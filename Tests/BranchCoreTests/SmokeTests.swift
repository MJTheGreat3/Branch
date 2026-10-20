import XCTest
@testable import BranchCore

final class SmokeTests: XCTestCase {
    func testVersion() {
        XCTAssertFalse(BranchCore.version.isEmpty)
    }
}
