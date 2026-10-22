import XCTest
@testable import BranchCore

final class CloudOnlyTests: XCTestCase {
    var dir: URL!
    var trash: URL!
    var store: Store!
    var library: FolderLibrary!
    var drive: FakeDrive!
    var clock: Clock!
    var engine: BackupEngine!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("branch-cloud-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        dir = base.appendingPathComponent("home")
        trash = base.appendingPathComponent("Trash")
        for d in [dir.appendingPathComponent("Docs/keep"), trash!] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        store = try Store(db: Database(path: ":memory:"))
        library = FolderLibrary(store: store)
        drive = FakeDrive()
        clock = Clock()
        let clock = clock!
        let trash = trash!
        var options = BackupEngine.Options()
        options.moveToTrash = { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        }
        engine = BackupEngine(store: store, drive: drive, options: options, now: { clock.now })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func path(_ rel: String) -> String { dir.appendingPathComponent(rel).path }

    /// Writes a file whose mtime is well before the fake clock, so it counts as idle.
    private func writeOld(_ rel: String, _ s: String) throws {
        try Data(s.utf8).write(to: dir.appendingPathComponent(rel))
        try FileManager.default.setAttributes([.modificationDate: clock.now.addingTimeInterval(-3600)], ofItemAtPath: path(rel))
    }

    private func cloudOnlyDocs() async throws -> ManagedFolder {
        let docs = try library.add(path: path("Docs"))
        try library.setAvailability(id: docs.id, .cloudOnly)
        await engine.tick()
        return docs
    }

    func testOffloadReplacesVerifiedFileWithStandIn() async throws {
        try writeOld("Docs/report.pdf", "important")
        let docs = try await cloudOnlyDocs()

        XCTAssertFalse(FileManager.default.fileExists(atPath: path("Docs/report.pdf")))
        let standIn = try StandIn.read(from: path("Docs/report.pdf.branch"))
        XCTAssertEqual(standIn.remotePath, "Docs/report.pdf")
        XCTAssertEqual(standIn.size, 9)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 1, "went to Trash")
        XCTAssertEqual(drive.files["Docs/report.pdf"], Data("important".utf8), "cloud copy untouched")

        let totals = try store.fileTotals(rootID: docs.id)
        XCTAssertEqual(totals.offloadedCount, 1)
        XCTAssertEqual(totals.localBytes, 0)

        // Rescanning doesn't re-upload, queue the stand-in, or forget the cloud copy.
        try library.scheduleNow(id: docs.id)
        await engine.tick()
        XCTAssertEqual(drive.uploadCalls, 1)
        XCTAssertTrue(try store.jobs().isEmpty)
        XCTAssertNotNil(try store.files(rootID: docs.id)["report.pdf"]?.offloadedAt)
    }

