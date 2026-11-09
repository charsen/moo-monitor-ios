import XCTest
@testable import MooMonitor

final class RedactorTests: XCTestCase {
    func testQuerySecretsAreMasked() {
        let out = Redactor.scrub("GET https://api.example.com/x?token=abcdef&page=2")!
        XCTAssertFalse(out.contains("abcdef"))
        XCTAssertTrue(out.contains("[url]"))
    }

    func testContainerPathCollapsed() {
        let out = Redactor.scrub("/var/mobile/Containers/Data/Application/1A2B-3C4D/Library/a.db")!
        XCTAssertTrue(out.hasPrefix("~"))
    }

    func testPlainMessageUntouched() {
        XCTAssertEqual(Redactor.scrub("nil at Reader"), "nil at Reader")
    }
}
