import XCTest
@testable import BranchCore

final class ScannerTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-scan-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("owned"), withIntermediateDirectories: true)
        try write("a.txt", "hello")
        try write("sub/deep/b.bin", "world")
        try write(".DS_Store", "x")
        try write("node_modules/pkg.js", "x")
        try write("owned/c.txt", "x")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ rel: String, _ s: String) throws {
        try Data(s.utf8).write(to: dir.appendingPathComponent(rel))
    }

    private func scan() throws -> [ScannedFile] {
        try Scanner.enumerate(
            folderPath: dir.path, rootPath: dir.path,
            skipping: [dir.appendingPathComponent("owned").path], rules: ExclusionRules()
        )
    }

    func testEnumerateSkipsExcludedAndOwned() throws {
        let rels = Set(try scan().map(\.relativePath))
        XCTAssertEqual(rels, ["a.txt", "sub/deep/b.bin"])
    }

    func testDiffDetectsNewChangedAndTouched() throws {
        let scanned = try scan()
        var result = Scanner.diff(scanned: scanned, known: [:], rootPath: dir.path)
        XCTAssertEqual(result.changed.count, 2)
        XCTAssertEqual(result.totalBytes, 10)

        // Pretend everything uploaded.
        var known: [String: FileRecord] = [:]
        for (f, h) in result.changed {
            known[f.relativePath] = FileRecord(rootID: 1, relativePath: f.relativePath, size: f.size,
                                               modified: f.modified, sha256: h, uploadedAt: Date())
        }
        result = Scanner.diff(scanned: scanned, known: known, rootPath: dir.path)
        XCTAssertTrue(result.changed.isEmpty)
        XCTAssertTrue(result.touched.isEmpty)

        // Same content, new mtime: touched, not changed.
        known["a.txt"]!.modified = .distantPast
        result = Scanner.diff(scanned: scanned, known: known, rootPath: dir.path)
        XCTAssertEqual(result.touched.map(\.file.relativePath), ["a.txt"])
        XCTAssertTrue(result.changed.isEmpty)

        // Content change.
        try write("a.txt", "HELLO!")
        result = Scanner.diff(scanned: try scan(), known: known, rootPath: dir.path)
        XCTAssertEqual(result.changed.map(\.file.relativePath), ["a.txt"])

        // Deleted file is reported missing only.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("sub/deep/b.bin"))
        result = Scanner.diff(scanned: try scan(), known: known, rootPath: dir.path)
        XCTAssertEqual(result.missing, ["sub/deep/b.bin"])
    }

    func testHash() throws {
        XCTAssertEqual(
            try Scanner.sha256(path: dir.appendingPathComponent("a.txt").path),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    func testExclusionRules() {
        let r = ExclusionRules()
        XCTAssertTrue(r.excludes(name: "foo.tmp"))
        XCTAssertTrue(r.excludes(name: "._foo"))
        XCTAssertFalse(r.excludes(name: "foo.txt"))
    }
}
