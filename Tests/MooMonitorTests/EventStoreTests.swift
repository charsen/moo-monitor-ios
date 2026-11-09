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

    func testMergesSameFingerprintAndKeepsNewEventId() {
        let store = makeStore(maxRecords: 10)
        let first = record(id: "first", count: 1)
        let second = record(id: "second", count: 2)

        XCTAssertTrue(store.appendMerged(first))
        XCTAssertTrue(store.appendMerged(second))

        let pending = store.pending(limit: 10)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?["event_id"] as? String, "second")
        XCTAssertEqual(pending.first?["count"] as? Int, 3)
    }

    func testDoesNotMergeDifferentFingerprint() {
        let store = makeStore(maxRecords: 10)
        store.appendMerged(record(id: "a", name: "Swift.fatalError"))
        store.appendMerged(record(id: "b", name: "NSInvalidArgumentException"))

        XCTAssertEqual(store.pending(limit: 10).count, 2)
    }

    func testFingerprintNormalizesAddressesAndNumbers() {
        let one = record(id: "a", message: "bad at 0x1234abcd and 42")
        let two = record(id: "b", message: "bad at 0xdeadbeef and 7")
        XCTAssertEqual(EventStore.fingerprint(of: one), EventStore.fingerprint(of: two))
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
