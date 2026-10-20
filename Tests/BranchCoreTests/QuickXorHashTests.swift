import XCTest
@testable import BranchCore

/// Vectors produced by the `quickxorhash` Python package (independent C implementation).
final class QuickXorHashTests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(QuickXorHash.hash(Data()), "AAAAAAAAAAAAAAAAAAAAAAAAAAA=")
        XCTAssertEqual(QuickXorHash.hash(Data("hello".utf8)), "aCgDG9jwBgAAAAAABQAAAAAAAAA=")
        XCTAssertEqual(QuickXorHash.hash(Data((0..<1000).map { UInt8($0 % 251) })), "KbphcpColXb1/3Wm950vUzeX1es=")
    }

    func testStreamingMatchesOneShotAcrossOddChunks() {
        let data = Data((0..<5_000_003).map { UInt8($0 % 7) })
        XCTAssertEqual(QuickXorHash.hash(data), "RWGahmFZjiMIAChKkHtgy3EEAQA=")

        var h = QuickXorHash()
        var offset = 0
        var step = 1
        while offset < data.count {
            let end = min(offset + step, data.count)
            h.update(data.subdata(in: offset..<end))
            offset = end
            step = step * 3 + 7
        }
        XCTAssertEqual(h.base64(), "RWGahmFZjiMIAChKkHtgy3EEAQA=")
    }

    func testFileHash() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("hello".utf8).write(to: url)
        XCTAssertEqual(try QuickXorHash.hash(path: url.path), "aCgDG9jwBgAAAAAABQAAAAAAAAA=")
    }
}
