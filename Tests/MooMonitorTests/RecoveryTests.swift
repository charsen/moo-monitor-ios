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
        XCTAssertNil((record["payload"] as? [String: Any])?["memory_footprint"])
    }

    func testDelayedMetricKitReportKeepsItsOwnBuildTimeAndAllFrames() throws {
        let dir = try directory()
        let config = MonitorConfig(token: "fixture", release: "current", build: "42")
        let monitor = MooMonitor(runtimeHooks: false)
        monitor.install(config, directory: dir)
        monitor.setScreen("CurrentReaderView")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let period = DateInterval(start: start, duration: 60)
        let frames: [[String: Any]] = (0..<32).map { ["image_uuid": "aaaaaaaa111122223333444444444444", "offset": $0] }
        monitor.enqueueMetric(MetricKitReport(kind: "crash", name: "metrickit_crash", message: "fixture",
                                             period: period, release: "old", build: "8", frames: frames,
                                             device: ["os_version": "old-os"], extras: ["frame_count": frames.count]))
        monitor.enqueueMetric(MetricKitReport(kind: "termination", name: "metrickit_app_exit", message: "mixed builds",
                                             period: period, release: nil, build: nil,
                                             extras: ["multiple_application_versions": true]))
        let records = EventStore(directory: dir, config: config).pending(limit: 10)
        XCTAssertEqual(records.count, 2)
        let report = try XCTUnwrap(records.first)
        XCTAssertEqual(report["release"] as? String, "old")
        XCTAssertEqual(report["build"] as? String, "8")
        XCTAssertEqual(report["occurred_at"] as? String, ISO8601DateFormatter.moo.string(from: period.end))
        XCTAssertEqual((report["frames"] as? [[String: Any]])?.count, 32)
        XCTAssertEqual((report["frames"] as? [[String: Any]])?.last?["offset"] as? Int, 31)
        XCTAssertEqual((report["device"] as? [String: String])?["os_version"], "old-os")
        let payload = try XCTUnwrap(report["payload"] as? [String: Any])
        XCTAssertEqual(payload["report_started_at"] as? String, ISO8601DateFormatter.moo.string(from: start))
        XCTAssertEqual(payload["timestamp_source"] as? String, "report_window_end")
        XCTAssertNil(payload["frames"])
        let context = try XCTUnwrap(report["context"] as? [String: Any])
        XCTAssertNotNil(context["install_id"])
        XCTAssertNil(context["session_id"])
        XCTAssertNil(context["foreground"])
        XCTAssertNil(report["breadcrumbs"])
        XCTAssertNil(records.last?["release"])
        XCTAssertNil(records.last?["build"])
    }

    func testMetricKitExitHintsSkipNormalOnlyReportsAndKeepBackgroundFailures() {
        func hint(_ memory: Bool = false, _ watchdog: Bool = false, _ abnormal: Bool = false,
                  pressure: Bool = false, cpu: Bool = false, timeout: Bool = false, locked: Bool = false) -> String? {
            MetricKitExitHint.classify(memory: memory, watchdog: watchdog, abnormal: abnormal, memoryPressure: pressure,
                                       cpuLimit: cpu, backgroundTimeout: timeout, suspendedWithLockedFile: locked)
        }
        XCTAssertNil(hint())
        XCTAssertEqual(hint(true, true), "oom_suspect")
        XCTAssertEqual(hint(false, true), "watchdog_suspect")
        XCTAssertEqual(hint(false, false, true), "crash_suspect")
        XCTAssertEqual(hint(pressure: true), "background_memory_pressure")
        XCTAssertEqual(hint(cpu: true), "background_cpu_limit")
        XCTAssertEqual(hint(timeout: true), "background_task_timeout")
        XCTAssertEqual(hint(locked: true), "background_suspended_with_locked_file")
    }

    func testTerminationUsesOnlyPreviousMemoryObservationAndKeepsCauseUnknown() throws {
        let dir = try directory()
        let config = MonitorConfig(token: "fixture")
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let sampledAt = Int64(started.timeIntervalSince1970 * 1000) + 10_000
        let marker = SessionMarker(directory: dir, config: config, device: ["model": "previous-device"])
        _ = marker.begin(sessionId: "previous", now: started)
        marker.mark(.foreground, now: started)
        marker.markMemory(SessionMemorySample(at: sampledAt, footprint: 64 * 1024 * 1024, available: 1024))
        MooMonitor(runtimeHooks: false).install(config, directory: dir)
        let record = try XCTUnwrap(EventStore(directory: dir, config: config).pending(limit: 10).first)
        let payload = try XCTUnwrap(record["payload"] as? [String: Any])
        XCTAssertEqual(payload["exit_hint"] as? String, "unknown")
        XCTAssertEqual(payload["memory_sampled_at"] as? Int64, sampledAt)
        XCTAssertEqual(payload["memory_footprint"] as? Int, 64 * 1024 * 1024)
        XCTAssertEqual(payload["available_memory"] as? Int, 1024)
        XCTAssertNil(payload["storage_free"])
        XCTAssertNil((record["context"] as? [String: Any])?["storage_free"])
        XCTAssertEqual((record["device"] as? [String: String])?["model"], "previous-device")
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
