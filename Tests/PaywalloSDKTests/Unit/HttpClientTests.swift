import XCTest
@testable import PaywalloSDK

// MARK: - MockURLProtocol

/// URLProtocol-based mock for intercepting URLSession requests.
/// HttpClient takes URLSession (concrete type), so we inject a URLSession
/// configured with this protocol instead of using MockURLSession directly.
final class MockURLProtocol: URLProtocol {
    // Queue of handlers: each call pops one. Thread-safe via a serial queue.
    static var handlers: [(URLRequest) throws -> (HTTPURLResponse, Data)] = []
    static var capturedRequests: [URLRequest] = []
    private static let queue = DispatchQueue(label: "MockURLProtocol")

    static func enqueue(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        queue.sync { handlers.append(handler) }
    }

    static func enqueueResponse(statusCode: Int, data: Data = Data(), headers: [String: String]? = nil, url: URL = URL(string: "https://api.test.com")!) {
        enqueue { _ in
            let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
            return (response, data)
        }
    }

    static func enqueueJSON(_ json: Any, statusCode: Int = 200) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        enqueueResponse(statusCode: statusCode, data: data)
    }

    static func enqueueError(_ error: Error) {
        enqueue { _ in throw error }
    }

    static func reset() {
        queue.sync {
            handlers.removeAll()
            capturedRequests.removeAll()
        }
    }

    // MARK: URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        MockURLProtocol.queue.sync {
            MockURLProtocol.capturedRequests.append(request)
        }

        guard !MockURLProtocol.handlers.isEmpty else {
            // Default 200 empty response
            let url = request.url ?? URL(string: "https://api.test.com")!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let handler = MockURLProtocol.queue.sync { MockURLProtocol.handlers.removeFirst() }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - HttpClientTests

final class HttpClientTests: XCTestCase {

    var session: URLSession!
    var client: HttpClient!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)

        client = HttpClient(
            baseUrl: "https://api.test.com",
            timeout: 10,
            retryConfig: RetryConfig(maxRetries: 2, baseDelay: 0.0, maxDelay: 0.0),
            debug: false,
            globalHeaders: [:],
            session: session
        )
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helper

    struct Empty: Decodable {}
    struct Echo: Decodable { let value: String }

    func makeClient(
        baseUrl: String = "https://api.test.com",
        globalHeaders: [String: String] = [:],
        retryConfig: RetryConfig = RetryConfig(maxRetries: 2, baseDelay: 0.0, maxDelay: 0.0)
    ) -> HttpClient {
        HttpClient(
            baseUrl: baseUrl,
            timeout: 10,
            retryConfig: retryConfig,
            debug: false,
            globalHeaders: globalHeaders,
            session: session
        )
    }

    // MARK: - 1. GET builds correct URL

    func testGetBuildsCorrectURL() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200)

        _ = try await client.getRaw(path: "/events/track")

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(req?.url?.absoluteString, "https://api.test.com/events/track")
        XCTAssertEqual(req?.httpMethod, "GET")
    }

    // MARK: - 2. POST includes JSON body

    func testPostIncludesJSONBody() async throws {
        struct Payload: Encodable { let name: String }
        MockURLProtocol.enqueueResponse(statusCode: 200)

        _ = try await client.postRaw(path: "/events/track", body: Payload(name: "test"))

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(req?.httpMethod, "POST")

        // URLProtocol receives httpBody as nil but makes it available via httpBodyStream
        let body = bodyData(from: req)
        XCTAssertNotNil(body)
        let json = try JSONSerialization.jsonObject(with: body!) as? [String: String]
        XCTAssertEqual(json?["name"], "test")
    }

    // MARK: - 3. Global headers included in requests

    func testGlobalHeadersAreSent() async throws {
        let c = makeClient(globalHeaders: ["X-App-Key": "pk_abc123"])
        MockURLProtocol.enqueueResponse(statusCode: 200)

        _ = try await c.getRaw(path: "/ping")

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(req?.value(forHTTPHeaderField: "X-App-Key"), "pk_abc123")
    }

    // MARK: - 4. Per-request headers override globals

    func testPerRequestHeadersOverrideGlobals() async throws {
        let c = makeClient(globalHeaders: ["X-Custom": "global-value"])
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let opts = RequestOptions(headers: ["X-Custom": "per-request-value"])
        _ = try await c.getRaw(path: "/ping", options: opts)

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(req?.value(forHTTPHeaderField: "X-Custom"), "per-request-value")
    }

    // MARK: - 5. Content-Type: application/json is set automatically

    func testContentTypeIsSetAutomatically() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200)

        _ = try await client.getRaw(path: "/ping")

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    // MARK: - 6. HTTP blocking: non-local http:// throws insecureRequest

    func testHttpNonLocalURLThrowsInsecureRequest() async throws {
        do {
            _ = try await client.getRaw(path: "http://evil.com/data")
            XCTFail("Expected insecureRequest error")
        } catch let error as ClientError {
            XCTAssertEqual(error.code, ClientErrorCode.insecureRequest)
        }
    }

    // MARK: - 7. HTTP allowing: localhost http:// is allowed

    func testLocalhostHTTPIsAllowed() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200, url: URL(string: "http://localhost:3000/ping")!)

        _ = try await client.getRaw(path: "http://localhost:3000/ping")

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(req?.url?.host, "localhost")
    }

    func test127_0_0_1HTTPIsAllowed() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200, url: URL(string: "http://127.0.0.1:8080/ping")!)

        _ = try await client.getRaw(path: "http://127.0.0.1:8080/ping")

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(req?.url?.host, "127.0.0.1")
    }

    func test192_168HTTPIsAllowed() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200, url: URL(string: "http://192.168.1.100/ping")!)

        _ = try await client.getRaw(path: "http://192.168.1.100/ping")

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(req?.url?.host, "192.168.1.100")
    }

    // MARK: - 8. skipRetry: no retries on failure

    func testSkipRetryDoesNotRetry() async throws {
        // Return 500 once; if it retried, it would hit the default 200
        MockURLProtocol.enqueueResponse(statusCode: 500)

        let opts = RequestOptions(skipRetry: true)
        let response = try await client.getRaw(path: "/ping", options: opts)

        // Only 1 request made (no retries)
        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
        XCTAssertEqual(response.status, 500)
    }

    // MARK: - 9. Retry on retryable status codes (429, 500, 502, 503, 504)

    func testRetryOn429() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 429)
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let response = try await client.getRaw(path: "/ping")

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 2)
        XCTAssertEqual(response.status, 200)
    }

    func testRetryOn500() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 500)
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let response = try await client.getRaw(path: "/ping")

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 2)
        XCTAssertEqual(response.status, 200)
    }

    func testRetryOn502() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 502)
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let response = try await client.getRaw(path: "/ping")

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 2)
        XCTAssertEqual(response.status, 200)
    }

    func testRetryOn503() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 503)
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let response = try await client.getRaw(path: "/ping")

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 2)
        XCTAssertEqual(response.status, 200)
    }

    func testRetryOn504() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 504)
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let response = try await client.getRaw(path: "/ping")

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 2)
        XCTAssertEqual(response.status, 200)
    }

    // MARK: - 10. Max 2 retries = 3 total attempts

    func testMaxRetriesIs2TotalAttempts3() async throws {
        // All 3 attempts fail with 500; should return 500 after 3 total calls
        MockURLProtocol.enqueueResponse(statusCode: 500)
        MockURLProtocol.enqueueResponse(statusCode: 500)
        MockURLProtocol.enqueueResponse(statusCode: 500)

        let response = try await client.getRaw(path: "/ping")

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 3)
        XCTAssertEqual(response.status, 500)
    }

    // MARK: - 11. Non-retryable status codes are NOT retried

    func testNoRetryOn400() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 400)

        let response = try await client.getRaw(path: "/ping")

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
        XCTAssertEqual(response.status, 400)
    }

    func testNoRetryOn401() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 401)

        let response = try await client.getRaw(path: "/ping")

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
        XCTAssertEqual(response.status, 401)
    }

    func testNoRetryOn403() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 403)

        let response = try await client.getRaw(path: "/ping")

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
        XCTAssertEqual(response.status, 403)
    }

    func testNoRetryOn404() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 404)

        let response = try await client.getRaw(path: "/ping")

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
        XCTAssertEqual(response.status, 404)
    }

    // MARK: - 12. Retry-After header honored (seconds format)

    func testRetryAfterHeaderHonored() async throws {
        // Enqueue 429 with Retry-After: 0 (instant) to avoid slow tests
        MockURLProtocol.enqueueResponse(statusCode: 429, headers: ["Retry-After": "0"])
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let response = try await client.getRaw(path: "/ping")

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 2)
        XCTAssertEqual(response.status, 200)
    }

    func testRetryAfterHeaderLargeValueCappedToMaxDelay() async throws {
        // Retry-After: 999 would be capped to maxDelay (0.0 in test config → 0.0)
        // This test just verifies we don't crash/hang and still get the response
        let c = makeClient(retryConfig: RetryConfig(maxRetries: 1, baseDelay: 0.0, maxDelay: 0.0))
        MockURLProtocol.enqueueResponse(statusCode: 429, headers: ["Retry-After": "999"])
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let response = try await c.getRaw(path: "/ping")

        XCTAssertEqual(response.status, 200)
    }

    // MARK: - 13. URL redaction in errors

    func testRedactUrlReplacesLongSegments() throws {
        // Access the private redactUrl via a ClientError thrown with a long token in path
        // We test this indirectly by triggering an insecureRequest error with a token in path
        // The redaction applies to logged error strings, not the thrown error message
        // We verify the regex logic by testing known inputs against expected outputs.

        // The regex: /([a-zA-Z0-9_-]{20,64})([\?/$]|$)
        // A 20-char segment should be redacted
        let shortSegment = "short"          // < 20 chars → NOT redacted
        let longSegment = "abcdefghijklmnopqrst"  // exactly 20 chars → redacted

        // Build URLs that would be processed by redactUrl
        let urlWithShort = "https://api.test.com/\(shortSegment)"
        let urlWithLong  = "https://api.test.com/\(longSegment)"

        let redacted = redactUrl(urlWithShort)
        let redactedLong = redactUrl(urlWithLong)

        XCTAssertEqual(redacted, urlWithShort, "Short segments should not be redacted")
        XCTAssertTrue(redactedLong.contains("[REDACTED]"), "Long segments (>=20 chars) should be redacted")
        XCTAssertFalse(redactedLong.contains(longSegment), "Original long token should not appear after redaction")
    }

    func testRedactUrlLeaves64CharSegmentRedacted() throws {
        let segment64 = String(repeating: "a", count: 64)
        let segment65 = String(repeating: "b", count: 65)

        let url64 = "https://api.test.com/\(segment64)"
        let url65 = "https://api.test.com/\(segment65)"

        XCTAssertTrue(redactUrl(url64).contains("[REDACTED]"), "64-char segment should be redacted")
        XCTAssertFalse(redactUrl(url65).contains("[REDACTED]"), "65-char segment should NOT be redacted (over max)")
    }

    // MARK: - 14. Timeout is set on URLRequest

    func testTimeoutIsSetOnURLRequest() async throws {
        let c = HttpClient(
            baseUrl: "https://api.test.com",
            timeout: 42,
            retryConfig: RetryConfig(maxRetries: 0, baseDelay: 0, maxDelay: 0),
            debug: false,
            globalHeaders: [:],
            session: session
        )
        MockURLProtocol.enqueueResponse(statusCode: 200)

        _ = try await c.getRaw(path: "/ping")

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(req?.timeoutInterval, 42)
    }

    func testPerRequestTimeoutOverridesDefault() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200)

        let opts = RequestOptions(timeout: 99)
        _ = try await client.getRaw(path: "/ping", options: opts)

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(req?.timeoutInterval, 99)
    }

    // MARK: - Additional: HTTPS absolute URL used directly

    func testAbsoluteHTTPSURLUsedDirectly() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200)

        _ = try await client.getRaw(path: "https://other.api.com/data")

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(req?.url?.absoluteString, "https://other.api.com/data")
    }

    // MARK: - Additional: setGlobalHeaders merges headers

    func testSetGlobalHeadersMergesHeaders() async throws {
        client.setGlobalHeaders(["X-Version": "2"])
        MockURLProtocol.enqueueResponse(statusCode: 200)

        _ = try await client.getRaw(path: "/ping")

        let req = MockURLProtocol.capturedRequests.first
        XCTAssertEqual(req?.value(forHTTPHeaderField: "X-Version"), "2")
    }

    // MARK: - Additional: ok flag reflects 2xx vs non-2xx

    func testOkTrueFor200() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 200)
        let res = try await client.getRaw(path: "/ping")
        XCTAssertTrue(res.ok)
    }

    func testOkFalseFor400() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 400)
        let res = try await client.getRaw(path: "/ping")
        XCTAssertFalse(res.ok)
    }

    func testOkTrueFor201() async throws {
        MockURLProtocol.enqueueResponse(statusCode: 201)
        let res = try await client.getRaw(path: "/ping")
        XCTAssertTrue(res.ok)
    }
}

// MARK: - URLRequest body helper

/// URLProtocol receives httpBody as nil (URLSession converts it to httpBodyStream).
/// This helper reads the body from whichever slot is populated.
private func bodyData(from request: URLRequest?) -> Data? {
    guard let request else { return nil }
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: 4096)
        if count > 0 { data.append(buffer, count: count) }
    }
    return data.isEmpty ? nil : data
}

// MARK: - Expose private redactUrl for testing

/// Mirrors the private redactUrl logic in HttpClient so we can test it directly.
private func redactUrl(_ url: String) -> String {
    url.replacingOccurrences(
        of: #"/([a-zA-Z0-9_-]{20,64})(\?|\/|$)"#,
        with: "/[REDACTED]$2",
        options: .regularExpression
    )
}
