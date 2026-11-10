import XCTest
import MooMonitorCrash
@testable import MooMonitor

final class SignalTests: XCTestCase {
    func testNativeFaultsTerminateAndProduceBoundedFrames() throws {
        for action in ["segv", "trap", "abort", "reset", "disabled"] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let path = dir.appendingPathComponent("crash.bin")
            if action == "reset" { try Data(repeating: 0, count: 10).write(to: path) }
            let process = Process()
            process.executableURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("MonitorCrashProbe")
            process.arguments = [path.path, action]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationReason, .uncaughtSignal, action)
            XCTAssertNotEqual(process.terminationStatus, 0, action)
            let frames = EventStore(directory: dir, config: MonitorConfig(token: "fixture")).crashFrames()
            if action == "disabled" { XCTAssertTrue(frames.isEmpty); continue }
            XCTAssertEqual(frames.count, 1, action)
            XCTAssertLessThanOrEqual(frames.first?.depth ?? 100, 2)
            if ["segv", "trap"].contains(action) { XCTAssertGreaterThan(frames.first?.depth ?? 0, 0) }
        }
    }

    func testCorruptFrameDoesNotHideLaterValidCrash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var bad = moo_crash_frame(), good = moo_crash_frame()
        bad.magic = 0
        good.magic = MOO_CRASH_MAGIC; good.version = UInt16(MOO_CRASH_VERSION); good.sig = SIGBUS
        let data = withUnsafeBytes(of: &bad) { Data($0) } + withUnsafeBytes(of: &good) { Data($0) }
        try data.write(to: dir.appendingPathComponent("crash.bin"))
        let frames = EventStore(directory: dir, config: MonitorConfig(token: "fixture")).crashFrames()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.sig, SIGBUS)
    }

    func testStartupBoundsRawCrashFileBeforeOpeningSignalDescriptor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var data = Data()
        for i in 0..<100 {
            var frame = moo_crash_frame()
            frame.magic = MOO_CRASH_MAGIC; frame.version = UInt16(MOO_CRASH_VERSION)
            frame.timestamp_ms = UInt64(i)
            data.append(withUnsafeBytes(of: &frame) { Data($0) })
        }
        let file = dir.appendingPathComponent("crash.bin")
        try data.write(to: file)
        let store = EventStore(directory: dir, config: MonitorConfig(token: "fixture"))
        XCTAssertTrue(store.prepareCrashFile())
        XCTAssertEqual(try Data(contentsOf: file).count, 20 * MemoryLayout<moo_crash_frame>.stride)
        XCTAssertEqual(store.crashFrames().map(\.timestamp_ms), Array(80..<100).map(UInt64.init))
        XCTAssertEqual(store.dropped, 80)
    }

    func testInvalidFrameVersionAndDepthAreRejectedBeforeResolution() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var frame = moo_crash_frame()
        frame.magic = MOO_CRASH_MAGIC; frame.version = 99
        let file = dir.appendingPathComponent("crash.bin")
        try withUnsafeBytes(of: &frame) { try Data($0).write(to: file) }
        let store = EventStore(directory: dir, config: MonitorConfig(token: "fixture"))
        XCTAssertTrue(store.crashFrames().isEmpty)
        frame.version = UInt16(MOO_CRASH_VERSION); frame.depth = UInt32.max
        try withUnsafeBytes(of: &frame) { try Data($0).write(to: file) }
        XCTAssertTrue(store.crashFrames().isEmpty)
    }
}
