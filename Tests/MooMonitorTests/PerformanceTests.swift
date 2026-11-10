import XCTest
@testable import MooMonitor

final class PerformanceTests: XCTestCase {
    func testAppendBudgetWithDistinctEvents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EventStore(directory: dir, config: MonitorConfig(token: "fixture"))
        let start = ProcessInfo.processInfo.systemUptime
        for i in 0..<1000 {
            store.appendMerged(["event_id": "event-\(i)", "platform": "ios", "kind": "handled",
                                "exception": ["name": "Fixture\(i)", "message": "synthetic"],
                                "payload": ["fixture": String(repeating: "x", count: 512)]])
        }
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        XCTAssertLessThanOrEqual(store.pending(limit: 1000).count, 200)
        print("MONITOR_PERF append_1000_ms=\(elapsed)")
    }
}
