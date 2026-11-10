import XCTest
@testable import MooMonitor

final class EventStoreTests: XCTestCase {

    func testByteLimitAppliesEvenBelowRecordLimit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = EventStore(directory: dir, config: MonitorConfig(token: "t", maxQueueRecords: 200, maxQueueBytes: 300))
        for i in 0..<4 { store.append(["event_id": "e\(i)", "message": String(repeating: "x", count: 150)]) }
        let size = try Data(contentsOf: dir.appendingPathComponent("queue.jsonl")).count
        XCTAssertLessThanOrEqual(size, 300)
    }

    func testReplayingSameRecoveredEventDoesNotIncreaseCount() {
        let store = makeStore()
        XCTAssertTrue(store.appendMerged(record(id: "stable")))
        XCTAssertTrue(store.appendMerged(record(id: "stable")))
        XCTAssertEqual(store.pending(limit: 10).first?["count"] as? Int, 1)
    }

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

    func testAcknowledgesOnlyFrozenRecordsAfterRotation() {
        let store = makeStore(maxRecords: 3)
        store.append(["event_id": "a"])
        store.append(["event_id": "b"])
        let batch = store.readBatch(limit: 2)
        store.append(["event_id": "c"])
        store.append(["event_id": "d"])
        XCTAssertTrue(store.acknowledge(batch, indexes: [0, 1]))
        XCTAssertEqual(store.pending(limit: 10).compactMap { $0["event_id"] as? String }, ["c", "d"])
    }

    func testCrashFramesEmptyWhenNoFile() {
        XCTAssertTrue(makeStore().crashFrames().isEmpty)
    }

    func testDistinctOccurrencesRemainIndependentUntilCloudAggregation() {
        let store = makeStore(maxRecords: 10)
        let first = record(id: "first", count: 1)
        let second = record(id: "second", count: 2)

        XCTAssertTrue(store.appendMerged(first))
        XCTAssertTrue(store.appendMerged(second))

        let pending = store.pending(limit: 10)
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending.last?["event_id"] as? String, "second")
        XCTAssertEqual(pending.last?["count"] as? Int, 2)
    }

    func testDoesNotMergeDifferentFingerprint() {
        let store = makeStore(maxRecords: 10)
        store.appendMerged(record(id: "a", name: "Swift.fatalError"))
        store.appendMerged(record(id: "b", name: "NSInvalidArgumentException"))

        XCTAssertEqual(store.pending(limit: 10).count, 2)
    }

    private func record(
        id: String,
        name: String = "Swift.fatalError",
        message: String = "unexpectedly found nil",
        count: Int = 1
    ) -> [String: Any] {
        [
            "event_id": id,
            "platform": "ios",
            "kind": "crash",
            "count": count,
            "exception": ["name": name, "message": message],
            "frames": [["function": "Shuhe.App.run", "app": true]],
        ]
    }
}
