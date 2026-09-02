import Foundation

/// A certificate/TLS failure is not transient — "certificate issues are not transient".
/// Retrying it burns battery and radio for an outcome that cannot change, so both retry
/// layers (this one and `runWithRetryPolicy`) stop on the first attempt and hand the
/// request straight to the backstop: `PendingRetry` for critical, drop for normal.
enum SslError {
    private static let urlErrorCodes: Set<URLError.Code> = [
        .secureConnectionFailed,
        .serverCertificateHasBadDate,
        .serverCertificateUntrusted,
        .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid,
        .clientCertificateRejected,
        .clientCertificateRequired,
    ]

    /// Message fallbacks for the errors that reach us as plain `NSError` (proxies, custom
    /// `URLSession` delegates, pinning libraries) instead of a typed `URLError`.
    private static let messagePatterns = [
        "certificate",
        "cert_",
        "x509",
        " ssl",
        "tls handshake",
        "unable to verify the first certificate",
        "self signed certificate",
        "err_cert",
    ]

    static func matches(_ error: Error) -> Bool {
        if let urlError = error as? URLError, urlErrorCodes.contains(urlError.code) { return true }
        let message = error.localizedDescription.lowercased()
        return messagePatterns.contains { message.contains($0) }
    }
}

/// RFC 7231 IMF-fixdate parser for the `Retry-After` header, shared by the two retry
/// layers (this client's per-request loop and `runWithRetryPolicy`).
enum HttpDate {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static func parse(_ value: String) -> Date? {
        formatter.date(from: value)
    }
}

public struct HttpResponse<T> {
    public let ok: Bool
    public let status: Int
    public let data: T
    public let headers: [String: String]
}

public struct RetryConfig {
    public var maxRetries: Int = 2
    public var baseDelay: TimeInterval = 0.5  // 500ms
    public var maxDelay: TimeInterval = 4.0   // 4000ms
    public var retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]

    public init(
        maxRetries: Int = 2,
        baseDelay: TimeInterval = 0.5,
        maxDelay: TimeInterval = 4.0,
        retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]
    ) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.retryableStatusCodes = retryableStatusCodes
    }
}

public struct RequestOptions {
    public var method: String = "GET"
    public var headers: [String: String]?
    public var body: Data?
    public var skipRetry: Bool = false
    public var timeout: TimeInterval?

    public init(method: String = "GET", headers: [String: String]? = nil, body: Data? = nil, skipRetry: Bool = false, timeout: TimeInterval? = nil) {
        self.method = method
        self.headers = headers
        self.body = body
        self.skipRetry = skipRetry
        self.timeout = timeout
    }
}

public final class HttpClient {
    private var baseUrl: String
    private var timeout: TimeInterval
    private var retryConfig: RetryConfig
    private var debug: Bool
    private var globalHeaders: [String: String]
    private let session: URLSession

    public init(
        baseUrl: String,
        timeout: TimeInterval = PaywalloConstants.httpClientTimeout,
        retryConfig: RetryConfig = RetryConfig(),
        debug: Bool = false,
        globalHeaders: [String: String] = [:],
        session: URLSession = .shared
    ) {
        self.baseUrl = baseUrl
        self.timeout = timeout
        self.retryConfig = retryConfig
        self.debug = debug
        self.globalHeaders = globalHeaders
        self.session = session
    }

    public func setGlobalHeaders(_ headers: [String: String]) {
        for (key, value) in headers {
            globalHeaders[key] = value
        }
    }

    public func setDebug(_ debug: Bool) {
        self.debug = debug
    }

    public func getBaseUrl() -> String {
        baseUrl
    }

    // MARK: - GET / POST convenience

    public func get<T: Decodable>(path: String, options: RequestOptions? = nil) async throws -> HttpResponse<T> {
        var opts = options ?? RequestOptions()
        opts.method = "GET"
        return try await request(path: path, options: opts)
    }

    public func post<T: Decodable>(path: String, body: Encodable? = nil, options: RequestOptions? = nil) async throws -> HttpResponse<T> {
        var opts = options ?? RequestOptions()
        opts.method = "POST"
        if let body = body, opts.body == nil {
            opts.body = try JSONEncoder().encode(body)
        }
        return try await request(path: path, options: opts)
    }

    // Raw data versions for when you don't need Decodable
    public func getRaw(path: String, options: RequestOptions? = nil) async throws -> HttpResponse<Data> {
        var opts = options ?? RequestOptions()
        opts.method = "GET"
        return try await requestRaw(path: path, options: opts)
    }

    public func postRaw(path: String, body: Encodable? = nil, options: RequestOptions? = nil) async throws -> HttpResponse<Data> {
        var opts = options ?? RequestOptions()
        opts.method = "POST"
        if let body = body, opts.body == nil {
            opts.body = try JSONEncoder().encode(body)
        }
        return try await requestRaw(path: path, options: opts)
    }

    // MARK: - Core request

    public func request<T: Decodable>(path: String, options: RequestOptions) async throws -> HttpResponse<T> {
        let rawResponse = try await requestRaw(path: path, options: options)
        let decoded = try JSONDecoder().decode(T.self, from: rawResponse.data)
        return HttpResponse(ok: rawResponse.ok, status: rawResponse.status, data: decoded, headers: rawResponse.headers)
    }

