import XCTest
@testable import MooMonitor

final class SessionMarkerTests: XCTestCase {

    private func makeMarker(release: String = "0.1.1", build: String = "12") -> SessionMarker {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moo-monitor-session-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SessionMarker(
            directory: dir,
            config: MonitorConfig(token: "t", app: "shuhe", release: release, build: build)
        )
    }

    func testFirstLaunchHasNoPreviousState() {
        XCTAssertNil(makeMarker().begin(sessionId: "s1"))
    }

    func testForegroundSurvivesIntoNextLaunch() {
        let marker = makeMarker()
        _ = marker.begin(sessionId: "s1")
        marker.mark(.foreground)
        marker.markScreen("ReaderView")

        let previous = marker.begin(sessionId: "s2")

        XCTAssertEqual(previous?.state, "foreground")
        XCTAssertEqual(previous?.screen, "ReaderView")
        XCTAssertEqual(previous?.release, "0.1.1")
        XCTAssertEqual(previous?.build, "12")
    }

    func testBackgroundIsRecorded() {
        let marker = makeMarker()
        _ = marker.begin(sessionId: "s1")
        marker.mark(.foreground)
        marker.mark(.background)

        XCTAssertEqual(marker.begin(sessionId: "s2")?.state, "background")
    }

    func testMalformedSessionTimesCannotBeUsedToInferTermination() {
        let config = MonitorConfig(token: "fixture")
        for (start, updated) in [(Int64.min, Int64.max), (Int64(100), Int64(1)), (Int64(0), Int64.max)] {
            let state = SessionState(session_id: "old", started_at: start, updated_at: updated,
                                     state: "foreground", release: "", build: "", screen: nil)
            XCTAssertFalse(MooMonitor.shouldInferTermination(previous: state, hadCrash: false, config: config))
        }
    }

    func testTerminationInferenceRequiresForegroundSameBuildAndNoCrash() {
        let config = MonitorConfig(token: "t", app: "shuhe", release: "0.1.1", build: "12")
        let state = SessionState(
            session_id: "s1",
            started_at: 1,
            updated_at: 2,
            state: "foreground",
            release: "0.1.1",
            build: "12",
            screen: "ReaderView"
        )

        XCTAssertTrue(MooMonitor.shouldInferTermination(previous: state, hadCrash: false, config: config))
        XCTAssertFalse(MooMonitor.shouldInferTermination(previous: state, hadCrash: true, config: config))
        XCTAssertFalse(MooMonitor.shouldInferTermination(previous: state, hadCrash: false,
                                                         config: MonitorConfig(token: "t", release: "0.1.1", build: "13")))
        var background = state; background.state = "background"
        XCTAssertFalse(MooMonitor.shouldInferTermination(previous: background, hadCrash: false, config: config))
        XCTAssertFalse(MooMonitor.shouldInferTermination(previous: nil, hadCrash: false, config: config))
    }
}
