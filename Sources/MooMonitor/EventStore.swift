import Foundation
import MooMonitorCrash

/// 落盘：`queue.jsonl`（待发记录）、`crash.bin`（定长崩溃帧）、`session.json`（脏退出标记）。
/// 目录标 `isExcludedFromBackup`，这些数据不该进 iCloud 备份。
public final class EventStore {

    public let dir: URL
    private let config: MonitorConfig
    private let lock = NSLock()

    public private(set) var dropped: Int = 0

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

    public func append(_ record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: data, encoding: .utf8) else {
            dropped += 1
            return
        }
        line += "\n"
        lock.lock()
        defer { lock.unlock() }
        do {
            if !FileManager.default.fileExists(atPath: queueURL.path) {
                FileManager.default.createFile(atPath: queueURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: queueURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
            rotateIfNeeded()
        } catch {
            dropped += 1
        }
    }

    private func rotateIfNeeded() {
        let lines = readLines()
        guard lines.count > config.maxQueueRecords else { return }
        let kept = Array(lines.suffix(max(config.maxQueueRecords * 3 / 4, 1)))
        dropped += lines.count - kept.count
        try? kept.joined(separator: "\n").appending("\n").write(to: queueURL, atomically: true, encoding: .utf8)
    }

    public func pending(limit: Int) -> [[String: Any]] {
        lock.lock()
        let lines = readLines()
        lock.unlock()

        var out: [[String: Any]] = []
        for line in lines {
            if out.count >= limit { break }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                dropped += 1
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
        let rest = Array(readLines().dropFirst(count))
        if rest.isEmpty {
            try? FileManager.default.removeItem(at: queueURL)
        } else {
            try? rest.joined(separator: "\n").appending("\n").write(to: queueURL, atomically: true, encoding: .utf8)
        }
    }

    private func readLines() -> [String] {
        guard let text = try? String(contentsOf: queueURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - 崩溃帧

    /// 读回崩溃帧（最多 maxCrashRecords 条）。
    public func crashFrames() -> [moo_crash_frame] {
        var buffer = [moo_crash_frame](repeating: moo_crash_frame(), count: config.maxCrashRecords)
        let count = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return moo_crash_read(crashURL.path, base, ptr.count)
        }
        return Array(buffer.prefix(count))
    }

    public func resetCrashFile() {
        moo_crash_reset(crashURL.path)
    }

    public var crashPath: String { crashURL.path }
}
