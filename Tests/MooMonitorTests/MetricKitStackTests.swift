import XCTest
@testable import MooMonitor

final class MetricKitStackTests: XCTestCase {
    private let json = """
    {"callStacks":[
      {"threadAttributed":false,"callStackRootFrames":[{"binaryUUID":"99999999-0000-0000-0000-000000000000","offsetIntoBinaryTextSegment":1}]},
      {"threadAttributed":true,"callStackRootFrames":[
        {"binaryUUID":"AAAAAAAA-1111-2222-3333-444444444444","offsetIntoBinaryTextSegment":100,
         "subFrames":[{"binaryUUID":"BBBBBBBB-5555-6666-7777-888888888888","offsetIntoBinaryTextSegment":200}]}
      ]}
    ]}
    """.data(using: .utf8)!

    func testParsesAttributedThreadFlattenedAndCompact() {
        let frames = MetricKitStackDecoder.frames(fromJSON: json, limit: 64)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0]["image_uuid"] as? String, "aaaaaaaa111122223333444444444444")
        XCTAssertEqual(frames[0]["offset"] as? Int, 100)
        XCTAssertEqual(frames[1]["image_uuid"] as? String, "bbbbbbbb555566667777888888888888")
        XCTAssertEqual(frames[1]["offset"] as? Int, 200)
    }
    func testLimitAndAppFlag() {
        let frames = MetricKitStackDecoder.frames(fromJSON: json, limit: 1, appUUID: "aaaaaaaa111122223333444444444444")
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0]["app"] as? Bool, true)
    }
    func testInvalidJSONYieldsEmpty() {
        XCTAssertTrue(MetricKitStackDecoder.frames(fromJSON: Data("not json".utf8)).isEmpty)
    }
}
