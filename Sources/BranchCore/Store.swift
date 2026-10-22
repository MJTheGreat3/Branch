import Foundation

/// Persistent app state: folder tree, file metadata, upload queue, settings.
public final class Store: @unchecked Sendable {
    public let db: Database

    public init(db: Database) throws {
        self.db = db
        try migrate()
    }

    /// Default on-disk location: ~/Library/Application Support/Branch/branch.sqlite
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let dir = base.appendingPathComponent("Branch", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("branch.sqlite")
    }

    // MARK: Schema

    private func migrate() throws {
        if db.userVersion < 1 {
            try db.transaction {
                try db.execute("""
                CREATE TABLE folders (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    parent_id INTEGER REFERENCES folders(id) ON DELETE CASCADE,
                    path TEXT NOT NULL UNIQUE,
                    bookmark BLOB,
                    remote_name TEXT,
                    interval TEXT,
                    availability TEXT,
                    paused INTEGER NOT NULL DEFAULT 0,
                    excluded INTEGER NOT NULL DEFAULT 0,
                    last_success REAL,
                    next_run REAL,
                    status TEXT NOT NULL DEFAULT 'idle',
                    last_error TEXT
                );
                CREATE TABLE files (
                    root_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
                    rel_path TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    modified REAL NOT NULL,
                    sha256 TEXT,
                    remote_item_id TEXT,
                    uploaded_at REAL,
                    PRIMARY KEY (root_id, rel_path)
                );
                CREATE TABLE jobs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
                    root_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
                    rel_path TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    modified REAL NOT NULL,
                    sha256 TEXT,
                    state TEXT NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    not_before REAL NOT NULL,
                    last_error TEXT,
                    session_url TEXT,
                    bytes_uploaded INTEGER NOT NULL DEFAULT 0,
                    UNIQUE (root_id, rel_path)
                );
                CREATE INDEX jobs_state ON jobs(state, not_before);
                CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);
                """)
                try db.setUserVersion(1)
            }
        }
        if db.userVersion < 2 {
            try db.transaction {
                try db.execute("ALTER TABLE folders ADD COLUMN exclude_patterns TEXT")
                try db.setUserVersion(2)
            }
        }
        if db.userVersion < 3 {
            // Per-folder status and counts run after every upload; keep them off full scans.
            try db.transaction {
                try db.execute("CREATE INDEX IF NOT EXISTS jobs_folder ON jobs(folder_id, state)")
                try db.setUserVersion(3)
            }
        }
    }

    // MARK: Folders

    private static let folderColumns =
        "id, parent_id, path, bookmark, remote_name, interval, availability, paused, excluded, last_success, next_run, status, last_error, exclude_patterns"

    private static func folder(_ r: Row) -> ManagedFolder {
        ManagedFolder(
            id: r.int(0),
            parentID: r.intOrNil(1),
            path: r.text(2),
            bookmark: r.blobOrNil(3),
            remoteName: r.textOrNil(4),
            intervalOverride: r.textOrNil(5).flatMap(BackupInterval.init(rawValue:)),
            availabilityOverride: r.textOrNil(6).flatMap(AvailabilityMode.init(rawValue:)),
            isPaused: r.bool(7),
            isExcluded: r.bool(8),
            excludePatterns: r.textOrNil(13).map(Store.decodePatterns) ?? [],
            lastSuccess: r.dateOrNil(9),
            nextRun: r.dateOrNil(10),
            status: BackupStatus(rawValue: r.text(11)) ?? .idle,
            lastError: r.textOrNil(12)
        )
    }

    public func allFolders() throws -> [ManagedFolder] {
        try db.all("SELECT \(Self.folderColumns) FROM folders ORDER BY path", [], Self.folder)
    }

    public func folder(id: Int64) throws -> ManagedFolder? {
        try db.first("SELECT \(Self.folderColumns) FROM folders WHERE id = ?", [id], Self.folder)
    }

    public func folder(path: String) throws -> ManagedFolder? {
        try db.first("SELECT \(Self.folderColumns) FROM folders WHERE path = ?", [path], Self.folder)
    }

