import XCTest
@testable import BranchCore

final class InclusionTests: XCTestCase {
    var dir: URL!
    var library: FolderLibrary!
    var store: Store!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-incl-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        for d in ["Root/a/deep", "Root/b", "Root/node_modules"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: dir.appendingPathComponent("Root/a/file.txt"))
        store = try Store(db: Database(path: ":memory:"))
        library = FolderLibrary(store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func p(_ rel: String) -> String { dir.appendingPathComponent(rel).path }
    private func state(_ rel: String) throws -> FolderTree.Inclusion {
        try library.tree().inclusion(of: p(rel), globalPatterns: ExclusionRules.defaultPatterns)
    }

    func testStates() throws {
        _ = try library.add(path: p("Root"))
        XCTAssertEqual(try state("Root/a"), .included)
        XCTAssertEqual(try state("Root/node_modules"), .skippedByPattern)
        XCTAssertEqual(try state("Elsewhere"), .outside)

        try library.setIncluded(path: p("Root/a/deep"), false)
        XCTAssertEqual(try state("Root/a/deep"), .excluded)
        XCTAssertEqual(try state("Root/a"), .partial)
        XCTAssertEqual(try state("Root"), .partial)
        XCTAssertEqual(try state("Root/b"), .included)
    }

    func testIncludeRemovesPlainNode() throws {
        let root = try library.add(path: p("Root"))
        try library.setIncluded(path: p("Root/a/file.txt"), false)
        XCTAssertEqual(try library.tree().excludedCount(under: root.id), 1)
        try library.setIncluded(path: p("Root/a/file.txt"), true)
        XCTAssertEqual(try store.allFolders().count, 1)
        XCTAssertEqual(try state("Root/a"), .included)
    }

    func testIncludeKeepsNodeWithSettings() throws {
        _ = try library.add(path: p("Root"))
        let a = try library.add(path: p("Root/a"))
        try library.setInterval(id: a.id, .daily)
        try library.setIncluded(path: p("Root/a"), false)
        try library.setIncluded(path: p("Root/a"), true)
        let node = try XCTUnwrap(store.folder(id: a.id))
        XCTAssertFalse(node.isExcluded)
        XCTAssertEqual(node.intervalOverride, .daily)
    }

    func testExcludingParentAdoptsExistingChildNodes() throws {
        let root = try library.add(path: p("Root"))
        let deep = try library.add(path: p("Root/a/deep"))
        XCTAssertEqual(deep.parentID, root.id)
        let a = try library.exclude(path: p("Root/a"))
        let tree = try library.tree()
        XCTAssertEqual(tree.folders[deep.id]?.parentID, a.id)
        XCTAssertTrue(tree.policy(for: deep.id).isExcluded)
        XCTAssertFalse(tree.dueFolders(now: Date()).contains { $0.id == deep.id })
    }

    func testExcludedFileIsNotScanned() async throws {
        let root = try library.add(path: p("Root"))
        try Data("y".utf8).write(to: dir.appendingPathComponent("Root/b/keep.txt"))
        try library.setIncluded(path: p("Root/a/file.txt"), false)
        let engine = BackupEngine(store: store, drive: nil)
        try await engine.scan(folderID: root.id)
        XCTAssertEqual(try store.jobs().map(\.relativePath), ["b/keep.txt"])
    }
}
