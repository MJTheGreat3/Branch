import XCTest
@testable import BranchCore

/// In-memory cloud that can be told to fail.
final class FakeDrive: CloudDrive, @unchecked Sendable {
    private let lock = NSLock()
    private var _files: [String: Data] = [:]
    private var _sessions: [URL: (path: String, data: Data)] = [:]
    private var _failures: [CloudError] = []
    private var _uploadCalls = 0
    private var _calls = 0
    private var _sessionsCreated = 0
    var reportSize: Int64?
    var corruptHash = false
    var failAtCall: Int?
    var sessionsCreated: Int { lock.withLock { _sessionsCreated } }

    var files: [String: Data] { lock.withLock { _files } }
    var uploadCalls: Int { lock.withLock { _uploadCalls } }
    func failNext(_ e: CloudError, times: Int = 1) {
        lock.withLock { _failures += Array(repeating: e, count: times) }
    }

    private func maybeFail() throws {
        try lock.withLock {
            _calls += 1
            if _calls == failAtCall { throw CloudError(kind: .network, message: "dropped") }
            if !_failures.isEmpty { throw _failures.removeFirst() }
        }
    }

    func upload(data: Data, to remotePath: String) async throws -> RemoteItem {
        try maybeFail()
        return lock.withLock {
            _uploadCalls += 1
            _files[remotePath] = data
            return RemoteItem(
                id: "id-\(remotePath)", size: reportSize ?? Int64(data.count),
                quickXorHash: corruptHash ? "bogus" : QuickXorHash.hash(data)
            )
        }
    }

    func createUploadSession(remotePath: String) async throws -> URL {
        try maybeFail()
        return lock.withLock {
            _sessionsCreated += 1
            let url = URL(string: "https://upload/\(UUID().uuidString)")!
            _sessions[url] = (remotePath, Data())
            return url
        }
    }

    func uploadChunk(session: URL, data: Data, offset: Int64, total: Int64) async throws -> ChunkResult {
        try maybeFail()
        return try lock.withLock {
            guard var s = _sessions[session] else { throw CloudError(kind: .notFound, message: "gone") }
            precondition(Int64(s.data.count) == offset)
            s.data.append(data)
            _sessions[session] = s
            if Int64(s.data.count) == total {
                _uploadCalls += 1
                _files[s.path] = s.data
                return .completed(RemoteItem(
                    id: "id-\(s.path)", size: total,
                    quickXorHash: corruptHash ? "bogus" : QuickXorHash.hash(s.data)
                ))
            }
            return .next(Int64(s.data.count))
        }
    }

    func sessionOffset(session: URL) async throws -> Int64 {
        try lock.withLock {
            guard let s = _sessions[session] else { throw CloudError(kind: .notFound, message: "gone") }
            return Int64(s.data.count)
        }
    }

    func quota() async throws -> DriveQuota { DriveQuota(total: 100, used: 0, remaining: 100) }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_700_000_000)
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
}

