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

    func testExclusionPatternsSetting() throws {
        XCTAssertEqual(try store.exclusionPatterns(), ExclusionRules.defaultPatterns)
        try store.setExclusionPatterns(["*.log", " ", "*.log"])
        XCTAssertEqual(try store.exclusionPatterns(), ["*.log"])
        try store.setExclusionPatterns([])
        XCTAssertEqual(try store.exclusionPatterns(), [])
        try store.setExclusionPatterns(nil)
        XCTAssertEqual(try store.exclusionPatterns(), ExclusionRules.defaultPatterns)
    }

    func testFolderPatternsPersist() throws {
        let f = try store.insert(ManagedFolder(path: "/tmp/p", excludePatterns: ["*.raw", "cache"]))
        XCTAssertEqual(try store.folder(id: f.id)?.excludePatterns, ["*.raw", "cache"])
        var g = f
        g.excludePatterns = []
        try store.update(g)
        XCTAssertEqual(try store.folder(id: f.id)?.excludePatterns, [])
    }

    func testMigratesVersion1Database() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("v1-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let db = try Database(path: url.path)
            try db.execute("""
            CREATE TABLE folders (id INTEGER PRIMARY KEY AUTOINCREMENT, parent_id INTEGER, path TEXT NOT NULL UNIQUE,
                bookmark BLOB, remote_name TEXT, interval TEXT, availability TEXT, paused INTEGER NOT NULL DEFAULT 0,
                excluded INTEGER NOT NULL DEFAULT 0, last_success REAL, next_run REAL,
                status TEXT NOT NULL DEFAULT 'idle', last_error TEXT);
            CREATE TABLE files (root_id INTEGER, rel_path TEXT, size INTEGER, modified REAL, sha256 TEXT,
                remote_item_id TEXT, uploaded_at REAL, PRIMARY KEY (root_id, rel_path));
            CREATE TABLE jobs (id INTEGER PRIMARY KEY AUTOINCREMENT, folder_id INTEGER, root_id INTEGER,
                rel_path TEXT, size INTEGER, modified REAL, sha256 TEXT, state TEXT, attempts INTEGER DEFAULT 0,
                not_before REAL, last_error TEXT, session_url TEXT, bytes_uploaded INTEGER DEFAULT 0,
                UNIQUE (root_id, rel_path));
            CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);
            INSERT INTO folders (path, remote_name) VALUES ('/tmp/old', 'old');
            PRAGMA user_version = 1;
            """)
        }
        let migrated = try Store(db: Database(path: url.path))
        XCTAssertEqual(migrated.db.userVersion, 2)
        let f = try XCTUnwrap(migrated.folder(path: "/tmp/old"))
        XCTAssertEqual(f.excludePatterns, [])
    }
}