    @discardableResult
    public func insert(_ f: ManagedFolder) throws -> ManagedFolder {
        try db.run("""
        INSERT INTO folders (parent_id, path, bookmark, remote_name, interval, availability, paused, excluded,
                             last_success, next_run, status, last_error, exclude_patterns)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            f.parentID, f.path, f.bookmark, f.remoteName, f.intervalOverride?.rawValue,
            f.availabilityOverride?.rawValue, f.isPaused, f.isExcluded, f.lastSuccess, f.nextRun,
            f.status.rawValue, f.lastError, Store.encodePatterns(f.excludePatterns),
        ])
        var copy = f
        copy.id = db.lastInsertID
        return copy
    }

    public func update(_ f: ManagedFolder) throws {
        try db.run("""
        UPDATE folders SET parent_id = ?, path = ?, bookmark = ?, remote_name = ?, interval = ?, availability = ?,
            paused = ?, excluded = ?, last_success = ?, next_run = ?, status = ?, last_error = ?, exclude_patterns = ?
        WHERE id = ?
        """, [
            f.parentID, f.path, f.bookmark, f.remoteName, f.intervalOverride?.rawValue,
            f.availabilityOverride?.rawValue, f.isPaused, f.isExcluded, f.lastSuccess, f.nextRun,
            f.status.rawValue, f.lastError, Store.encodePatterns(f.excludePatterns), f.id,
        ])
    }

    /// Removes the folder (and its descendants) from management only.
    /// Never touches local files or the cloud copy.
    public func deleteFolder(id: Int64) throws {
        try db.run("DELETE FROM folders WHERE id = ?", [id])
    }

    public func setStatus(folderID: Int64, _ status: BackupStatus, error: String? = nil) throws {
        try db.run("UPDATE folders SET status = ?, last_error = ? WHERE id = ?", [status.rawValue, error, folderID])
    }

    // MARK: Files

    private static func fileRecord(_ r: Row) -> FileRecord {
        FileRecord(
            rootID: r.int(0), relativePath: r.text(1), size: r.int(2), modified: r.date(3),
            sha256: r.textOrNil(4), remoteItemID: r.textOrNil(5), uploadedAt: r.dateOrNil(6)
        )
    }

    public func files(rootID: Int64) throws -> [String: FileRecord] {
        let rows = try db.all(
            "SELECT root_id, rel_path, size, modified, sha256, remote_item_id, uploaded_at FROM files WHERE root_id = ?",
            [rootID], Self.fileRecord
        )
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.relativePath, $0) })
    }

    public func upsert(_ f: FileRecord) throws {
        try db.run("""
        INSERT INTO files (root_id, rel_path, size, modified, sha256, remote_item_id, uploaded_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (root_id, rel_path) DO UPDATE SET
            size = excluded.size, modified = excluded.modified, sha256 = excluded.sha256,
            remote_item_id = excluded.remote_item_id, uploaded_at = excluded.uploaded_at
        """, [f.rootID, f.relativePath, f.size, f.modified, f.sha256, f.remoteItemID, f.uploadedAt])
    }

    public struct FileTotals: Equatable, Sendable {
        public var count: Int
        public var bytes: Int64
        public var uploadedCount: Int
        public var uploadedBytes: Int64

        public init(count: Int = 0, bytes: Int64 = 0, uploadedCount: Int = 0, uploadedBytes: Int64 = 0) {
            self.count = count
            self.bytes = bytes
            self.uploadedCount = uploadedCount
            self.uploadedBytes = uploadedBytes
        }
    }

    public func fileTotals(rootID: Int64? = nil) throws -> FileTotals {
        let filter = rootID == nil ? "" : "WHERE root_id = ?"
        let params: [any SQLBindable] = rootID.map { [$0] } ?? []
        return try db.first("""
        SELECT COUNT(*), COALESCE(SUM(size), 0),
               COALESCE(SUM(uploaded_at IS NOT NULL), 0),
               COALESCE(SUM(CASE WHEN uploaded_at IS NOT NULL THEN size ELSE 0 END), 0)
        FROM files \(filter)
        """, params) {
            FileTotals(count: Int($0.int(0)), bytes: $0.int(1), uploadedCount: Int($0.int(2)), uploadedBytes: $0.int(3))
        } ?? FileTotals(count: 0, bytes: 0, uploadedCount: 0, uploadedBytes: 0)
    }

    // MARK: Jobs

    private static let jobColumns =
        "id, folder_id, root_id, rel_path, size, modified, sha256, state, attempts, not_before, last_error, session_url, bytes_uploaded"

    private static func job(_ r: Row) -> UploadJob {
        UploadJob(
            id: r.int(0), folderID: r.int(1), rootID: r.int(2), relativePath: r.text(3), size: r.int(4),
            modified: r.date(5), sha256: r.textOrNil(6), state: JobState(rawValue: r.text(7)) ?? .queued,
            attempts: Int(r.int(8)), notBefore: r.date(9), lastError: r.textOrNil(10),
            sessionURL: r.textOrNil(11), bytesUploaded: r.int(12)
        )
    }

    /// Queues an upload. Replaces any existing job for the same file, resetting its progress.
    public func enqueue(_ j: UploadJob) throws {
        try db.run("""
        INSERT INTO jobs (folder_id, root_id, rel_path, size, modified, sha256, state, attempts, not_before)
        VALUES (?, ?, ?, ?, ?, ?, 'queued', 0, ?)
        ON CONFLICT (root_id, rel_path) DO UPDATE SET
            folder_id = excluded.folder_id, size = excluded.size, modified = excluded.modified,
            sha256 = excluded.sha256, state = 'queued', attempts = 0, not_before = excluded.not_before,
            last_error = NULL, session_url = NULL, bytes_uploaded = 0
        """, [j.folderID, j.rootID, j.relativePath, j.size, j.modified, j.sha256, j.notBefore])
    }

    /// Next runnable jobs, oldest first.
    public func dueJobs(now: Date, limit: Int) throws -> [UploadJob] {
        try db.all(
            "SELECT \(Self.jobColumns) FROM jobs WHERE state = 'queued' AND not_before <= ? ORDER BY not_before, id LIMIT ?",
            [now, limit], Self.job
        )
    }

    public func jobs(folderID: Int64? = nil) throws -> [UploadJob] {
        if let folderID {
            return try db.all("SELECT \(Self.jobColumns) FROM jobs WHERE folder_id = ? ORDER BY id", [folderID], Self.job)
        }
        return try db.all("SELECT \(Self.jobColumns) FROM jobs ORDER BY id", [], Self.job)
    }

    /// A bounded slice for display: failed first, then uploading, then queued.
    public func jobs(folderID: Int64, limit: Int) throws -> [UploadJob] {
        // One indexed query per state instead of sorting every job of the folder.
        var out: [UploadJob] = []
        for state in [JobState.failed, .uploading, .queued] where out.count < limit {
            out += try db.all(
                "SELECT \(Self.jobColumns) FROM jobs WHERE folder_id = ? AND state = ? LIMIT ?",
                [folderID, state.rawValue, limit - out.count], Self.job
            )
        }
        return out
    }

    public func jobs(rootID: Int64) throws -> [UploadJob] {
        try db.all("SELECT \(Self.jobColumns) FROM jobs WHERE root_id = ?", [rootID], Self.job)
    }

    /// Most relevant error for a folder: a failed job's, else any retrying job's.
    public func firstJobError(folderID: Int64, failedOnly: Bool) throws -> String? {
        let filter = failedOnly ? "AND state = 'failed'" : ""
        return try db.first(
            "SELECT last_error FROM jobs WHERE folder_id = ? AND last_error IS NOT NULL \(filter) LIMIT 1",
            [folderID]
        ) { $0.textOrNil(0) } ?? nil
    }

    public func reassignJob(id: Int64, toFolder folderID: Int64) throws {
        try db.run("UPDATE jobs SET folder_id = ? WHERE id = ?", [folderID, id])
    }

    public func update(_ j: UploadJob) throws {
        try db.run("""
        UPDATE jobs SET state = ?, attempts = ?, not_before = ?, last_error = ?, session_url = ?, bytes_uploaded = ?
        WHERE id = ?
        """, [j.state.rawValue, j.attempts, j.notBefore, j.lastError, j.sessionURL, j.bytesUploaded, j.id])
    }

    public func deleteJob(id: Int64) throws {
        try db.run("DELETE FROM jobs WHERE id = ?", [id])
    }

    /// Jobs left mid-upload by a crash or quit go back to the queue; their session URL is kept for resume.
    public func requeueInterruptedJobs() throws {
        try db.run("UPDATE jobs SET state = 'queued' WHERE state = 'uploading'")
    }

    /// Puts failed jobs back in the queue immediately.
    public func retryFailedJobs(folderID: Int64? = nil) throws {
        if let folderID {
            try db.run(
                "UPDATE jobs SET state = 'queued', attempts = 0, not_before = 0, last_error = NULL WHERE state = 'failed' AND folder_id = ?",
                [folderID]
            )
        } else {
            try db.run("UPDATE jobs SET state = 'queued', attempts = 0, not_before = 0, last_error = NULL WHERE state = 'failed'")
        }
    }

    public struct JobCounts: Equatable, Sendable {
        public var queued = 0
        public var uploading = 0
        public var failed = 0
        public init() {}
    }

    public func jobCounts(folderID: Int64? = nil) throws -> JobCounts {
        var counts = JobCounts()
        let filter = folderID == nil ? "" : "WHERE folder_id = ?"
        let params: [any SQLBindable] = folderID.map { [$0] } ?? []
        try db.query("SELECT state, COUNT(*) FROM jobs \(filter) GROUP BY state", params) { r in
            let n = Int(r.int(1))
            switch JobState(rawValue: r.text(0)) {
            case .queued: counts.queued = n
            case .uploading: counts.uploading = n
            case .failed: counts.failed = n
            default: break
            }
        }
        return counts
    }

    // MARK: Settings

    static func encodePatterns(_ p: [String]) -> String? {
        p.isEmpty ? nil : p.joined(separator: "\n")
    }

    static func decodePatterns(_ s: String) -> [String] {
        s.split(separator: "\n").map(String.init)
    }

    private static let exclusionsKey = "exclusions.patterns"

    /// Global exclusion patterns; the built-in defaults until the user edits them.
    public func exclusionPatterns() throws -> [String] {
        try setting(Self.exclusionsKey).map(Store.decodePatterns) ?? ExclusionRules.defaultPatterns
    }

    /// Saves global patterns. nil restores the defaults.
    public func setExclusionPatterns(_ patterns: [String]?) throws {
        // Stored even when empty so "no exclusions" differs from "defaults".
        try setSetting(Self.exclusionsKey, patterns.map { ExclusionRules.clean($0).joined(separator: "\n") })
    }

    /// Drops never-uploaded records and unfinished jobs for files no longer in scope
    /// (deleted, or now excluded). Records of files already in the cloud are kept.
    public func forgetPending(rootID: Int64, relativePaths: [String]) throws {
        for rel in relativePaths {
            try db.run("DELETE FROM files WHERE root_id = ? AND rel_path = ? AND uploaded_at IS NULL", [rootID, rel])
            try db.run("DELETE FROM jobs WHERE root_id = ? AND rel_path = ? AND state != 'uploading'", [rootID, rel])
        }
    }

    public func setting(_ key: String) throws -> String? {
        try db.first("SELECT value FROM settings WHERE key = ?", [key]) { $0.textOrNil(0) } ?? nil
    }

    public func setSetting(_ key: String, _ value: String?) throws {
        if let value {
            try db.run(
                "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                [key, value]
            )
        } else {
            try db.run("DELETE FROM settings WHERE key = ?", [key])
        }
    }
}