    func testNothingOffloadedUnlessSafe() async throws {
        // Recently modified.
        try Data("fresh".utf8).write(to: dir.appendingPathComponent("Docs/fresh.txt"))
        try FileManager.default.setAttributes([.modificationDate: clock.now], ofItemAtPath: path("Docs/fresh.txt"))
        // Cloud copy doesn't match.
        try writeOld("Docs/mismatch.txt", "m")
        drive.corruptRemoteHash = true
        _ = try await cloudOnlyDocs()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("Docs/fresh.txt")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("Docs/mismatch.txt")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("Docs/mismatch.txt.branch")))
    }

    func testLocalOverrideInsideCloudOnlyStaysLocal() async throws {
        try writeOld("Docs/keep/k.txt", "k")
        try writeOld("Docs/gone.txt", "g")
        let keep = try library.add(path: path("Docs/keep"))
        try library.setAvailability(id: keep.id, .localAndCloud)
        _ = try await cloudOnlyDocs()
        try library.scheduleNow(id: keep.id)
        await engine.tick()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("Docs/keep/k.txt")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("Docs/gone.txt")))
    }

    func testRestoreBringsBackVerifiedFileAndHoldsIt() async throws {
        try writeOld("Docs/report.pdf", "important")
        let docs = try await cloudOnlyDocs()
        let original = try XCTUnwrap(store.files(rootID: docs.id)["report.pdf"]?.modified)

        let restored = try await engine.restore(standInPath: path("Docs/report.pdf.branch"))
        XCTAssertEqual(restored, path("Docs/report.pdf"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: restored)), Data("important".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("Docs/report.pdf.branch")))
        let mtime = try FileManager.default.attributesOfItem(atPath: restored)[.modificationDate] as? Date
        XCTAssertEqual(mtime!.timeIntervalSince1970, original.timeIntervalSince1970, accuracy: 0.001)

        // Not re-uploaded, and not offloaded again during the hold.
        try library.scheduleNow(id: docs.id)
        await engine.tick()
        XCTAssertEqual(drive.uploadCalls, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored))

        // After the hold it goes back to the cloud.
        clock.advance(8 * 24 * 3600)
        await engine.offloadPass()
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored))
    }

    func testCorruptDownloadIsNotPutInPlace() async throws {
        try writeOld("Docs/report.pdf", "important")
        _ = try await cloudOnlyDocs()
        drive.corruptDownload = true
        do {
            try await engine.restore(standInPath: path("Docs/report.pdf.branch"))
            XCTFail("expected verification failure")
        } catch let e as BackupEngine.RestoreError {
            XCTAssertEqual(e, .verificationFailed("report.pdf"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("Docs/report.pdf")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("Docs/report.pdf.branch")))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: path("Docs")).filter { $0.contains("branch-restore") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testRestoreNeverOverwritesADifferentFile() async throws {
        try writeOld("Docs/report.pdf", "important")
        _ = try await cloudOnlyDocs()
        try Data("new work".utf8).write(to: dir.appendingPathComponent("Docs/report.pdf"))
        do {
            try await engine.restore(standInPath: path("Docs/report.pdf.branch"))
            XCTFail("expected fileExists")
        } catch let e as BackupEngine.RestoreError {
            XCTAssertEqual(e, .fileExists(path("Docs/report.pdf")))
        }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("Docs/report.pdf")), Data("new work".utf8))
    }

    func testRestoreWorksFromStandInAloneAndRestoreAll() async throws {
        try writeOld("Docs/a.txt", "a")
        try writeOld("Docs/keep/b.txt", "b")
        _ = try await cloudOnlyDocs()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("Docs/keep/b.txt.branch")))

        // A fresh engine with an empty database can still restore.
        let freshStore = try Store(db: Database(path: ":memory:"))
        let fresh = BackupEngine(store: freshStore, drive: drive)
        let result = await fresh.restoreAll(under: path("Docs"))
        XCTAssertEqual(result.restored, 2)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("Docs/keep/b.txt")), Data("b".utf8))
    }

    func testPuttingBackFromTrashIsReconciled() async throws {
        try writeOld("Docs/a.txt", "a")
        let docs = try await cloudOnlyDocs()
        let trashed = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: trash.path).first)
        try FileManager.default.moveItem(atPath: trash.appendingPathComponent(trashed).path, toPath: path("Docs/a.txt"))
        // Make it look recently touched so it isn't immediately offloaded again.
        try FileManager.default.setAttributes([.modificationDate: clock.now], ofItemAtPath: path("Docs/a.txt"))
        await engine.offloadPass()
        XCTAssertNil(try store.files(rootID: docs.id)["a.txt"]?.offloadedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("Docs/a.txt.branch")))
    }

    func testPrefixMatchesDecomposedNames() throws {
        let store = try Store(db: Database(path: ":memory:"))
        let root = try store.insert(ManagedFolder(path: "/tmp/r", remoteName: "r"))
        let nfd = "Re\u{0301}sume\u{0301}"  // decomposed accents, as macOS often stores them
        try store.upsert(FileRecord(rootID: root.id, relativePath: nfd + "/cv.pdf", size: 1, modified: Date(), uploadedAt: Date()))
        try store.upsert(FileRecord(rootID: root.id, relativePath: "Other/x", size: 1, modified: Date(), uploadedAt: Date()))
        XCTAssertEqual(try store.offloadCandidates(rootID: root.id, prefix: nfd, limit: 10).map(\.relativePath), [nfd + "/cv.pdf"])
    }
}
