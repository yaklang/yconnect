import Foundation
@testable import YConnect

final class MockHTTPTransport: HTTPTransport {
    typealias Handler = (URLRequest) throws -> (Data, URLResponse)

    private let handler: Handler
    private(set) var requests: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try handler(request)
    }
}

enum TestFixture {
    private struct CookiePayload: Encodable {
        let name: String
        let value: String
        let domain: String
        let path: String
        let expiresAt: Date?
    }

    static func cookie(
        name: String = "yakcool_user_session",
        value: String = "fake-session-token-for-tests",
        domain: String = ".yakcool.com",
        path: String = "/",
        expiresAt: Date? = nil
    ) throws -> StoredWebCookie {
        let payload = CookiePayload(
            name: name,
            value: value,
            domain: domain,
            path: path,
            expiresAt: expiresAt
        )
        return try JSONDecoder().decode(
            StoredWebCookie.self,
            from: JSONEncoder().encode(payload)
        )
    }

    static func httpResponse(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }
}
