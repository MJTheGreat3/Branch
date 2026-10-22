import XCTest
@testable import BranchCore

final class EventsTests: XCTestCase {
    func testQuotaLevels() {
        let q = DriveQuota(total: 1000, used: 500, remaining: 500)
        XCTAssertEqual(QuotaLevel.assess(q, pendingBytes: 100), .ok)
        XCTAssertEqual(QuotaLevel.assess(q, pendingBytes: 600), .insufficient)
        XCTAssertEqual(QuotaLevel.assess(DriveQuota(total: 1000, used: 950, remaining: 50), pendingBytes: 0), .low)
        XCTAssertEqual(QuotaLevel.assess(DriveQuota(total: 1000, used: 1000, remaining: 0), pendingBytes: 0), .full)
        XCTAssertEqual(QuotaLevel.assess(DriveQuota(total: 0, used: 0, remaining: 0), pendingBytes: 10), .ok)
    }

    func testQuotaOnlyWhenWorse() {
        XCTAssertEqual(BackupEvent.quotaChange(from: nil, to: .low), .quota(.low))
        XCTAssertNil(BackupEvent.quotaChange(from: .low, to: .low))
        XCTAssertNil(BackupEvent.quotaChange(from: .full, to: .low))
        XCTAssertNil(BackupEvent.quotaChange(from: nil, to: .ok))
    }

    func testFolderTransitions() {
        let a = ManagedFolder(id: 1, path: "/x/Docs", status: .queued)
        var aDone = a
        aDone.status = .backedUp
        aDone.lastSuccess = Date()

        XCTAssertEqual(BackupEvent.changes(from: [a], to: [aDone]), [.firstBackupCompleted(folderID: 1, name: "Docs")])
        // Second success isn't "first".
        XCTAssertEqual(BackupEvent.changes(from: [aDone], to: [aDone]), [])

        var broken = aDone
        broken.status = .needsAttention
        broken.lastError = "full"
        XCTAssertEqual(BackupEvent.changes(from: [aDone], to: [broken]), [.needsAttention(folderID: 1, name: "Docs", reason: "full")])
        XCTAssertEqual(BackupEvent.changes(from: [broken], to: [broken]), [], "reported once")
        XCTAssertEqual(BackupEvent.changes(from: [broken], to: [aDone]), [.recovered(folderID: 1, name: "Docs")])

        // New folders (no previous snapshot) produce nothing.
        XCTAssertEqual(BackupEvent.changes(from: [], to: [broken]), [])
    }
}
