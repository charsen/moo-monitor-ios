import XCTest
@testable import MooMonitor

final class UploaderTests: XCTestCase {

    private final class StubProtocol: URLProtocol {
        static var status = 200
        static var headers: [String: String] = [:]
        static var responseBody: Data?
        static var bodies: [String] = []
        static var onRequest: (() -> Void)?
        static var delay: TimeInterval = 0

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.onRequest?()
            if let body = request.httpBody ?? request.httpBodyStream.flatMap(Self.readAll) {
                Self.bodies.append(String(data: body, encoding: .utf8) ?? "")
            }
            if Self.delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) { self.complete() }
            } else { complete() }
        }

        private func complete() {
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: Self.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let body = Self.responseBody ?? Self.successBody(Self.bodies.last ?? "{}")
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        private static func successBody(_ text: String) -> Data {
            let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            let records = object?["records"] as? [Any] ?? []
            return try! JSONSerialization.data(withJSONObject: ["ok": true, "results": records.indices.map { ["index": $0, "status": "saved"] as [String: Any] }])
        }

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
        StubProtocol.responseBody = nil
        StubProtocol.bodies = []
        StubProtocol.onRequest = nil
        StubProtocol.delay = 0
    }

    private func uploader() -> Uploader {
        Uploader(
            config: MonitorConfig(endpoint: "https://c.example.com", token: "tok", app: "shuhe"),
            store: store,
            session: session
        )
    }

    func testAppendDuringSendIsNotAcknowledgedAsPartOfOldBatch() async {
        store.append(["event_id": "a"])
        var once = false
        StubProtocol.onRequest = { [self] in
            if !once { once = true; store.append(["event_id": "b"]) }
        }
        let outcome = await uploader().flush()
        XCTAssertEqual(outcome, .sent(2))
        XCTAssertEqual(StubProtocol.bodies.count, 2)
    }

    func testMoreThanThreeBatchesCanContinueWithoutNewCapture() async {
        for i in 0..<180 { store.append(["event_id": "e\(i)"]) }
        let uploader = uploader()
        let first = await uploader.flush()
        XCTAssertEqual(first, .more)
        XCTAssertEqual(store.pending(limit: 200).count, 30)
        let second = await uploader.flush()
        XCTAssertEqual(second, .sent(30))
        XCTAssertEqual(StubProtocol.bodies.count, 4)
    }

    func testChangedTokenRecoversWithoutChangingBuild() async {
        store.append(["event_id": "a"])
        StubProtocol.status = 401
        _ = await uploader().flush()
        StubProtocol.status = 200
        let changed = Uploader(config: MonitorConfig(endpoint: "https://c.example.com", token: "new-token"), store: store, session: session)
        let outcome = await changed.flush()
        XCTAssertEqual(outcome, .sent(1))
    }

    func testDuplicateOrBooleanReceiptIndexesKeepWholeBatch() async {
        for body in [#"{"ok":true,"results":[{"index":0,"status":"saved"},{"index":0,"status":"saved"}]}"#,
                     #"{"ok":true,"results":[{"index":false,"status":"saved"},{"index":1,"status":"saved"}]}"#] {
            store.append(["event_id": "a"]); store.append(["event_id": "b"])
            store.clearRetryState()
            StubProtocol.responseBody = Data(body.utf8)
            _ = await uploader().flush()
            XCTAssertEqual(store.pending(limit: 10).count, 2)
        }
    }

    func testExhaustedRetryAfterSurvivesNewUploader() async {
        let identity = EventStore.identity(MonitorConfig(endpoint: "https://c.example.com", token: "tok"))
        store.setRetryState(.init(attempts: 6, nextAt: Date().timeIntervalSince1970 + 7200, identity: identity))
        store.append(["event_id": "a"])
        let outcome = await uploader().flush()
        XCTAssertEqual(outcome, .retry("backoff"))
        XCTAssertTrue(StubProtocol.bodies.isEmpty)
    }

    func testNewUploaderResetsAttemptsWithoutShorteningRetryAfter() async throws {
        let identity = EventStore.identity(MonitorConfig(endpoint: "https://c.example.com", token: "tok"))
        let deadline = Date().timeIntervalSince1970 + 7200
        store.setRetryState(.init(attempts: 6, nextAt: deadline, reason: "429", identity: identity))
        store.append(["event_id": "original"])
        let current = uploader()
        let outcome = await current.flush()
        XCTAssertEqual(outcome, .retry("backoff"))
        let state = try XCTUnwrap(store.retryState())
        XCTAssertEqual(state.attempts, 0, "The next process must be able to wait without being mistaken for exhausted")
        XCTAssertEqual(state.nextAt, deadline, accuracy: 0.001)
        XCTAssertEqual(state.identity, identity)
        XCTAssertEqual(state.reason, "429")
        XCTAssertTrue(StubProtocol.bodies.isEmpty)
        XCTAssertEqual(store.pending(limit: 10).first?["event_id"] as? String, "original")
    }

    func testNewProcessStartsFreshBudgetButSameUploaderAccumulatesFailures() async throws {
        let identity = EventStore.identity(MonitorConfig(endpoint: "https://c.example.com", token: "tok"))
        store.setRetryState(.init(attempts: 5, nextAt: Date().timeIntervalSince1970 - 1, reason: "http 503", identity: identity))
        store.append(["event_id": "original"])
        StubProtocol.status = 503
        let current = uploader()
        for expected in 1...6 {
            if var state = store.retryState() { state.nextAt = Date().timeIntervalSince1970 - 1; store.setRetryState(state) }
            let outcome = await current.flush()
            XCTAssertEqual(outcome, .retry("http 503"))
            XCTAssertEqual(store.retryState()?.attempts, expected)
        }
        let exhausted = await current.flush()
        XCTAssertEqual(exhausted, .retry("exhausted"))
        XCTAssertEqual(StubProtocol.bodies.count, 6)
        XCTAssertEqual(store.pending(limit: 10).first?["event_id"] as? String, "original")
    }

    func testOversizedResponseKeepsEvidence() async {
        store.append(["event_id": "a"])
        StubProtocol.responseBody = Data(repeating: 32, count: 128 * 1024 + 1)
        let outcome = await uploader().flush()
        XCTAssertEqual(outcome, .retry("response too large"))
        XCTAssertEqual(store.pending(limit: 10).count, 1)
    }

    func testByteBudgetUsesExactEnvelopeWithoutRepeatedlyDroppingGoodNeighbors() async {
        for i in 0..<10 { store.append(["event_id": "e\(i)", "payload": ["text": String(repeating: "汉", count: 10_000)]]) }
        let outcome = await uploader().flush()
        XCTAssertEqual(outcome, .sent(10))
        XCTAssertTrue(StubProtocol.bodies.allSatisfy { $0.utf8.count <= 512 * 1024 })
    }

    func testUnreadableQueueRetainsSourceAndReportsRetry() async throws {
        let url = store.dir.appendingPathComponent("queue.jsonl")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let outcome = await uploader().flush()
        XCTAssertEqual(outcome, .retry("queue read"))
        var directory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &directory))
        XCTAssertTrue(directory.boolValue)
    }

    func testConcurrentFlushDoesNotSendSameSnapshotTwice() async {
        store.append(["event_id": "a"])
        StubProtocol.delay = 0.1
        let uploader = uploader()
        async let first = uploader.flush()
        async let second = uploader.flush()
        let outcomes = await [first, second]
        XCTAssertTrue(outcomes.contains(.sent(1)))
        XCTAssertTrue(outcomes.contains(.retry("busy")))
        XCTAssertEqual(StubProtocol.bodies.count, 1)
    }

    func testIncompleteSuccessReceiptKeepsBatch() async {
        store.append(["event_id": "a"])
        StubProtocol.responseBody = Data(#"{"ok":true,"results":[]}"#.utf8)
        _ = await uploader().flush()
        XCTAssertEqual(store.pending(limit: 10).count, 1)
    }

    func testPartialReceiptOnlyAcknowledgesTerminalRecords() async {
        store.append(["event_id": "a"])
        store.append(["event_id": "b"])
        StubProtocol.responseBody = Data(#"{"ok":true,"results":[{"index":0,"status":"saved"},{"index":1,"status":"skipped","retryable":true}]}"#.utf8)
        _ = await uploader().flush()
        XCTAssertEqual(store.pending(limit: 10).compactMap { $0["event_id"] as? String }, ["b"])
    }

    func testUnauthorizedKeepsQueuedEvidence() async {
        store.append(["event_id": "a"])
        StubProtocol.status = 401
        _ = await uploader().flush()
        XCTAssertEqual(store.pending(limit: 10).count, 1)
    }

    func testUnknownHTTPStatusDoesNotDiscardEvidence() async {
        store.append(["event_id": "a"])
        StubProtocol.status = 302
        _ = await uploader().flush()
        XCTAssertEqual(store.pending(limit: 10).count, 1)
    }

    func testBadQueueLineCannotShiftAcknowledgement() async throws {
        let text = "bad-json\n{\"event_id\":\"a\"}\n{\"event_id\":\"b\"}\n"
        try text.write(to: store.dir.appendingPathComponent("queue.jsonl"), atomically: true, encoding: .utf8)
        StubProtocol.responseBody = Data(#"{"ok":true,"results":[{"index":0,"status":"saved"},{"index":1,"status":"saved"}]}"#.utf8)
        _ = await uploader().flush()
        XCTAssertTrue(store.pending(limit: 10).isEmpty)
        XCTAssertEqual(StubProtocol.bodies.count, 1)
    }

    func testServerRetryAfterIsNotShortenedToOneHour() async {
        store.append(["event_id": "a"])
        StubProtocol.status = 429
        StubProtocol.headers = ["Retry-After": "7200"]
        _ = await uploader().flush()
        XCTAssertGreaterThan(store.retryState()?.nextAt ?? 0, Date().timeIntervalSince1970 + 7100)
    }

    func testSuccessDrainsQueue() async {
        store.append(["event_id": "a"])
        store.append(["event_id": "b"])

        let outcome = await uploader().flush()

        XCTAssertEqual(outcome, .sent(2))
        XCTAssertTrue(store.pending(limit: 10).isEmpty)
        XCTAssertTrue(StubProtocol.bodies.first?.contains("moo-monitor-ios") ?? false)
    }

    func testUnauthorizedPreservesQueueAndPersistsDisabled() async {
        store.append(["event_id": "a"])
        StubProtocol.status = 403

        let outcome = await uploader().flush()

        XCTAssertEqual(outcome, .disabled)
        XCTAssertEqual(store.pending(limit: 10).count, 1)
        XCTAssertNotNil(store.disabledStamp())
    }

    func testDisabledStampStopsLaterSends() async {
        store.append(["event_id": "a"])
        store.setDisabledStamp(config: MonitorConfig(endpoint: "https://c.example.com", token: "tok", app: "shuhe"))

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

        XCTAssertEqual(outcome, .retry("invalid response"))
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
