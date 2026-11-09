import Foundation
import MooMonitorCrash

/// 落盘：`queue.jsonl`（待发记录）、`crash.bin`（定长崩溃帧）、`session.json`（脏退出标记）。
/// 目录标 `isExcludedFromBackup`，这些数据不该进 iCloud 备份。
public final class EventStore {

    public let dir: URL
    private let config: MonitorConfig
    private let lock = NSLock()

    /// 队列上限 / 坏行 / 写失败累计。持久化，跨启动仍然可解释。
    public var dropped: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedLocked()
    }

    public init(directory: URL, config: MonitorConfig) {
        self.dir = directory
        self.config = config
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(values)
    }

    public static func forApp(config: MonitorConfig) -> EventStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return EventStore(directory: base.appendingPathComponent("monitor", isDirectory: true), config: config)
    }

    private var queueURL: URL { dir.appendingPathComponent("queue.jsonl") }
    private var crashURL: URL { dir.appendingPathComponent("crash.bin") }
    private var droppedURL: URL { dir.appendingPathComponent("dropped.txt") }
    private var disabledURL: URL { dir.appendingPathComponent("disabled.json") }
    private var retryURL: URL { dir.appendingPathComponent("retry.json") }

    // MARK: - 队列

    /// 追加一条原始记录。队列内同指纹合并由 `appendMerged` 做；
    /// 这里保留给测试和不需要合并的调用点。
    public func append(_ record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: data, encoding: .utf8) else {
            lock.lock(); recordDroppedLocked(1); lock.unlock()
            return
        }
        line += "\n"
        lock.lock()
        defer { lock.unlock() }
        do {
            try appendLineLocked(line)
            rotateIfNeededLocked()
        } catch {
            recordDroppedLocked(1)
        }
    }

    /// 追加并按指纹合并：同一条崩溃重复发生时只增加 count，不堆 200 条同样记录。
    ///
    /// 为什么必须换新的 `event_id`：服务端按 `event_id` 做重试去重。沿用旧 id 会把
    /// 「已成功发送过」的合并记录判成 duplicate，新增的次数就丢了。
    @discardableResult
    public func appendMerged(_ record: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              let line = String(data: data, encoding: .utf8) else {
            lock.lock(); recordDroppedLocked(1); lock.unlock()
            return false
        }

        lock.lock()
        defer { lock.unlock() }

        let fingerprint = Self.fingerprint(of: record)
        var lines = readLinesLocked()
        for index in lines.indices {
            guard let existingData = lines[index].data(using: .utf8),
                  var existing = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
                continue
            }
            guard Self.fingerprint(of: existing) == fingerprint else { continue }

            let newCount = (record["count"] as? Int) ?? 1
            let oldCount = (existing["count"] as? Int) ?? 1
            existing["count"] = min(1000, oldCount + newCount)
            existing["event_id"] = record["event_id"] ?? existing["event_id"]
            existing["occurred_at"] = record["occurred_at"] ?? existing["occurred_at"]
            existing["context"] = record["context"] ?? existing["context"]
            existing["device"] = record["device"] ?? existing["device"]
            if let breadcrumbs = record["breadcrumbs"] { existing["breadcrumbs"] = breadcrumbs }
            if let payload = record["payload"] as? [String: Any] {
                var merged = (existing["payload"] as? [String: Any]) ?? [:]
                for (key, value) in payload { merged[key] = value }
                existing["payload"] = merged
            }
            // 新记录带了更完整的异常上下文（例如 NSException 的栈）时不要被旧记录覆盖。
            if let exception = record["exception"] as? [String: Any] {
                var merged = (existing["exception"] as? [String: Any]) ?? [:]
                for (key, value) in exception {
                    if let text = value as? String, text.isEmpty { continue }
                    merged[key] = value
                }
                existing["exception"] = merged
            }
            if let frames = record["frames"] as? [[String: Any]], !frames.isEmpty {
                existing["frames"] = frames
            }

            guard let mergedData = try? JSONSerialization.data(withJSONObject: existing),
                  let mergedLine = String(data: mergedData, encoding: .utf8) else {
                recordDroppedLocked(1)
                return false
            }
            lines[index] = mergedLine
            guard writeLinesLocked(lines) else {
                recordDroppedLocked(1)
                return false
            }
            return true
        }

        do {
            try appendLineLocked(line + "\n")
            rotateIfNeededLocked()
            return true
        } catch {
            recordDroppedLocked(1)
            return false
        }
    }

    public func pending(limit: Int) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }

        var out: [[String: Any]] = []
        for line in readLinesLocked() {
            if out.count >= limit { break }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                recordDroppedLocked(1)
                continue
            }
            out.append(obj)
        }
        return out
    }

    public func dropFirst(_ count: Int) {
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        let rest = Array(readLinesLocked().dropFirst(count))
        if rest.isEmpty {
            try? FileManager.default.removeItem(at: queueURL)
        } else {
            writeLinesLocked(rest)
        }
    }

    /// 401/403 时按契约清空待发队列，避免拿着无效 token 一直重试。
    public func clearQueue() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: queueURL)
    }

    private func appendLineLocked(_ line: String) throws {
        if !FileManager.default.fileExists(atPath: queueURL.path) {
            FileManager.default.createFile(atPath: queueURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: queueURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }

    @discardableResult
    private func writeLinesLocked(_ lines: [String]) -> Bool {
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        do {
            try text.write(to: queueURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private func rotateIfNeededLocked() {
        let lines = readLinesLocked()
        let size = (try? FileManager.default.attributesOfItem(atPath: queueURL.path)[.size] as? NSNumber)?.intValue ?? 0
        let overCount = lines.count > config.maxQueueRecords
        let overBytes = size > config.maxQueueBytes
        guard overCount || overBytes else { return }

        let keep = max(config.maxQueueRecords * 3 / 4, 1)
        let kept = Array(lines.suffix(keep))
        recordDroppedLocked(lines.count - kept.count)
        writeLinesLocked(kept)
    }

    private func readLinesLocked() -> [String] {
        guard let text = try? String(contentsOf: queueURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private func droppedLocked() -> Int {
        if let value = Int((try? String(contentsOf: droppedURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
            return value
        }
        return 0
    }

    private func recordDroppedLocked(_ count: Int) {
        guard count > 0 else { return }
        let value = droppedLocked() + count
        try? String(value).write(to: droppedURL, atomically: true, encoding: .utf8)
    }

    // MARK: - 崩溃帧

    /// 读回崩溃帧，只取最近 `maxCrashRecords` 条。`crash.bin` 本身可能被坏版本写得很长，
    /// 读取端限制数量，避免一次启动解析上千帧。
    public func crashFrames() -> [moo_crash_frame] {
        var buffer = [moo_crash_frame](repeating: moo_crash_frame(), count: config.maxCrashRecords)
        let count = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return moo_crash_read_last(crashURL.path, base, ptr.count)
        }
        return Array(buffer.prefix(count))
    }

    public var hasCrashFrames: Bool {
        var frame = moo_crash_frame()
        return moo_crash_read_last(crashURL.path, &frame, 1) > 0
    }

    public func resetCrashFile() {
        moo_crash_reset(crashURL.path)
    }

    public var crashPath: String { crashURL.path }

    // MARK: - 运行状态（跨启动）

    public struct DisabledStamp: Codable, Equatable {
        public var at: Double
        public var release: String
        public var build: String
    }

    public struct RetryState: Codable, Equatable {
        public var attempts: Int
        public var nextAt: Double
        public var reason: String?
    }

    public func disabledStamp() -> DisabledStamp? {
        guard let data = try? Data(contentsOf: disabledURL) else { return nil }
        return try? JSONDecoder().decode(DisabledStamp.self, from: data)
    }

    public func setDisabledStamp(release: String, build: String, now: Date = Date()) {
        let stamp = DisabledStamp(at: now.timeIntervalSince1970, release: release, build: build)
        if let data = try? JSONEncoder().encode(stamp) {
            try? data.write(to: disabledURL, options: .atomic)
        }
    }

    public func clearDisabledStamp() {
        try? FileManager.default.removeItem(at: disabledURL)
    }

    public func retryState() -> RetryState? {
        guard let data = try? Data(contentsOf: retryURL) else { return nil }
        return try? JSONDecoder().decode(RetryState.self, from: data)
    }

    public func setRetryState(_ state: RetryState) {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: retryURL, options: .atomic)
        }
    }

    public func clearRetryState() {
        try? FileManager.default.removeItem(at: retryURL)
    }

    // MARK: - 指纹

    /// 队列内合并用的本地指纹。服务端不信任客户端 hash，会自己重算；
    /// 这里只用于「同一进程内同一条崩溃别堆 200 行」，不参与上报。
    static func fingerprint(of record: [String: Any]) -> String {
        let platform = record["platform"] as? String ?? ""
        let kind = record["kind"] as? String ?? ""
        let exception = record["exception"] as? [String: Any] ?? [:]
        let name = exception["name"] as? String ?? ""
        let message = normalize(exception["message"] as? String ?? "")
        let frames = (record["frames"] as? [[String: Any]] ?? []).prefix(3).map {
            ($0["function"] as? String) ?? ($0["file"] as? String) ?? ""
        }
        return [platform, kind, name, message, frames.joined(separator: "|")].joined(separator: "\u{1F}")
    }

    private static func normalize(_ message: String) -> String {
        var value = message
        value = value.replacingOccurrences(of: #"0x[0-9a-fA-F]+"#, with: "0xN", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\b[0-9a-fA-F]{8,}\b"#, with: "HEX", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\d+"#, with: "N", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }
}
