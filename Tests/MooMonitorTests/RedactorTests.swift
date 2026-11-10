import XCTest
@testable import MooMonitor

final class RedactorTests: XCTestCase {
    func testShortCredentialsAndPrivateFilenameAreRemoved() {
        let out = Redactor.scrub("token=short pwd: tiny Bearer abc.def.ghi file:///private/var/book title.epub")!
        XCTAssertFalse(out.contains("short"))
        XCTAssertFalse(out.contains("tiny"))
        XCTAssertFalse(out.contains("abc.def.ghi"))
        XCTAssertFalse(out.contains("book title.epub"))
    }

    func testLongSourceIdentifierRemainsReadable() {
        let symbol = "ShuheApple.ReaderSelectionCoordinatorWithLongClassName.persistCurrentSelectionForDocumentBoundary"
        XCTAssertEqual(Redactor.scrub(symbol), symbol)
    }
    func testSharedObjectGraphAndUnsupportedDescriptionsStayBounded() throws {
        final class PrivateObject: NSObject {
            override var description: String { XCTFail("must not describe host objects"); return "private" }
        }
        var shared: [String: Any] = ["secret": "tiny", "value": String(repeating: "汉", count: 20_000)]
        for _ in 0..<8 { shared = Dictionary(uniqueKeysWithValues: (0..<16).map { ("k\($0)", shared) }) }
        let payload = Redactor.payload(["graph": shared, "object": PrivateObject(), "nan": Double.nan])
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertLessThanOrEqual(data.count, 8 * 1024)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("tiny"))
    }

    func testQuotedAndPrefixedCredentialsAreFullyRemoved() {
        let text = #"db_password = "two secret words" token='tiny value' {"authorization":"short-token"}"#
        let scrubbed = Redactor.scrub(text) ?? ""
        for secret in ["two secret words", "tiny value", "short-token"] {
            XCTAssertFalse(scrubbed.contains(secret), scrubbed)
        }
    }

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
