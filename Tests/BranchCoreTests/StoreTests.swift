import XCTest
@testable import BranchCore

final class StoreTests: XCTestCase {
    var store: Store!

    override func setUpWithError() throws {
        store = try Store(db: Database(path: ":memory:"))
    }

    func testFolderCRUDAndCascade() throws {
        let root = try store.insert(ManagedFolder(path: "/tmp/a", remoteName: "a", intervalOverride: .hourly))
        let child = try store.insert(ManagedFolder(parentID: root.id, path: "/tmp/a/big", intervalOverride: .daily))
        XCTAssertEqual(try store.allFolders().count, 2)

        var updated = child
        updated.isPaused = true
        try store.update(updated)
        XCTAssertEqual(try store.folder(id: child.id)?.isPaused, true)
        XCTAssertEqual(try store.folder(path: "/tmp/a")?.intervalOverride, .hourly)

        try store.upsert(FileRecord(rootID: root.id, relativePath: "x.txt", size: 3, modified: Date()))
        try store.enqueue(UploadJob(folderID: child.id, rootID: root.id, relativePath: "big/y", size: 1, modified: Date()))

        try store.deleteFolder(id: root.id)
        XCTAssertTrue(try store.allFolders().isEmpty)
        XCTAssertTrue(try store.files(rootID: root.id).isEmpty)
        XCTAssertTrue(try store.jobs().isEmpty)
    }

    func testEnqueueDedupesAndResets() throws {
        let root = try store.insert(ManagedFolder(path: "/tmp/b"))
        let job = UploadJob(folderID: root.id, rootID: root.id, relativePath: "f", size: 1, modified: Date())
        try store.enqueue(job)
        var queued = try XCTUnwrap(store.dueJobs(now: Date(), limit: 10).first)
        queued.state = .failed
        queued.attempts = 3
        queued.sessionURL = "https://example"
        try store.update(queued)
        XCTAssertEqual(try store.jobCounts().failed, 1)

        try store.enqueue(UploadJob(folderID: root.id, rootID: root.id, relativePath: "f", size: 2, modified: Date()))
        let all = try store.jobs()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].state, .queued)
        XCTAssertEqual(all[0].attempts, 0)
        XCTAssertEqual(all[0].size, 2)
        XCTAssertNil(all[0].sessionURL)
    }

    func testRequeueInterrupted() throws {
        let root = try store.insert(ManagedFolder(path: "/tmp/c"))
        try store.enqueue(UploadJob(folderID: root.id, rootID: root.id, relativePath: "f", size: 1, modified: Date()))
        var j = try XCTUnwrap(store.jobs().first)
        j.state = .uploading
        j.sessionURL = "https://session"
        try store.update(j)
        try store.requeueInterruptedJobs()
        let after = try XCTUnwrap(store.jobs().first)
        XCTAssertEqual(after.state, .queued)
        XCTAssertEqual(after.sessionURL, "https://session")
    }

    func testTotalsAndSettings() throws {
        let root = try store.insert(ManagedFolder(path: "/tmp/d"))
        try store.upsert(FileRecord(rootID: root.id, relativePath: "a", size: 10, modified: Date(), uploadedAt: Date()))
        try store.upsert(FileRecord(rootID: root.id, relativePath: "b", size: 5, modified: Date()))
        let totals = try store.fileTotals()
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals.bytes, 15)
        XCTAssertEqual(totals.uploadedCount, 1)
        XCTAssertEqual(totals.uploadedBytes, 10)

        try store.setSetting("k", "v")
        XCTAssertEqual(try store.setting("k"), "v")
        try store.setSetting("k", nil)
        XCTAssertNil(try store.setting("k"))
    }
}
