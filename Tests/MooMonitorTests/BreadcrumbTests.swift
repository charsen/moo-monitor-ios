import XCTest
@testable import MooMonitor

final class BreadcrumbTests: XCTestCase {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    private func crumbs(_ dir: URL) throws -> [[String: String]] {
        let data = try Data(contentsOf: dir.appendingPathComponent("breadcrumbs.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: String]])
    }
    func testCrossPlatformLabelsRejectRequestDataAndCredentials() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cross-sdk-breadcrumbs", withExtension: "json", subdirectory: "Fixtures"))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        for row in rows {
            let dir = try directory(), monitor = MooMonitor(runtimeHooks: false)
            monitor.install(MonitorConfig(token: "fixture"), directory: dir)
            let before = try crumbs(dir).count
            monitor.breadcrumb(row["type"] as! String, row["name"] as! String)
            XCTAssertEqual(try crumbs(dir).count - before, row["accepted"] as? Bool == true ? 1 : 0)
        }
    }
    func testRepeatedRequestsAvoidDiskWritesAndKeepThirtyOrderedTransitions() throws {
        let dir = try directory(), config = MonitorConfig(token: "fixture")
        let monitor = MooMonitor(runtimeHooks: false)
        monitor.install(config, directory: dir)
        monitor.breadcrumb("sync", "reader.identity.ok")
        let file = dir.appendingPathComponent("breadcrumbs.json")
        let before = try Data(contentsOf: file)
        for _ in 0..<1000 { monitor.breadcrumb("sync", "reader.identity.ok") }
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertTrue(EventStore(directory: dir, config: config).pending(limit: 10).isEmpty)
        for i in 0..<35 { monitor.breadcrumb("sync", "reader.phase_\(i).ok") }
        let tail = try crumbs(dir)
        XCTAssertEqual(tail.count, 30)
        XCTAssertEqual(tail.first?["name"], "reader.phase_5.ok")
        XCTAssertEqual(tail.last?["name"], "reader.phase_34.ok")
        monitor.capture(NSError(domain: "fixture", code: 1))
        let saved = EventStore(directory: dir, config: config).pending(limit: 10)
        let attached = try XCTUnwrap(saved.first?["breadcrumbs"] as? [[String: String]])
        XCTAssertEqual(attached, tail)
        monitor.breadcrumb("sync", "reader.progress.ok")
        XCTAssertEqual((EventStore(directory: dir, config: config).pending(limit: 10).first?["breadcrumbs"] as? [[String: String]]), tail)
    }
    func testDisabledMonitorDoesNotPersistBreadcrumbs() throws {
        let dir = try directory(), monitor = MooMonitor(runtimeHooks: false)
        monitor.install(MonitorConfig(token: ""), directory: dir)
        monitor.breadcrumb("sync", "reader.identity.ok")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }
    func testLegacyBreadcrumbEntryPointPreservesRepeatedOccurrences() throws {
        let dir = try directory(), monitor = MooMonitor(runtimeHooks: false)
        monitor.install(MonitorConfig(token: "fixture"), directory: dir)
        monitor.addBreadcrumb("screen", "ReaderView")
        monitor.addBreadcrumb("screen", "ReaderView")
        XCTAssertEqual(try crumbs(dir).filter { $0["name"] == "ReaderView" }.count, 2)
    }
}
