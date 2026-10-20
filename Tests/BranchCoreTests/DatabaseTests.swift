import XCTest
@testable import BranchCore

final class DatabaseTests: XCTestCase {
    func testRoundTrip() throws {
        let db = try Database(path: ":memory:")
        try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, at REAL, blob BLOB)")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db.run("INSERT INTO t (name, at, blob) VALUES (?, ?, ?)", ["a", now, Data([1, 2, 3])])
        try db.run("INSERT INTO t (name, at, blob) VALUES (?, ?, ?)", [String?.none, Date?.none, Data?.none])

        let rows = try db.all("SELECT name, at, blob FROM t ORDER BY id") {
            ($0.textOrNil(0), $0.dateOrNil(1), $0.blobOrNil(2))
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].0, "a")
        XCTAssertEqual(rows[0].1, now)
        XCTAssertEqual(rows[0].2, Data([1, 2, 3]))
        XCTAssertNil(rows[1].0)
        XCTAssertNil(rows[1].1)
    }

    func testTransactionRollsBack() throws {
        let db = try Database(path: ":memory:")
        try db.execute("CREATE TABLE t (v INTEGER)")
        struct Boom: Error {}
        XCTAssertThrowsError(try db.transaction {
            try db.run("INSERT INTO t VALUES (1)")
            throw Boom()
        })
        XCTAssertEqual(try db.first("SELECT COUNT(*) FROM t") { $0.int(0) }, 0)
    }
}
