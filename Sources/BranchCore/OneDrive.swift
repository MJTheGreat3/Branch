import Foundation

/// A file confirmed to exist in the cloud.
public struct RemoteItem: Equatable, Sendable {
    public var id: String
    public var size: Int64
}

public struct DriveQuota: Equatable, Sendable {
    public var total: Int64
    public var used: Int64
    public var remaining: Int64
}

public enum ChunkResult: Equatable, Sendable {
    /// Server accepted the chunk; continue from this byte offset.
    case next(Int64)
    case completed(RemoteItem)
}

/// Cloud operations the backup engine needs. Paths are relative to the app's root folder.
public protocol CloudDrive: Sendable {
    /// Single-request upload for small files.
    func upload(data: Data, to remotePath: String) async throws -> RemoteItem
    /// Starts a resumable upload session; returns its upload URL.
    func createUploadSession(remotePath: String) async throws -> URL
    /// Uploads bytes [offset, offset+data.count) of a `total`-byte file.
    func uploadChunk(session: URL, data: Data, offset: Int64, total: Int64) async throws -> ChunkResult
    /// Next byte offset the server expects for an existing session.
    func sessionOffset(session: URL) async throws -> Int64
    func quota() async throws -> DriveQuota
}

public struct CloudError: Error, Equatable, CustomStringConvertible {
    public enum Kind: Equatable, Sendable {
        case unauthorized
        case throttled
        case quotaExceeded
        case notFound
        case server
        case client
        case network
        case verification
    }

    public var kind: Kind
    public var status: Int
    public var message: String
    public var retryAfter: TimeInterval?

    public init(kind: Kind, status: Int = 0, message: String, retryAfter: TimeInterval? = nil) {
        self.kind = kind
        self.status = status
        self.message = message
        self.retryAfter = retryAfter
    }

    public var isRetryable: Bool {
        switch kind {
        case .throttled, .server, .network, .unauthorized, .notFound, .verification: return true
        case .quotaExceeded, .client: return false
        }
    }

    public var description: String { message }
}

/// Microsoft Graph implementation targeting the app's special folder (/Apps/Branch).
public struct GraphDrive: CloudDrive {
    public static let simpleUploadLimit: Int64 = 4 * 1024 * 1024
    /// Graph requires chunk sizes in multiples of 320 KiB.
    public static let chunkSize: Int64 = 320 * 1024 * 20

    private let tokens: AccessTokenProvider
    private let http: HTTPClient
    private let base = URL(string: "https://graph.microsoft.com/v1.0/me/drive")!

    public init(tokens: AccessTokenProvider, http: HTTPClient = URLSession.shared) {
        self.tokens = tokens
        self.http = http
    }

    static func encode(_ remotePath: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: ":?#[]@!$&'()*+,;=%")
        return remotePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }

    func itemURL(_ remotePath: String, suffix: String) -> URL {
        URL(string: "\(base.absoluteString)/special/approot:/\(Self.encode(remotePath)):/\(suffix)")!
    }

    private func authorized(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var r = req
        r.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        return try await send(r)
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await http.send(req)
        } catch let e as URLError {
            throw CloudError(kind: .network, message: e.localizedDescription)
        }
    }

    public func upload(data: Data, to remotePath: String) async throws -> RemoteItem {
        var req = URLRequest(url: itemURL(remotePath, suffix: "content?@microsoft.graph.conflictBehavior=replace"))
        req.httpMethod = "PUT"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (body, resp) = try await authorized(req)
        try Self.check(resp, body)
        return try Self.item(body)
    }

    public func createUploadSession(remotePath: String) async throws -> URL {
        var req = URLRequest(url: itemURL(remotePath, suffix: "createUploadSession"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"item":{"@microsoft.graph.conflictBehavior":"replace"}}"#.utf8)
        let (body, resp) = try await authorized(req)
        try Self.check(resp, body)
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let s = obj["uploadUrl"] as? String, let url = URL(string: s) else {
            throw CloudError(kind: .server, status: resp.statusCode, message: "Upload session missing uploadUrl")
        }
        return url
    }

    public func uploadChunk(session: URL, data: Data, offset: Int64, total: Int64) async throws -> ChunkResult {
        // The upload URL is pre-authenticated; Graph rejects an Authorization header here.
        var req = URLRequest(url: session)
        req.httpMethod = "PUT"
        req.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        req.setValue("bytes \(offset)-\(offset + Int64(data.count) - 1)/\(total)", forHTTPHeaderField: "Content-Range")
        req.httpBody = data
        let (body, resp) = try await send(req)
        try Self.check(resp, body)
        if resp.statusCode == 202 {
            return .next(Self.nextOffset(body) ?? offset + Int64(data.count))
        }
        return .completed(try Self.item(body))
    }

    public func sessionOffset(session: URL) async throws -> Int64 {
        let (body, resp) = try await send(URLRequest(url: session))
        try Self.check(resp, body)
        return Self.nextOffset(body) ?? 0
    }

    public func quota() async throws -> DriveQuota {
        let (body, resp) = try await authorized(URLRequest(url: base))
        try Self.check(resp, body)
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let q = obj["quota"] as? [String: Any] else {
            throw CloudError(kind: .server, status: resp.statusCode, message: "Drive quota unavailable")
        }
        func n(_ k: String) -> Int64 { (q[k] as? NSNumber)?.int64Value ?? 0 }
        return DriveQuota(total: n("total"), used: n("used"), remaining: n("remaining"))
    }

    // MARK: Response handling

    static func nextOffset(_ body: Data) -> Int64? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let ranges = obj["nextExpectedRanges"] as? [String],
              let first = ranges.first,
              let start = first.split(separator: "-").first else { return nil }
        return Int64(start)
    }

    static func item(_ body: Data) throws -> RemoteItem {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = obj["id"] as? String else {
            throw CloudError(kind: .verification, message: "Upload response did not include an item id")
        }
        return RemoteItem(id: id, size: (obj["size"] as? NSNumber)?.int64Value ?? -1)
    }

    static func check(_ resp: HTTPURLResponse, _ body: Data) throws {
        let code = resp.statusCode
        guard !(200..<300).contains(code) else { return }
        let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let err = obj?["error"] as? [String: Any]
        let message = (err?["message"] as? String) ?? HTTPURLResponse.localizedString(forStatusCode: code)
        let graphCode = err?["code"] as? String
        let retryAfter = resp.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        let kind: CloudError.Kind
        switch code {
        case 401: kind = .unauthorized
        case 404, 410: kind = .notFound
        case 429, 503: kind = .throttled
        case 507: kind = .quotaExceeded
        case 500...: kind = .server
        default: kind = graphCode == "quotaLimitReached" ? .quotaExceeded : .client
        }
        throw CloudError(kind: kind, status: code, message: message, retryAfter: retryAfter)
    }
}
