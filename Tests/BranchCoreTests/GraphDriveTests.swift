import XCTest
@testable import BranchCore

/// Records requests and replays canned responses.
final class StubHTTP: HTTPClient, @unchecked Sendable {
    var responses: [(Int, String, [String: String])] = []
    var requests: [URLRequest] = []
    private let lock = NSLock()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (code, body, headers) = lock.withLock {
            requests.append(request)
            return responses.isEmpty ? (500, "{}", [:]) : responses.removeFirst()
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
        return (Data(body.utf8), resp)
    }
}

struct FixedToken: AccessTokenProvider {
    func accessToken() async throws -> String { "tok" }
}

final class GraphDriveTests: XCTestCase {
    func testEncodePath() {
        XCTAssertEqual(GraphDrive.encode("My Docs (1)/a#b?.txt"), "My%20Docs%20%281%29/a%23b%3F.txt")
    }

    func testSimpleUpload() async throws {
        let http = StubHTTP()
        http.responses = [(201, #"{"id":"ABC","size":5}"#, [:])]
        let drive = GraphDrive(tokens: FixedToken(), http: http)
        let item = try await drive.upload(data: Data("hello".utf8), to: "Docs/a.txt")
        XCTAssertEqual(item, RemoteItem(id: "ABC", size: 5))
        let req = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(req.httpMethod, "PUT")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertTrue(req.url!.absoluteString.contains("/special/approot:/Docs/a.txt:/content"))
    }

    func testChunkFlow() async throws {
        let http = StubHTTP()
        http.responses = [
            (200, #"{"uploadUrl":"https://up.example/s1"}"#, [:]),
            (202, #"{"nextExpectedRanges":["4-"]}"#, [:]),
            (201, #"{"id":"X","size":8}"#, [:]),
        ]
        let drive = GraphDrive(tokens: FixedToken(), http: http)
        let session = try await drive.createUploadSession(remotePath: "a/b.bin")
        XCTAssertEqual(session.absoluteString, "https://up.example/s1")
        let r1 = try await drive.uploadChunk(session: session, data: Data(count: 4), offset: 0, total: 8)
        XCTAssertEqual(r1, .next(4))
        let r2 = try await drive.uploadChunk(session: session, data: Data(count: 4), offset: 4, total: 8)
        XCTAssertEqual(r2, .completed(RemoteItem(id: "X", size: 8)))
        XCTAssertNil(http.requests[1].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(http.requests[2].value(forHTTPHeaderField: "Content-Range"), "bytes 4-7/8")
    }

    func testErrorMapping() async {
        let http = StubHTTP()
        http.responses = [(429, #"{"error":{"code":"tooMany","message":"slow"}}"#, ["Retry-After": "7"])]
        let drive = GraphDrive(tokens: FixedToken(), http: http)
        do {
            _ = try await drive.upload(data: Data(), to: "x")
            XCTFail("expected throw")
        } catch let e as CloudError {
            XCTAssertEqual(e.kind, .throttled)
            XCTAssertEqual(e.retryAfter, 7)
            XCTAssertTrue(e.isRetryable)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testQuotaExceededNotRetryable() {
        let resp = HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 507, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try GraphDrive.check(resp, Data())) { e in
            XCTAssertEqual((e as? CloudError)?.kind, .quotaExceeded)
            XCTAssertEqual((e as? CloudError)?.isRetryable, false)
        }
    }
}