final class BackupEngineTests: XCTestCase {
    var dir: URL!
    var store: Store!
    var library: FolderLibrary!
    var drive: FakeDrive!
    var clock: Clock!
    var engine: BackupEngine!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-engine-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Docs/big"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Photos"), withIntermediateDirectories: true)
        store = try Store(db: Database(path: ":memory:"))
        library = FolderLibrary(store: store)
        drive = FakeDrive()
        clock = Clock()
        let clock = clock!
        engine = BackupEngine(store: store, drive: drive, now: { clock.now })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ rel: String, _ data: Data) throws {
        try data.write(to: dir.appendingPathComponent(rel))
    }

    private func path(_ rel: String) -> String { dir.appendingPathComponent(rel).path }

    func testTwoFoldersDistinctIntervalsAndNoReupload() async throws {
        let docs = try library.add(path: path("Docs"))
        let photos = try library.add(path: path("Photos"))
        try library.setInterval(id: docs.id, .hourly)
        try library.setInterval(id: photos.id, .daily)
        try write("Docs/a.txt", Data("a".utf8))
        try write("Photos/p.jpg", Data("p".utf8))

        await engine.tick()
        XCTAssertEqual(drive.files.keys.sorted(), ["Docs/a.txt", "Photos/p.jpg"])
        XCTAssertEqual(try store.folder(id: docs.id)?.status, .backedUp)
        XCTAssertNotNil(try store.folder(id: docs.id)?.lastSuccess)

        // An hour later only Docs is due; nothing changed, so nothing uploads.
        clock.advance(3601)
        let due = try library.tree().dueFolders(now: clock.now).map(\.id)
        XCTAssertEqual(due, [docs.id])
        await engine.tick()
        XCTAssertEqual(drive.uploadCalls, 2)

        // Changed file uploads again.
        try write("Docs/a.txt", Data("changed".utf8))
        try library.scheduleNow(id: docs.id)
        await engine.tick()
        XCTAssertEqual(drive.files["Docs/a.txt"], Data("changed".utf8))
        XCTAssertEqual(drive.uploadCalls, 3)
    }

    func testChildOverrideOwnsSubtree() async throws {
        let docs = try library.add(path: path("Docs"))
        let big = try library.add(path: path("Docs/big"))
        XCTAssertEqual(big.parentID, docs.id)
        try library.setInterval(id: big.id, .weekly)
        try write("Docs/a.txt", Data("a".utf8))
        try write("Docs/big/huge.bin", Data("b".utf8))

        try await engine.scan(folderID: docs.id)
        XCTAssertEqual(try store.jobs().map(\.relativePath), ["a.txt"])
        try await engine.scan(folderID: big.id)
        XCTAssertEqual(try store.jobs().map(\.relativePath).sorted(), ["a.txt", "big/huge.bin"])
        await engine.processQueue()
        XCTAssertEqual(drive.files.keys.sorted(), ["Docs/a.txt", "Docs/big/huge.bin"])
    }

    func testExcludedSubfolderSkipped() async throws {
        let docs = try library.add(path: path("Docs"))
        try library.exclude(path: path("Docs/big"))
        try write("Docs/big/x", Data("x".utf8))
        try write("Docs/y", Data("y".utf8))
        try await engine.scan(folderID: docs.id)
        XCTAssertEqual(try store.jobs().map(\.relativePath), ["y"])
    }

    func testRetryThenSuccess() async throws {
        let docs = try library.add(path: path("Docs"))
        try write("Docs/a.txt", Data("a".utf8))
        drive.failNext(CloudError(kind: .network, message: "offline"))

        await engine.tick()
        XCTAssertTrue(drive.files.isEmpty)
        let job = try XCTUnwrap(store.jobs().first)
        XCTAssertEqual(job.state, .queued)
        XCTAssertEqual(job.attempts, 1)
        XCTAssertEqual(try store.folder(id: docs.id)?.status, .queued)
        XCTAssertNotEqual(try store.folder(id: docs.id)?.status, .backedUp)

        clock.advance(31)
        await engine.processQueue()
        XCTAssertEqual(drive.files.keys.sorted(), ["Docs/a.txt"])
        XCTAssertEqual(try store.folder(id: docs.id)?.status, .backedUp)
    }

    func testQuotaFailureNeedsAttention() async throws {
        let docs = try library.add(path: path("Docs"))
        try write("Docs/a.txt", Data("a".utf8))
        drive.failNext(CloudError(kind: .quotaExceeded, status: 507, message: "full"))
        await engine.tick()
        XCTAssertEqual(try store.jobs().first?.state, .failed)
        let f = try XCTUnwrap(store.folder(id: docs.id))
        XCTAssertEqual(f.status, .needsAttention)
        XCTAssertEqual(f.lastError, "full")
        XCTAssertNil(f.lastSuccess)

        try store.retryFailedJobs(folderID: docs.id)
        await engine.processQueue()
        XCTAssertEqual(try store.folder(id: docs.id)?.status, .backedUp)
    }

    func testSizeMismatchNotReportedAsSuccess() async throws {
        let docs = try library.add(path: path("Docs"))
        try write("Docs/a.txt", Data("abc".utf8))
        drive.reportSize = 1
        await engine.tick()
        XCTAssertNotEqual(try store.folder(id: docs.id)?.status, .backedUp)
        XCTAssertNil(try store.files(rootID: docs.id)["a.txt"]?.uploadedAt)
    }

    func testHashMismatchNotReportedAsSuccess() async throws {
        let docs = try library.add(path: path("Docs"))
        try write("Docs/a.txt", Data("abc".utf8))
        drive.corruptHash = true
        await engine.tick()
        let job = try XCTUnwrap(store.jobs().first)
        XCTAssertEqual(job.state, .queued)
        XCTAssertEqual(job.lastError, "Uploaded content does not match the local file (hash mismatch)")
        XCTAssertNil(try store.files(rootID: docs.id)["a.txt"]?.uploadedAt)

        drive.corruptHash = false
        clock.advance(60)
        await engine.processQueue()
        XCTAssertEqual(try store.folder(id: docs.id)?.status, .backedUp)
    }

    func testLargeFileResumesSession() async throws {
        let docs = try library.add(path: path("Docs"))
        let size = Int(GraphDrive.simpleUploadLimit) + Int(GraphDrive.chunkSize) + 123
        let blob = Data((0..<size).map { UInt8($0 % 251) })
        try write("Docs/big/blob.bin", blob)
        try await engine.scan(folderID: docs.id)

        // Calls: 1 create session, 2 first chunk, 3 second chunk (fails).
        drive.failAtCall = 3
        await engine.processQueue()
        let job = try XCTUnwrap(store.jobs().first)
        XCTAssertEqual(job.state, .queued)
        XCTAssertNotNil(job.sessionURL)
        XCTAssertEqual(job.bytesUploaded, GraphDrive.chunkSize)
        XCTAssertNotEqual(try store.folder(id: docs.id)?.status, .backedUp)

        clock.advance(60)
        await engine.processQueue()
        XCTAssertEqual(drive.files["Docs/big/blob.bin"], blob)
        XCTAssertEqual(drive.sessionsCreated, 1)
        XCTAssertEqual(try store.folder(id: docs.id)?.status, .backedUp)
    }

    func testMissingFilesNeverDeleteCloudCopy() async throws {
        _ = try library.add(path: path("Docs"))
        try write("Docs/a.txt", Data("a".utf8))
        await engine.tick()
        try FileManager.default.removeItem(atPath: path("Docs/a.txt"))
        clock.advance(4000)
        await engine.tick()
        XCTAssertNotNil(drive.files["Docs/a.txt"])
    }

    func testRemoveKeepsLocalFiles() async throws {
        let docs = try library.add(path: path("Docs"))
        try write("Docs/a.txt", Data("a".utf8))
        await engine.tick()
        try library.remove(id: docs.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("Docs/a.txt")))
        XCTAssertNotNil(drive.files["Docs/a.txt"])
        XCTAssertTrue(try store.allFolders().isEmpty)
    }

    func testRecoverRequeuesInterrupted() async throws {
        let docs = try library.add(path: path("Docs"))
        try write("Docs/a.txt", Data("a".utf8))
        try await engine.scan(folderID: docs.id)
        var job = try XCTUnwrap(store.jobs().first)
        job.state = .uploading
        try store.update(job)

        let clock = clock!
        let restarted = BackupEngine(store: store, drive: drive, now: { clock.now })
        try await restarted.recover()
        await restarted.processQueue()
        XCTAssertEqual(drive.files.keys.sorted(), ["Docs/a.txt"])
    }

    func testPausedFolderNotScanned() async throws {
        let docs = try library.add(path: path("Docs"))
        try library.setPaused(id: docs.id, true)
        try write("Docs/a.txt", Data("a".utf8))
        await engine.tick()
        XCTAssertTrue(drive.files.isEmpty)
        XCTAssertEqual(try store.folder(id: docs.id)?.status, .paused)
    }

    func testBackoffGrowsAndCaps() async {
        let b1 = await engine.backoff(attempt: 1)
        let b3 = await engine.backoff(attempt: 3)
        let b20 = await engine.backoff(attempt: 20)
        XCTAssertEqual(b1, 30)
        XCTAssertEqual(b3, 120)
        XCTAssertEqual(b20, 3600)
    }
}
