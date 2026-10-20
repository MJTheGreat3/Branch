import XCTest
@testable import BranchCore

final class SmokeTests: XCTestCase {
    func testIntervalSeconds() {
        XCTAssertEqual(BackupInterval.hourly.seconds, 3600)
    }
}
