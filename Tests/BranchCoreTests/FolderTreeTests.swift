import XCTest
@testable import BranchCore

final class FolderTreeTests: XCTestCase {
    let root = ManagedFolder(id: 1, path: "/u/docs", intervalOverride: .hourly)
    let data = ManagedFolder(id: 2, parentID: 1, path: "/u/docs/data", intervalOverride: .daily)
    let raw = ManagedFolder(id: 3, parentID: 2, path: "/u/docs/data/raw", availabilityOverride: .cloudOnly)
    let tmp = ManagedFolder(id: 4, parentID: 1, path: "/u/docs/tmp", isExcluded: true)

    var tree: FolderTree { FolderTree([root, data, raw, tmp]) }

    func testInheritance() {
        XCTAssertEqual(tree.policy(for: 1).interval, .hourly)
        XCTAssertEqual(tree.policy(for: 2).interval, .daily)
        XCTAssertTrue(tree.policy(for: 2).intervalIsOverridden)
        XCTAssertEqual(tree.policy(for: 3).interval, .daily)
        XCTAssertFalse(tree.policy(for: 3).intervalIsOverridden)
        XCTAssertEqual(tree.policy(for: 3).availability, .cloudOnly)
        XCTAssertEqual(tree.policy(for: 2).availability, .localAndCloud)
        XCTAssertTrue(tree.policy(for: 4).isExcluded)
        XCTAssertEqual(tree.root(of: 3)?.id, 1)
    }

    func testPauseInherits() {
        var paused = root
        paused.isPaused = true
        let t = FolderTree([paused, data, raw])
        XCTAssertTrue(t.policy(for: 3).isPaused)
        XCTAssertTrue(t.dueFolders(now: Date()).isEmpty)
    }

    func testDueFolders() {
        let now = Date()
        var r = root; r.nextRun = now.addingTimeInterval(60)
        var d = data; d.nextRun = now.addingTimeInterval(-60)
        let t = FolderTree([r, d, raw, tmp])
        // raw has no nextRun so it's due; tmp is excluded.
        XCTAssertEqual(Set(t.dueFolders(now: now).map(\.id)), [2, 3])
    }

    func testSkippedPaths() {
        XCTAssertEqual(tree.skippedPaths(under: 1), ["/u/docs/data", "/u/docs/tmp"])
        XCTAssertEqual(tree.skippedPaths(under: 2), ["/u/docs/data/raw"])
    }

    func testRelativeAndContaining() {
        XCTAssertEqual(FolderTree.relative("/u/docs/data/x", to: "/u/docs"), "data/x")
        XCTAssertNil(FolderTree.relative("/u/docsx/y", to: "/u/docs"))
        XCTAssertEqual(tree.containing("/u/docs/data/raw/file")?.id, 3)
        XCTAssertEqual(tree.containing("/u/docs/other")?.id, 1)
        XCTAssertNil(tree.containing("/elsewhere"))
    }

    func testExcludePatternsInherit() {
        var r = root; r.excludePatterns = ["*.log"]
        var d = data; d.excludePatterns = ["*.raw"]
        let t = FolderTree([r, d, raw])
        XCTAssertEqual(t.excludePatterns(for: 3), ["*.log", "*.raw"])
        XCTAssertEqual(t.excludePatterns(for: 1), ["*.log"])
    }
}
