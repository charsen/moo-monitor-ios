import XCTest
import MooMonitorCrash
@testable import MooMonitor

final class RecoveryTests: XCTestCase {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testCrashRecoveryRetainsOriginalBuildSessionAndStableIDAfterFailedQueueWrite() throws {
        let dir = try directory()
        let old = MonitorConfig(token: "local-fixture", release: "old", build: "3", env: "debug")
        let marker = SessionMarker(directory: dir, config: old)
        _ = marker.begin(sessionId: "old-session")
        marker.mark(.foreground)
        marker.markScreen("ReaderView")
        var frame = moo_crash_frame()
        frame.magic = MOO_CRASH_MAGIC; frame.version = UInt16(MOO_CRASH_VERSION)
        frame.sig = SIGTRAP; frame.timestamp_ms = 1_700_000_000_000
        try withUnsafeBytes(of: &frame) { try Data($0).write(to: dir.appendingPathComponent("crash.bin")) }
        let queue = dir.appendingPathComponent("queue.jsonl")
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        let updated = MonitorConfig(token: "local-fixture", release: "new", build: "4")
        MooMonitor(runtimeHooks: false).install(updated, directory: dir)
        let recovery = try Data(contentsOf: dir.appendingPathComponent("crash-recovery.json"))
        let frozen = try XCTUnwrap(try JSONSerialization.jsonObject(with: recovery) as? [[String: Any]])
        try FileManager.default.removeItem(at: queue)
        MooMonitor(runtimeHooks: false).install(updated, directory: dir)
        let records = EventStore(directory: dir, config: updated).pending(limit: 10)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?["release"] as? String, "old")
        XCTAssertEqual(records.first?["build"] as? String, "3")
        XCTAssertEqual(records.first?["env"] as? String, "debug")
        XCTAssertEqual((records.first?["context"] as? [String: Any])?["session_id"] as? String, "old-session")
        XCTAssertEqual(records.first?["event_id"] as? String, frozen.first?["event_id"] as? String)
        XCTAssertTrue(EventStore(directory: dir, config: updated).crashFrames().isEmpty)
    }

    func testCaptureSanitizesNestedPayloadAndBoundsUTF8() throws {
        let dir = try directory()
        let config = MonitorConfig(token: "local-fixture")
        let monitor = MooMonitor(runtimeHooks: false)
        monitor.install(config, directory: dir)
        monitor.setScreen("ReaderView")
        monitor.capture(NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: String(repeating: "汉", count: 20_000)]),
                        extras: ["nested": ["token": "tiny", "password": "short"], "invalid": Double.infinity])
        let record = try XCTUnwrap(EventStore(directory: dir, config: config).pending(limit: 10).first)
        let payload = try JSONSerialization.data(withJSONObject: record["payload"]!)
        XCTAssertLessThanOrEqual(payload.count, 8 * 1024)
        let text = String(decoding: payload, as: UTF8.self)
        XCTAssertFalse(text.contains("tiny")); XCTAssertFalse(text.contains("short"))
        XCTAssertLessThanOrEqual(((record["exception"] as? [String: Any])?["message"] as? String)?.utf8.count ?? Int.max, 8 * 1024)
    }

    func testUnknownImageAndOverflowingOffsetCannotResolveIntoDifferentBinary() {
        var frame = moo_crash_frame()
        frame.depth = 64; frame.image_count = 32
        _ = withUnsafeMutableBytes(of: &frame.image_index) { $0.initializeMemory(as: UInt8.self, repeating: 255) }
        XCTAssertTrue(FrameResolver.resolve(frame).isEmpty)
        frame.depth = UInt32.max; frame.image_count = UInt32.max
        XCTAssertTrue(FrameResolver.resolve(frame).isEmpty)
    }

    func testRepeatedLifecycleAndScreenDoNotWriteDuplicateBreadcrumbs() throws {
        let dir = try directory()
        let monitor = MooMonitor(runtimeHooks: false)
        monitor.install(MonitorConfig(token: "fixture"), directory: dir)
        monitor.enterForeground(); monitor.enterForeground()
        monitor.setScreen("ReaderView"); monitor.setScreen("ReaderView")
        let data = try Data(contentsOf: dir.appendingPathComponent("breadcrumbs.json"))
        let crumbs = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: String]])
        XCTAssertEqual(crumbs.filter { $0["name"] == "foreground" }.count, 1)
        XCTAssertEqual(crumbs.filter { $0["name"] == "ReaderView" }.count, 1)
    }

    func testRendererCaptureUsesDedicatedKindAndRejectsUnsupportedKinds() throws {
        let dir = try directory()
        let config = MonitorConfig(token: "fixture")
        let monitor = MooMonitor(runtimeHooks: false)
        monitor.install(config, directory: dir)
        monitor.capture(NSError(domain: "fixture", code: 1), kind: "webview_gone")
        monitor.capture(NSError(domain: "fixture", code: 1), kind: "invented")
        let records = EventStore(directory: dir, config: config).pending(limit: 10)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?["kind"] as? String, "webview_gone")
    }

    func testLowMemoryUsesOneHourMonotonicThrottle() throws {
        let dir = try directory()
        let config = MonitorConfig(token: "fixture")
        let monitor = MooMonitor(runtimeHooks: false)
        monitor.install(config, directory: dir)
        monitor.recordLowMemory(now: 10)
        monitor.recordLowMemory(now: 20)
        monitor.recordLowMemory(now: 3610)
        let records = EventStore(directory: dir, config: config).pending(limit: 10)
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { $0["kind"] as? String == "low_memory" })
    }

    func testNSErrorDomainAndCodeRemainDistinctForServerGrouping() throws {
        let dir = try directory()
        let config = MonitorConfig(token: "fixture")
        let monitor = MooMonitor(runtimeHooks: false)
        monitor.install(config, directory: dir)
        monitor.capture(NSError(domain: "NSCocoaErrorDomain", code: 260, userInfo: [NSLocalizedDescriptionKey: "import failed"]))
        monitor.capture(NSError(domain: "NSCocoaErrorDomain", code: 257, userInfo: [NSLocalizedDescriptionKey: "import failed"]))
        let names = EventStore(directory: dir, config: config).pending(limit: 10).compactMap { ($0["exception"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(Set(names), ["NSCocoaErrorDomain#260", "NSCocoaErrorDomain#257"])
    }

    func testOversizedExtrasCannotDiscardDroppedCounter() throws {
        let dir = try directory()
        let config = MonitorConfig(token: "fixture")
        EventStore(directory: dir, config: config).noteDropped(7)
        let monitor = MooMonitor(runtimeHooks: false)
        monitor.install(config, directory: dir)
        monitor.capture(NSError(domain: "fixture", code: 1), extras: ["text": String(repeating: "\0", count: 8000)])
        let record = try XCTUnwrap(EventStore(directory: dir, config: config).pending(limit: 10).first)
        let payload = try XCTUnwrap(record["payload"] as? [String: Any])
        XCTAssertEqual(payload["dropped"] as? Int, 7)
        XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: payload).count, 8 * 1024)
    }

    func testTerminationKeepsPreviousSessionAndUsesWarningSeverity() throws {
        let dir = try directory()
        let config = MonitorConfig(token: "fixture")
        let marker = SessionMarker(directory: dir, config: config)
        _ = marker.begin(sessionId: "previous")
        marker.mark(.foreground)
        let monitor = MooMonitor(runtimeHooks: false)
        monitor.install(config, directory: dir)
        let record = try XCTUnwrap(EventStore(directory: dir, config: config).pending(limit: 10).first)
        XCTAssertEqual(record["kind"] as? String, "termination")
        XCTAssertEqual(record["severity"] as? String, "warning")
        XCTAssertEqual((record["context"] as? [String: Any])?["session_id"] as? String, "previous")
    }

    func testMalformedSessionTimeIsIgnoredWithoutCrashingHost() throws {
        let dir = try directory()
        let state = SessionState(session_id: "bad", started_at: Int64.min, updated_at: Int64.max,
                                 state: "foreground", release: "", build: "", screen: nil)
        try JSONEncoder().encode(state).write(to: dir.appendingPathComponent("session.json"))
        let config = MonitorConfig(token: "fixture")
        MooMonitor(runtimeHooks: false).install(config, directory: dir)
        XCTAssertTrue(EventStore(directory: dir, config: config).pending(limit: 10).isEmpty)
    }

    func testFutureSignalTimestampIsClampedBeforeFormatting() throws {
        let dir = try directory()
        var frame = moo_crash_frame()
        frame.magic = MOO_CRASH_MAGIC; frame.version = UInt16(MOO_CRASH_VERSION)
        frame.timestamp_ms = UInt64.max; frame.sig = SIGTRAP
        try withUnsafeBytes(of: &frame) { try Data($0).write(to: dir.appendingPathComponent("crash.bin")) }
        let config = MonitorConfig(token: "fixture")
        MooMonitor(runtimeHooks: false).install(config, directory: dir)
        let record = try XCTUnwrap(EventStore(directory: dir, config: config).pending(limit: 10).first)
        let text = try XCTUnwrap(record["occurred_at"] as? String)
        let date = try XCTUnwrap(ISO8601DateFormatter.moo.date(from: text))
        XCTAssertLessThanOrEqual(date.timeIntervalSince1970, Date().timeIntervalSince1970 + 1)
        XCTAssertGreaterThan(date.timeIntervalSince1970, Date().timeIntervalSince1970 - 5)
    }

    func testScreenRejectsBusinessContent() throws {
        let monitor = MooMonitor(runtimeHooks: false)
        monitor.install(MonitorConfig(token: "local-fixture"), directory: try directory())
        monitor.setScreen("ReaderView")
        monitor.setScreen("书名 /books/private.txt")
        XCTAssertEqual(monitor.screen, "ReaderView")
    }
}
