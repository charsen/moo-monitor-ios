import XCTest
@testable import MooMonitor

final class UploaderTests: XCTestCase {

    private final class StubProtocol: URLProtocol {
        static var status = 200
        static var headers: [String: String] = [:]
        static var responseBody = Data("{}".utf8)
        static var bodies: [String] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            if let body = request.httpBody ?? request.httpBodyStream.flatMap(Self.readAll) {
                Self.bodies.append(String(data: body, encoding: .utf8) ?? "")
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: Self.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.responseBody)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        private static func readAll(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        }
    }

    private var store: EventStore!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moo-monitor-upload-\(UUID().uuidString)", isDirectory: true)
        store = EventStore(directory: dir, config: MonitorConfig(token: "tok", app: "shuhe"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: config)
        StubProtocol.status = 200
        StubProtocol.headers = [:]
        StubProtocol.responseBody = Data("{}".utf8)
        StubProtocol.bodies = []
    }

    private func uploader() -> Uploader {
        Uploader(
            config: MonitorConfig(endpoint: "https://c.example.com", token: "tok", app: "shuhe"),
            store: store,
            session: session
        )
    }

    func testSuccessDrainsQueue() async {
        store.append(["event_id": "a"])
        store.append(["event_id": "b"])

        let outcome = await uploader().flush()

        XCTAssertEqual(outcome, .sent(2))
        XCTAssertTrue(store.pending(limit: 10).isEmpty)
        XCTAssertTrue(StubProtocol.bodies.first?.contains("moo-monitor-ios") ?? false)
    }

    func testUnauthorizedClearsQueueAndPersistsDisabled() async {
        store.append(["event_id": "a"])
        StubProtocol.status = 403

        let outcome = await uploader().flush()

        XCTAssertEqual(outcome, .disabled)
        XCTAssertEqual(store.pending(limit: 10).count, 0)
        XCTAssertNotNil(store.disabledStamp())
    }

    func testDisabledStampStopsLaterSends() async {
        store.append(["event_id": "a"])
        store.setDisabledStamp(release: "", build: "")

        let outcome = await uploader().flush()

        XCTAssertEqual(outcome, .disabled)
        XCTAssertTrue(StubProtocol.bodies.isEmpty)
    }

    func testRateLimitUsesRetryAfter() async {
        store.append(["event_id": "a"])
        StubProtocol.status = 429
        StubProtocol.headers = ["Retry-After": "120"]

        let outcome = await uploader().flush()

        XCTAssertEqual(outcome, .retry("429"))
        XCTAssertEqual(store.pending(limit: 10).count, 1)
        let state = store.retryState()
        XCTAssertEqual(state?.attempts, 1)
        XCTAssertEqual(state?.reason, "429")
        XCTAssertGreaterThan(state?.nextAt ?? 0, Date().timeIntervalSince1970 + 60)
    }

    func testBackoffSkipsImmediateRetry() async {
        store.append(["event_id": "a"])
        StubProtocol.status = 500
        _ = await uploader().flush()

        StubProtocol.status = 200
        let sentBefore = StubProtocol.bodies.count
        let outcome = await uploader().flush()

        XCTAssertEqual(outcome, .retry("backoff"))
        XCTAssertEqual(StubProtocol.bodies.count, sentBefore)
        XCTAssertEqual(store.pending(limit: 10).count, 1)
    }

    func testOkFalseKeepsBatch() async {
        store.append(["event_id": "a"])
        StubProtocol.responseBody = Data(#"{"ok":false}"#.utf8)

        let outcome = await uploader().flush()

        XCTAssertEqual(outcome, .retry("ok=false"))
        XCTAssertEqual(store.pending(limit: 10).count, 1)
    }

    func testRejectedDropsBatch() async {
        store.append(["event_id": "bad"])
        StubProtocol.status = 422

        _ = await uploader().flush()

        XCTAssertTrue(store.pending(limit: 10).isEmpty)
    }

    func testServerErrorRetries() async {
        store.append(["event_id": "a"])
        StubProtocol.status = 500

        let outcome = await uploader().flush()

        XCTAssertEqual(outcome, .retry("http 500"))
        XCTAssertEqual(store.pending(limit: 10).count, 1)
    }

    func testEmptyQueueIsNoop() async {
        let outcome = await uploader().flush()

        XCTAssertEqual(outcome, .nothing)
        XCTAssertTrue(StubProtocol.bodies.isEmpty)
    }
}