    public func requestRaw(path: String, options: RequestOptions) async throws -> HttpResponse<Data> {
        let url = try buildUrl(path)
        let urlRequest = buildURLRequest(url: url, options: options)

        if options.skipRetry {
            return try await executeRequest(urlRequest)
        }

        return try await executeWithRetry(urlRequest, options: options)
    }

    // MARK: - Retry logic

    private func executeWithRetry(_ request: URLRequest, options: RequestOptions) async throws -> HttpResponse<Data> {
        var attempt = 0
        var lastError: Error?

        while attempt <= retryConfig.maxRetries {
            do {
                let response = try await executeRequest(request)

                if retryConfig.retryableStatusCodes.contains(response.status) {
                    if attempt < retryConfig.maxRetries {
                        attempt += 1
                        let delay = calculateDelayForResponse(attempt: attempt, headers: response.headers)
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                }

                return response
            } catch {
                lastError = error

                if isNetworkError(error) && attempt < retryConfig.maxRetries {
                    attempt += 1
                    let delay = calculateDelay(attempt: attempt)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }

                throw error
            }
        }

        throw lastError ?? ClientError(code: ClientErrorCode.unknown, message: "Max retries exceeded")
    }

    private func executeRequest(_ request: URLRequest) async throws -> HttpResponse<Data> {
        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ClientError(code: ClientErrorCode.unknown, message: "Invalid response type")
            }

            var headers: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                if let k = key as? String, let v = value as? String {
                    headers[k.lowercased()] = v
                }
            }

            return HttpResponse(
                ok: (200..<300).contains(httpResponse.statusCode),
                status: httpResponse.statusCode,
                data: data,
                headers: headers
            )
        } catch {
            log("Request failed", ["url": redactUrl(request.url?.absoluteString ?? ""), "error": error.localizedDescription])
            throw error
        }
    }

    // MARK: - URL building

    private func buildUrl(_ path: String) throws -> URL {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            if path.hasPrefix("http://") {
                let isLocalDev = path.range(of: #"^http://(localhost|127\.0\.0\.1|192\.168\.\d{1,3}\.\d{1,3})"#, options: .regularExpression) != nil
                if !isLocalDev {
                    let sanitized = path.components(separatedBy: "?").first ?? path
                    log("Blocked http:// request — only HTTPS is allowed in production:", sanitized)
                    throw ClientError(code: ClientErrorCode.insecureRequest, message: "Insecure HTTP request blocked: \(sanitized)")
                }
            }
            guard let url = URL(string: path) else {
                throw ClientError(code: ClientErrorCode.unknown, message: "Invalid URL: \(path)")
            }
            return url
        }

        guard let url = URL(string: "\(baseUrl)\(path)") else {
            throw ClientError(code: ClientErrorCode.unknown, message: "Invalid URL: \(baseUrl)\(path)")
        }
        return url
    }

    private func buildURLRequest(url: URL, options: RequestOptions) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = options.method
        request.timeoutInterval = options.timeout ?? timeout

        // Default headers
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Global headers
        for (key, value) in globalHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Per-request headers (override globals)
        if let headers = options.headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        request.httpBody = options.body

        return request
    }

    // MARK: - Retry helpers

    private func isNetworkError(_ error: Error) -> Bool {
        // Checked first: a TLS failure arrives as a `URLError` too, and treating it as a
        // transient network error retried the same doomed handshake three times per request.
        if SslError.matches(error) { return false }
        if error is URLError { return true }
        let message = error.localizedDescription.lowercased()
        return ["network", "timeout", "connection"].contains(where: message.contains)
    }

    private func calculateDelay(attempt: Int) -> TimeInterval {
        let exponentialDelay = retryConfig.baseDelay * pow(2.0, Double(attempt - 1))
        let jitter = Double.random(in: 0...(0.3 * exponentialDelay))
        return min(exponentialDelay + jitter, retryConfig.maxDelay)
    }

    private func calculateDelayForResponse(attempt: Int, headers: [String: String]) -> TimeInterval {
        // Honor Retry-After header
        if let retryAfter = headers["retry-after"] {
            // Try seconds format
            if let seconds = Double(retryAfter), seconds > 0 {
                return min(seconds, retryConfig.maxDelay)
            }
            // Try HTTP-date format
            if let date = HttpDate.parse(retryAfter) {
                let interval = date.timeIntervalSinceNow
                if interval > 0 { return min(interval, retryConfig.maxDelay) }
            }
        }
        return calculateDelay(attempt: attempt)
    }

    // MARK: - Logging

    private func redactUrl(_ url: String) -> String {
        url.replacingOccurrences(
            of: #"/([a-zA-Z0-9_-]{20,64})(\?|\/|$)"#,
            with: "/[REDACTED]$2",
            options: .regularExpression
        )
    }

    private func log(_ message: String, _ context: Any?...) {
        guard debug else { return }
        print("[Paywallo:Http] \(message)", context.compactMap { $0 })
    }
}
