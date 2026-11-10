import XCTest
@testable import MooMonitor

final class HTTPPolicyTests: XCTestCase {
    private func fixture(_ mode: String) async throws -> (URL, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = try XCTUnwrap(Bundle.module.url(forResource: "transport-server", withExtension: "py", subdirectory: "Fixtures"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path, dir.path, mode]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        addTeardownBlock {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: dir)
        }
        for _ in 0..<200 {
            if let port = try? String(contentsOf: dir.appendingPathComponent("port"), encoding: .utf8) {
                return (dir, "http://127.0.0.1:\(port)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "FixtureStartup", code: 1)
    }

    func testActualRedirectIsNotFollowedAndCookiesAreNotSent() async throws {
        let (dir, endpoint) = try await fixture("redirect")
        let config = MonitorConfig(endpoint: endpoint, token: "fixture")
        let store = EventStore(directory: dir, config: config)
        store.append(["event_id": "fixture"])
        let configuration = URLSessionConfiguration.ephemeral
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain:"127.0.0.1", .path:"/", .name:"private_fixture", .value:"private"]))
        configuration.httpCookieStorage?.setCookie(cookie)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let outcome = await Uploader(config: config, store: store, session: session).flush()
        XCTAssertEqual(outcome, .retry("http 302"))
        XCTAssertEqual(store.pending(limit: 10).count, 1)
        let lines = try String(contentsOf: dir.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let request = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertTrue(request["cookie"] is NSNull)
    }

    func testHTTPAuthenticationChallengeStillDisablesOn401AndKeepsQueue() async throws {
        let (dir, endpoint) = try await fixture("auth")
        let config = MonitorConfig(endpoint: endpoint, token: "fixture")
        let store = EventStore(directory: dir, config: config)
        store.append(["event_id": "fixture"])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let outcome = await Uploader(config: config, store: store, session: session).flush()
        XCTAssertEqual(outcome, .disabled)
        XCTAssertTrue(store.isDisabled(for: config))
        XCTAssertEqual(store.pending(limit: 10).count, 1)
    }
}
