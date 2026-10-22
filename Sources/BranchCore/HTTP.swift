import Foundation

/// Minimal HTTP transport so Graph and auth code can be tested without the network.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Streams the response body to a temporary file the caller must move or delete.
    func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse)
}

extension HTTPClient {
    /// Buffered fallback for clients without native downloads (tests).
    public func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (data, resp) = try await send(request)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("branch-dl-\(UUID().uuidString)")
        try data.write(to: url)
        return (url, resp)
    }
}

extension URLSession: HTTPClient {
    public func download(_ request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (temp, response) = try await download(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // The system deletes `temp` when this returns; move it somewhere we own.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("branch-dl-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: temp, to: url)
        return (url, http)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

extension URLRequest {
    static func form(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        return req
    }
}
