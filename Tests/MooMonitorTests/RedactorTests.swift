import XCTest
@testable import MooMonitor

final class RedactorTests: XCTestCase {
    func testSharedCrossSDKCorpus() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "cross-sdk-redaction", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        for row in fixture["cases"] as! [[String: Any]] {
            let out = Redactor.scrub(row["input"] as? String) ?? ""
            for secret in row["forbidden"] as! [String] { XCTAssertFalse(out.contains(secret), row["name"] as! String) }
            XCTAssertTrue(out.contains(row["keep"] as! String), row["name"] as! String)
        }
    }

    func testRedactsWholeCredentialBeforeOutputAndPayloadLimits() {
        let jwt = "eyJ" + String(repeating: "A", count: 40_000) + ".payload.signature"
        XCTAssertFalse((Redactor.scrub(jwt) ?? "").contains("eyJAAA"))
        let shortJWT = "eyJ" + String(repeating: "A", count: 3_000) + ".payload.signature"
        let data = Redactor.payload(["note": shortJWT, "key " + shortJWT: "ok"])
        XCTAssertFalse(String(describing: data).contains("eyJAAA"))
        XCTAssertEqual(Redactor.scrub(String(repeating: "x", count: 65_537)), "[truncated]")
    }

    func testEscapedQuotedCredentialsDoNotExposeTheirTail() {
        let text = #"password="first \"second\" final-secret" keep=visible"#
        let out = Redactor.scrub(text) ?? ""
        XCTAssertFalse(out.contains("final-secret"))
        XCTAssertTrue(out.contains("keep=visible"))
    }

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
