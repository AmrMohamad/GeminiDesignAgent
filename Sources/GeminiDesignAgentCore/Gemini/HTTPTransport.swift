import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GeminiHTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data
    public var timeoutSeconds: Int

    public init(url: URL, method: String, headers: [String: String], body: Data, timeoutSeconds: Int) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct GeminiHTTPResponse: Sendable {
    public var statusCode: Int
    public var body: Data
    public var headers: [String: String]

    public init(statusCode: Int, body: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        var normalizedHeaders: [String: String] = [:]
        for (key, value) in headers {
            normalizedHeaders[key.lowercased()] = value
        }
        self.headers = normalizedHeaders
    }

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

public protocol HTTPTransport: Sendable {
    func execute(_ request: GeminiHTTPRequest) async throws -> GeminiHTTPResponse
}

public final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            self.session = URLSession(configuration: configuration)
        }
    }

    public func execute(_ request: GeminiHTTPRequest) async throws -> GeminiHTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: TimeInterval(request.timeoutSeconds))
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.unexpectedResponse("Gemini transport returned a non-HTTP response")
        }
        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            guard let name = key as? String else { continue }
            headers[name.lowercased()] = String(describing: value)
        }
        return GeminiHTTPResponse(statusCode: httpResponse.statusCode, body: data, headers: headers)
    }
}
