import Foundation

/// Scans due folders, queues changed files and uploads them with retries.
///
/// All progress is persisted in the store, so a crash or quit loses nothing:
/// interrupted jobs are re-queued on start and large uploads resume from their session.
public actor BackupEngine {
    public struct Options: Sendable {
        public var maxConcurrentUploads = 3
        public var maxAttempts = 8
        public var baseBackoff: TimeInterval = 30
        public var maxBackoff: TimeInterval = 3600
        public init() {}
    }

    public let store: Store
    private var drive: CloudDrive?
    private let options: Options
    private let now: @Sendable () -> Date
    private var isProcessing = false
    private var onChange: (@Sendable () -> Void)?

    public init(
        store: Store,
        drive: CloudDrive?,
        options: Options = Options(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.drive = drive
        self.options = options
        self.now = now
    }

    public func setDrive(_ drive: CloudDrive?) {
        self.drive = drive
    }

    public func setOnChange(_ handler: (@Sendable () -> Void)?) {
        onChange = handler
    }

    /// Call once at launch: re-queues jobs interrupted by a quit or crash.
    public func recover() throws {
        try store.requeueInterruptedJobs()
        for f in try store.allFolders() where f.status == .uploading {
            try store.setStatus(folderID: f.id, .queued)
        }
    }

    /// One scheduling pass: scan every due folder, then drain the upload queue.
    public func tick() async {
        // Follow folders the user moved or renamed before deciding what's due.
        _ = try? FolderLibrary(store: store).relocateMovedFolders()
        if let tree = try? FolderTree(store.allFolders()) {
            for folder in tree.dueFolders(now: now()) {
                do {
                    try scan(folderID: folder.id)
                } catch let e as ScanError {
                    try? store.setStatus(folderID: folder.id, .needsAttention, error: e.description)
                } catch {
                    try? store.setStatus(folderID: folder.id, .needsAttention, error: "Scan failed: \(error.localizedDescription)")
                }
            }
        }
        notify()
        await processQueue()
    }

    // MARK: Scan

    /// Scans one folder's subtree and queues changed files. Returns the number queued.
    @discardableResult
    public func scan(folderID: Int64) throws -> Int {
        let tree = FolderTree(try store.allFolders())
        guard let folder = tree.folders[folderID], let root = tree.root(of: folderID) else { return 0 }
        let policy = tree.policy(for: folderID)
        guard !policy.isExcluded else { return 0 }

        let skipped = tree.skippedPaths(under: folderID)
        let rules = ExclusionRules(patterns: try store.exclusionPatterns())
            .adding(tree.excludePatterns(for: folderID))
        let scanned = try Scanner.enumerate(
            folderPath: folder.path, rootPath: root.path, skipping: skipped, rules: rules
        )

        // Only compare with records inside this folder's own scope.
        let prefix = FolderTree.relative(folder.path, to: root.path) ?? ""
        let skippedRel = skipped.compactMap { FolderTree.relative($0, to: root.path) }
        func inScope(_ rel: String) -> Bool {
            let inside = prefix.isEmpty || rel.hasPrefix(prefix + "/")
            return inside && !skippedRel.contains { rel == $0 || rel.hasPrefix($0 + "/") }
        }
        let known = try store.files(rootID: root.id).filter { inScope($0.key) }
        let result = Scanner.diff(scanned: scanned, known: known, rootPath: root.path)

        let pending = Dictionary(
            try reconcileJobs(rootID: root.id, tree: tree).map { ($0.relativePath, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        let at = now()
        var queued = 0
        try store.db.transaction {
            try store.forgetPending(rootID: root.id, relativePaths: result.missing)
            for (file, hash) in result.touched {
                var rec = known[file.relativePath]!
                rec.size = file.size
                rec.modified = file.modified
                rec.sha256 = hash
                try store.upsert(rec)
            }
            for (file, hash) in result.changed {
                if let job = pending[file.relativePath], job.sha256 == hash, job.state != .failed {
                    continue
                }
                let prev = known[file.relativePath]
                try store.upsert(FileRecord(
                    rootID: root.id, relativePath: file.relativePath, size: file.size, modified: file.modified,
                    sha256: hash, remoteItemID: prev?.remoteItemID, uploadedAt: nil
                ))
                try store.enqueue(UploadJob(
                    folderID: folderID, rootID: root.id, relativePath: file.relativePath,
                    size: file.size, modified: file.modified, sha256: hash, notBefore: at
                ))
                queued += 1
            }

            var f = folder
            f.nextRun = at.addingTimeInterval(policy.interval.seconds)
            let counts = try store.jobCounts(folderID: folderID)
            if counts.failed > 0 {
                f.status = .needsAttention
            } else if counts.queued + counts.uploading > 0 {
                f.status = .queued
                f.lastError = nil
            } else {
                f.status = .backedUp
                f.lastSuccess = at
                f.lastError = nil
            }
            try store.update(f)
        }
        return queued
    }

    /// Brings queued jobs in line with the current tree: jobs under an excluded item are dropped,
    /// and jobs now under a different managed folder (one given its own settings after they were
    /// queued) move to it, so each folder's status reflects its own pending files.
    func reconcileJobs(rootID: Int64, tree: FolderTree) throws -> [UploadJob] {
        guard let root = tree.folders[rootID] else { return [] }
        var kept: [UploadJob] = []
        try store.db.transaction {
            for job in try store.jobs(rootID: rootID) {
                let path = (root.path as NSString).appendingPathComponent(job.relativePath)
                guard let owner = tree.containing(path) else { continue }
                if tree.policy(for: owner.id).isExcluded {
                    if job.state != .uploading {
                        try store.forgetPending(rootID: rootID, relativePaths: [job.relativePath])
                    }
                    continue
                }
                var j = job
                if owner.id != job.folderID {
                    try store.reassignJob(id: job.id, toFolder: owner.id)
                    j.folderID = owner.id
                }
                kept.append(j)
            }
        }
        return kept
    }

    // MARK: Queue

    /// Uploads due jobs until none remain runnable now.
    public func processQueue() async {
        guard !isProcessing, let drive else { return }
        isProcessing = true
        defer { isProcessing = false }

        while true {
            guard let batch = try? store.dueJobs(now: now(), limit: options.maxConcurrentUploads),
                  !batch.isEmpty else { break }
            await withTaskGroup(of: Void.self) { group in
                for job in batch {
                    group.addTask { await self.run(job, drive: drive) }
                }
            }
            if self.drive == nil { break }
        }
        notify()
    }

    private func run(_ job: UploadJob, drive: CloudDrive) async {
        var job = job
        job.state = .uploading
        try? store.update(job)
        try? store.setStatus(folderID: job.folderID, .uploading)
        notify()

        do {
            let tree = FolderTree(try store.allFolders())
            guard let root = tree.folders[job.rootID], let remoteName = root.remoteName else {
                try store.deleteJob(id: job.id)
                return
            }
            var rootIsDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &rootIsDir), rootIsDir.boolValue else {
                // Whole folder unreachable (moved, unmounted): keep the job for when it's back.
                throw ScanError.folderMissing(root.path)
            }
            let localPath = (root.path as NSString).appendingPathComponent(job.relativePath)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: localPath) else {
                // Source vanished since scan; nothing to back up. Deletions are never propagated.
                try store.deleteJob(id: job.id)
                try refreshFolderStatus(job.folderID)
                return
            }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attrs[.modificationDate] as? Date) ?? job.modified
            if size != job.size || abs(modified.timeIntervalSince(job.modified)) > 0.001 {
                // File changed after scan: upload what's there now, from scratch.
                job.size = size
                job.modified = modified
                job.sha256 = try Scanner.sha256(path: localPath)
                job.sessionURL = nil
                job.bytesUploaded = 0
            }

            let remotePath = remoteName + "/" + job.relativePath
            let (item, localHash) = try await upload(&job, localPath: localPath, remotePath: remotePath, drive: drive)
            try Self.verify(item, size: job.size, quickXorHash: localHash)

            try store.db.transaction {
                try store.upsert(FileRecord(
                    rootID: job.rootID, relativePath: job.relativePath, size: job.size, modified: job.modified,
                    sha256: job.sha256, remoteItemID: item.id, uploadedAt: now()
                ))
                try store.deleteJob(id: job.id)
            }
        } catch {
            fail(&job, error)
        }
        try? refreshFolderStatus(job.folderID)
        notify()
    }

    /// Confirms the cloud copy matches what was read locally. Missing remote values can't be checked and are allowed.
    static func verify(_ item: RemoteItem, size: Int64, quickXorHash: String) throws {
        guard item.size < 0 || item.size == size else {
            throw CloudError(kind: .verification, message: "Uploaded size \(item.size) does not match local size \(size)")
        }
        if let remote = item.quickXorHash, remote != quickXorHash {
            throw CloudError(kind: .verification, message: "Uploaded content does not match the local file (hash mismatch)")
        }
    }

    /// Uploads the file and returns the remote item plus the local QuickXorHash to verify against.
    private func upload(_ job: inout UploadJob, localPath: String, remotePath: String, drive: CloudDrive) async throws -> (RemoteItem, String) {
        if job.size <= GraphDrive.simpleUploadLimit {
            let data = try Data(contentsOf: URL(fileURLWithPath: localPath))
            guard Int64(data.count) == job.size else {
                throw CloudError(kind: .verification, message: "File changed while reading; will retry")
            }
            return (try await drive.upload(data: data, to: remotePath), QuickXorHash.hash(data))
        }
        // Hash before sending: if the file changes mid-upload the remote hash won't match and the job retries.
        let localHash = try QuickXorHash.hash(path: localPath)

        var offset: Int64 = 0
        var session: URL
        if let s = job.sessionURL.flatMap(URL.init(string:)),
           let resumeAt = try? await drive.sessionOffset(session: s) {
            session = s
            offset = resumeAt
        } else {
            session = try await drive.createUploadSession(remotePath: remotePath)
            job.sessionURL = session.absoluteString
            job.bytesUploaded = 0
            try store.update(job)
        }

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: localPath))
        defer { try? handle.close() }
        while true {
            try handle.seek(toOffset: UInt64(offset))
            let length = Int(min(GraphDrive.chunkSize, job.size - offset))
            guard let chunk = try handle.read(upToCount: length), chunk.count == length else {
                throw CloudError(kind: .verification, message: "Local file shrank during upload")
            }
            switch try await drive.uploadChunk(session: session, data: chunk, offset: offset, total: job.size) {
            case .completed(let item):
                return (item, localHash)
            case .next(let next):
                offset = next
                job.bytesUploaded = next
                try store.update(job)
                notify()
            }
        }
    }

    private func fail(_ job: inout UploadJob, _ error: Error) {
        let cloud = error as? CloudError
        job.attempts += 1
        job.lastError = Self.message(for: error)
        if cloud?.kind == .notFound {
            // Expired upload session: restart it next time.
            job.sessionURL = nil
            job.bytesUploaded = 0
        }
        // Auth problems (signed out, refresh failed) keep the job queued until the user signs in again.
        let retryable = cloud?.isRetryable ?? true
        if retryable && job.attempts < options.maxAttempts {
            job.state = .queued
            job.notBefore = now().addingTimeInterval(cloud?.retryAfter ?? backoff(attempt: job.attempts))
        } else {
            job.state = .failed
        }
        try? store.update(job)
    }

    static func message(for error: Error) -> String {
        switch error {
        case let e as CloudError: return e.description
        case let e as AuthError: return e.description
        case let e as ScanError: return e.description
        default: return error.localizedDescription
        }
    }

    func backoff(attempt: Int) -> TimeInterval {
        min(options.maxBackoff, options.baseBackoff * pow(2, Double(max(0, attempt - 1))))
    }

    /// Derives a folder's status from its jobs. Only marks backed up once every job is confirmed.
    private func refreshFolderStatus(_ folderID: Int64) throws {
        guard var f = try store.folder(id: folderID) else { return }
        let counts = try store.jobCounts(folderID: folderID)
        if f.isPaused {
            f.status = .paused
        } else if counts.failed > 0 {
            f.status = .needsAttention
            f.lastError = try store.firstJobError(folderID: folderID, failedOnly: true)
        } else if counts.uploading > 0 {
            f.status = .uploading
        } else if let root = FolderTree(try store.allFolders()).root(of: folderID),
                  !FileManager.default.fileExists(atPath: root.path) {
            f.status = .needsAttention
            f.lastError = ScanError.folderMissing(root.path).description
        } else if counts.queued > 0 {
            f.status = .queued
            f.lastError = try store.firstJobError(folderID: folderID, failedOnly: false)
        } else {
            f.status = .backedUp
            f.lastSuccess = now()
            f.lastError = nil
        }
        try store.update(f)
    }

    private func notify() {
        onChange?()
    }
}
