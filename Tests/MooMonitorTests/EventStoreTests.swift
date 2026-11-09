import XCTest
@testable import MooMonitor

final class EventStoreTests: XCTestCase {

    private func makeStore(maxRecords: Int = 5) -> EventStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moo-monitor-test-\(UUID().uuidString)", isDirectory: true)
        return EventStore(directory: dir, config: MonitorConfig(token: "t", app: "shuhe", maxQueueRecords: maxRecords))
    }

    func testAppendsAndReadsInOrder() {
        let store = makeStore()
        store.append(["event_id": "a"])
        store.append(["event_id": "b"])

        XCTAssertEqual(store.pending(limit: 10).compactMap { $0["event_id"] as? String }, ["a", "b"])
    }

    func testRotatesOverCapacity() {
        let store = makeStore(maxRecords: 3)
        for i in 0..<6 { store.append(["event_id": "e\(i)"]) }

        let ids = store.pending(limit: 10).compactMap { $0["event_id"] as? String }
        XCTAssertTrue(ids.contains("e5"))
        XCTAssertGreaterThan(store.dropped, 0)
    }

    func testDropFirstKeepsRest() {
        let store = makeStore(maxRecords: 10)
        for i in 0..<4 { store.append(["event_id": "e\(i)"]) }

        store.dropFirst(2)

        XCTAssertEqual(store.pending(limit: 10).compactMap { $0["event_id"] as? String }, ["e2", "e3"])
    }

    func testCrashFramesEmptyWhenNoFile() {
        XCTAssertTrue(makeStore().crashFrames().isEmpty)
    }
}
