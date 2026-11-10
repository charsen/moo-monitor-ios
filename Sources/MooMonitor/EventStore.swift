import Foundation
import CryptoKit
import MooMonitorCrash

/// 单进程队列。普通追加只写新行，重写用原子替换；崩溃文件始终独立。
final class EventStore {
    let dir: URL
    private let config: MonitorConfig
    private let lock = NSLock()
    private struct Entry { let line: String; let record: [String: Any] }
    private var entries: [Entry]?
    private var bytes = 0
    private var droppedValue: Int?

    init(directory: URL, config: MonitorConfig) {
        dir = directory
        var boundedConfig = config
        boundedConfig.maxQueueRecords = min(200, max(1, config.maxQueueRecords))
        boundedConfig.maxQueueBytes = min(2 * 1024 * 1024, max(1, config.maxQueueBytes))
        boundedConfig.maxCrashRecords = min(20, max(1, config.maxCrashRecords))
        self.config = boundedConfig
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(values)
    }

    static func forApp(config: MonitorConfig) -> EventStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return EventStore(directory: base.appendingPathComponent("monitor", isDirectory: true), config: config)
    }

    private var queueURL: URL { dir.appendingPathComponent("queue.jsonl") }
    private var droppedURL: URL { dir.appendingPathComponent("dropped.txt") }
    private var disabledURL: URL { dir.appendingPathComponent("disabled.json") }
    private var retryURL: URL { dir.appendingPathComponent("retry.json") }
    var crashPath: String { dir.appendingPathComponent("crash.bin").path }

    var dropped: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedLocked()
    }

    struct Batch {
        let records: [[String: Any]]
        fileprivate let lines: [String]
        let encodedSizes: [Int]
        let readable: Bool
    }

    /// 不按指纹合并：服务端负责聚合，客户端保留独立事件与发生日期。
    /// 相同 event_id 的崩溃源重放是幂等的，不能再次增加 count。
    @discardableResult
    func appendMerged(_ record: [String: Any]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            let current = try loadLocked()
            if let id = record["event_id"] as? String,
               current.contains(where: { $0.record["event_id"] as? String == id }) { return true }
            guard JSONSerialization.isValidJSONObject(record) else { throw StoreError.encoding }
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            guard data.count <= 256 * 1024, data.count + 1 <= config.maxQueueBytes else {
                recordDroppedLocked(1)
                // 明确永久超限，恢复端可清源；无法写盘的失败仍返回 false。
                return true
            }
            let entry = Entry(line: String(decoding: data, as: UTF8.self), record: record)
            if current.count + 1 > config.maxQueueRecords || bytes + data.count + 1 > config.maxQueueBytes {
                let kept = bounded(current + [entry])
                try replaceLocked(kept)
                recordDroppedLocked(current.count + 1 - kept.count)
            } else {
                if !FileManager.default.fileExists(atPath: queueURL.path) {
                    guard FileManager.default.createFile(atPath: queueURL.path, contents: nil) else { throw StoreError.write }
                }
                let handle = try FileHandle(forWritingTo: queueURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data + Data([10]))
                entries = current + [entry]
                bytes += data.count + 1
            }
            return true
        } catch {
            entries = nil // 下次操作重新修复潜在半行；读失败绝不覆盖原文件。
            recordDroppedLocked(1)
            return false
        }
    }

    func append(_ record: [String: Any]) { _ = appendMerged(record) }

    func readBatch(limit: Int) -> Batch {
        lock.lock(); defer { lock.unlock() }
        guard let current = try? loadLocked() else {
            return Batch(records: [], lines: [], encodedSizes: [], readable: false)
        }
        let batch = Array(current.prefix(max(0, limit)))
        return Batch(records: batch.map(\.record), lines: batch.map(\.line), encodedSizes: batch.map { $0.line.utf8.count }, readable: true)
    }

    func pending(limit: Int) -> [[String: Any]] { readBatch(limit: limit).records }

    /// 冻结原始行作为收据。网络期间追加/轮转不能改变被确认的事件集合。
    func acknowledge(_ batch: Batch, indexes: [Int]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard indexes.allSatisfy({ batch.lines.indices.contains($0) }) else { return false }
        do {
            var receipts = Dictionary(batch.lines.enumerated().filter { indexes.contains($0.offset) }
                .map { ($0.element, 1) }, uniquingKeysWith: +)
            let rest = try loadLocked().filter { entry in
                let count = receipts[entry.line] ?? 0
                if count > 0 { receipts[entry.line] = count - 1 }
                return count == 0
            }
            try replaceLocked(rest)
            return true
        } catch { return false }
    }

    private func loadLocked() throws -> [Entry] {
        if let entries { return entries }
        if !FileManager.default.fileExists(atPath: queueURL.path) { entries = []; bytes = 0; return [] }
        let data = try Data(contentsOf: queueURL)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        let valid = lines.compactMap { line -> Entry? in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            return Entry(line: line, record: obj)
        }
        let kept = bounded(valid)
        // 修复半行、损坏行及旧版本超限文件，避免坏行反复计丢弃或粘连新记录。
        if kept.count != lines.count || data.last != 10 {
            try replaceLocked(kept)
            recordDroppedLocked(lines.count - kept.count)
        } else {
            entries = kept
            bytes = kept.reduce(0) { $0 + $1.line.utf8.count + 1 }
        }
        return kept
    }

    private func bounded(_ items: [Entry]) -> [Entry] {
        let total = items.reduce(0) { $0 + $1.line.utf8.count + 1 }
        if items.count <= config.maxQueueRecords && total <= config.maxQueueBytes,
           items.allSatisfy({ $0.line.utf8.count <= 256 * 1024 }) { return items }
        var kept: [Entry] = []
        var size = 0
        for item in items.reversed() {
            let n = item.line.utf8.count + 1
            if n > config.maxQueueBytes || n > 256 * 1024 + 1 { continue }
            if kept.count >= max(1, config.maxQueueRecords * 3 / 4) || size + n > config.maxQueueBytes { break }
            kept.append(item); size += n
        }
        return kept.reversed()
    }

    private func replaceLocked(_ items: [Entry]) throws {
        let text = items.isEmpty ? "" : items.map(\.line).joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: queueURL, options: .atomic)
        entries = items
        bytes = text.utf8.count
    }

    private func droppedLocked() -> Int {
        if let droppedValue { return droppedValue }
        let value = Int((try? String(contentsOf: droppedURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        droppedValue = max(0, value)
        return droppedValue!
    }

    private func recordDroppedLocked(_ count: Int) {
        guard count > 0 else { return }
        let value = droppedLocked().addingReportingOverflow(count)
        droppedValue = value.overflow ? Int.max : value.partialValue
        try? String(droppedValue!).write(to: droppedURL, atomically: true, encoding: .utf8)
    }

    func crashFrames() -> [moo_crash_frame] {
        var buffer = [moo_crash_frame](repeating: moo_crash_frame(), count: config.maxCrashRecords)
        let count = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return moo_crash_read_last(crashPath, base, ptr.count)
        }
        return Array(buffer.prefix(count))
    }

    /// 安装信号处理前，在普通上下文原子收缩遗留原始帧；处理器打开的inode此后不变。
    func prepareCrashFile() -> Bool {
        let url = URL(fileURLWithPath: crashPath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: crashPath),
              let size = attributes[.size] as? NSNumber else { return true }
        let stride = MemoryLayout<moo_crash_frame>.stride
        guard size.int64Value > Int64(config.maxCrashRecords * stride) else { return true }
        let frames = crashFrames()
        // 无法确认读取成功时不能为了容量覆盖未知源；后续仍只作有界读取。
        guard !frames.isEmpty else { return false }
        let data = frames.withUnsafeBufferPointer { Data(bytes: $0.baseAddress!, count: $0.count * stride) }
        do {
            try data.write(to: url, options: .atomic)
            noteDropped(max(0, Int(size.int64Value / Int64(stride)) - frames.count))
            return true
        } catch { return false }
    }

    func noteDropped(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        recordDroppedLocked(count)
    }

    var hasCrashFrames: Bool { !crashFrames().isEmpty }
    func synchronizeQueue() -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            let handle = try FileHandle(forWritingTo: queueURL)
            defer { try? handle.close() }
            try handle.synchronize()
            return true
        } catch { return false }
    }
    func resetCrashFile() -> Bool { moo_crash_reset(crashPath) == 0 }

    struct DisabledStamp: Codable, Equatable {
        var at: Double
        var release: String? // 兼容旧文件；旧构建范围的禁用不再阻止新发送身份。
        var build: String?
        var identity: String?
    }
    struct RetryState: Codable, Equatable {
        var attempts: Int
        var nextAt: Double
        var reason: String?
        var identity: String? = nil
    }

    static func identity(_ config: MonitorConfig) -> String {
        let parts = [config.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")), config.app, config.token]
        let data = (try? JSONSerialization.data(withJSONObject: parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func disabledStamp() -> DisabledStamp? { readState(DisabledStamp.self, from: disabledURL) }
    func isDisabled(for config: MonitorConfig) -> Bool { disabledStamp()?.identity == Self.identity(config) }
    func setDisabledStamp(config: MonitorConfig, now: Date = Date()) {
        writeState(DisabledStamp(at: now.timeIntervalSince1970, identity: Self.identity(config)), to: disabledURL)
    }
    func clearDisabledStamp() { try? FileManager.default.removeItem(at: disabledURL) }
    func retryState() -> RetryState? { readState(RetryState.self, from: retryURL) }
    func setRetryState(_ state: RetryState) { writeState(state, to: retryURL) }
    func clearRetryState() { try? FileManager.default.removeItem(at: retryURL) }
    private func readState<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private func writeState<T: Encodable>(_ value: T, to url: URL) {
        lock.lock(); defer { lock.unlock() }
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: url, options: .atomic) }
    }
    private enum StoreError: Error { case encoding, write }
}
