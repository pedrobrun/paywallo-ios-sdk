import Foundation
@testable import PaywalloSDK

public protocol URLSessionProtocol {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}

public final class MockURLSession: URLSessionProtocol {
    public var responses: [(Data, URLResponse)] = []
    public var errors: [Error] = []
    public var requestsReceived: [URLRequest] = []
    private var callIndex = 0

    public init() {}

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestsReceived.append(request)
        let index = callIndex
        callIndex += 1

        if index < errors.count {
            throw errors[index]
        }

        if index < responses.count {
            return responses[index]
        }

        // Default 200 empty response
        let url = request.url ?? URL(string: "https://api.paywallo.com")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(), response)
    }

    public func enqueueResponse(statusCode: Int, data: Data = Data(), headers: [String: String]? = nil) {
        let url = URL(string: "https://api.paywallo.com")!
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)!
        responses.append((data, response))
    }

    public func enqueueJSON(_ json: Any, statusCode: Int = 200) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        enqueueResponse(statusCode: statusCode, data: data)
    }

    public func enqueueError(_ error: Error) {
        errors.append(error)
    }
}
