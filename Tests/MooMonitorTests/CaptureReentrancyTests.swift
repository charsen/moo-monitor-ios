import XCTest
@testable import MooMonitor

final class CaptureReentrancyTests: XCTestCase {
    private struct Diagnostic: CustomNSError, @unchecked Sendable {
        let read: () -> Void
        static var errorDomain: String { "fixture.outer" }
        var errorCode: Int { 1 }
        var errorUserInfo: [String: Any] {
            read()
            return [NSLocalizedDescriptionKey: "outer"]
        }
    }
    private final class MonitorBox: @unchecked Sendable {
        let value: MooMonitor
        init(_ value: MooMonitor) { self.value = value }
    }
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    func testRecursiveErrorBridgeIsSkippedButLaterAttemptsRemainDistinct() throws {
        let dir = try directory(), config = MonitorConfig(token: "fixture")
        let monitor = MooMonitor(runtimeHooks: false)
        monitor.install(config, directory: dir)
        let error = Diagnostic {
            monitor.capture(NSError(domain: "fixture.nested", code: 2))
            monitor.capture(NSError(domain: "fixture.nested", code: 3), kind: "webview_gone")
        }
        monitor.capture(error); monitor.capture(error)
        let rows = EventStore(directory: dir, config: config).pending(limit: 10)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { ($0["exception"] as? [String: Any])?["name"] as? String == "fixture.outer#1" })
        XCTAssertEqual(Set(rows.compactMap { $0["event_id"] as? String }).count, 2)
    }
    func testCaptureGuardDoesNotSuppressAnotherThread() throws {
        let dir = try directory(), config = MonitorConfig(token: "fixture")
        let monitor = MooMonitor(runtimeHooks: false)
        monitor.install(config, directory: dir)
        let box = MonitorBox(monitor), started = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let release = DispatchGroup(); release.enter()
        let error = Diagnostic { started.signal(); _ = release.wait(timeout: .now() + 5) }
        DispatchQueue.global().async { box.value.capture(error); done.signal() }
        let entered = started.wait(timeout: .now() + 3) == .success
        if entered { monitor.capture(NSError(domain: "fixture.other", code: 2)) }
        release.leave()
        XCTAssertTrue(entered)
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        let rows = EventStore(directory: dir, config: config).pending(limit: 10)
        XCTAssertEqual(Set(rows.compactMap { ($0["exception"] as? [String: Any])?["name"] as? String }), ["fixture.outer#1", "fixture.other#2"])
    }
}
