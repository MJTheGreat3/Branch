import Foundation
import SQLite3

public struct DatabaseError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Values that can be bound to statement parameters.
public enum SQLValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension Date: SQLBindable { public var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

/// A row read from a statement, accessed by column index.
public struct Row {
    fileprivate let stmt: OpaquePointer

    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func intOrNil(_ i: Int32) -> Int64? { isNull(i) ? nil : int(i) }
    public func bool(_ i: Int32) -> Bool { int(i) != 0 }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func date(_ i: Int32) -> Date { Date(timeIntervalSince1970: double(i)) }
    public func dateOrNil(_ i: Int32) -> Date? { isNull(i) ? nil : date(i) }

    public func text(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }

    public func textOrNil(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }

    public func blobOrNil(_ i: Int32) -> Data? {
        guard !isNull(i), let p = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
}

/// Thin, serialized wrapper over a SQLite connection.
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()

    /// Opens (or creates) a database at `path`. Use ":memory:" for tests.
    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw DatabaseError(message: "open failed: \(msg)")
        }
        try execute("PRAGMA foreign_keys = ON")
        if path != ":memory:" {
            try execute("PRAGMA journal_mode = WAL")
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    private var errorMessage: String {
        String(cString: sqlite3_errmsg(handle))
    }

    /// Runs one or more statements with no parameters.
    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw DatabaseError(message: msg)
        }
    }

    /// Runs a single statement with parameters, returning nothing.
    public func run(_ sql: String, _ params: [any SQLBindable] = []) throws {
        try query(sql, params) { _ in }
    }

    /// Runs a statement and calls `each` per result row.
    public func query(_ sql: String, _ params: [any SQLBindable] = [], _ each: (Row) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError(message: "prepare failed: \(errorMessage) — \(sql)")
        }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                try each(Row(stmt: stmt))
            } else if rc == SQLITE_DONE {
                return
            } else {
                throw DatabaseError(message: "step failed: \(errorMessage) — \(sql)")
            }
        }
    }

    /// Collects mapped rows into an array.
    public func all<T>(_ sql: String, _ params: [any SQLBindable] = [], _ map: (Row) throws -> T) throws -> [T] {
        var out: [T] = []
        try query(sql, params) { out.append(try map($0)) }
        return out
    }

    /// Returns the first mapped row, if any.
    public func first<T>(_ sql: String, _ params: [any SQLBindable] = [], _ map: (Row) throws -> T) throws -> T? {
        try all(sql, params, map).first
    }

    public var lastInsertID: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    public var changes: Int {
        lock.lock(); defer { lock.unlock() }
        return Int(sqlite3_changes(handle))
    }

    /// Runs `body` inside a transaction, rolling back on error.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public var userVersion: Int {
        get { (try? first("PRAGMA user_version") { Int($0.int(0)) }) ?? 0 }
    }

    public func setUserVersion(_ v: Int) throws {
        try execute("PRAGMA user_version = \(v)")
    }

    private func bind(_ stmt: OpaquePointer, _ params: [any SQLBindable]) throws {
        for (offset, param) in params.enumerated() {
            let i = Int32(offset + 1)
            let rc: Int32
            switch param.sqlValue {
            case .null: rc = sqlite3_bind_null(stmt, i)
            case .int(let v): rc = sqlite3_bind_int64(stmt, i, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, i, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, i, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, i, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            }
            guard rc == SQLITE_OK else {
                throw DatabaseError(message: "bind failed at \(i): \(errorMessage)")
            }
        }
    }
}
