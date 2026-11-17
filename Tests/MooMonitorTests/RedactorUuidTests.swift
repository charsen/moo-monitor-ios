import XCTest
@testable import MooMonitor

final class RedactorUuidTests: XCTestCase {
    func testImageUUIDSurvivesRedaction() {
        let uuid = "aaaaaaaa111122223333444444444444"
        let cleaned = Redactor.payload(["frames": [
            ["image_uuid": uuid, "offset": 123],
            ["image_uuid": "bbbbbbbb555566667777888888888888", "offset": 9]
        ]])
        let frames = cleaned["frames"] as? [[String: Any]]
        XCTAssertEqual(frames?.count, 2)
        XCTAssertEqual(frames?[0]["image_uuid"] as? String, uuid)
        XCTAssertEqual(frames?[1]["image_uuid"] as? String, "bbbbbbbb555566667777888888888888")
    }
}
