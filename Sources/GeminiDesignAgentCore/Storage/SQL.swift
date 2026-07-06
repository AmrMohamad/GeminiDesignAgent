import Foundation
import CSQLite

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum SQLError: Error {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)
    case execFailed(String)
    case notFound
}

public final class SQLiteDB: @unchecked Sendable {
    private let db: OpaquePointer
    private let path: String
    private let lock = NSLock()

    public init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let rc = sqlite3_open(path, &handle)
        guard rc == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw SQLError.openFailed(msg)
        }
        self.db = handle!
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
    }

    deinit {
        sqlite3_close(db)
    }

    public func withLock<T>(_ block: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try block()
    }

    public func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        guard rc == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw SQLError.execFailed(msg)
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLError.prepareFailed(msg)
        }
        return Statement(stmt: stmt, db: db, lock: lock)
    }

    public func scalar(_ sql: String) throws -> String? {
        let stmt = try prepare(sql)
        defer { stmt.finalize() }
        guard try stmt.step() else { return nil }
        return stmt.columnText(0)
    }

    public func scalarInt(_ sql: String) throws -> Int {
        let stmt = try prepare(sql)
        defer { stmt.finalize() }
        guard try stmt.step() else { return 0 }
        return stmt.columnInt(0)
    }

    public func lastInsertRowId() -> Int64 {
        sqlite3_last_insert_rowid(db)
    }

    public func transaction<T>(_ block: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try block()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

public final class Statement: @unchecked Sendable {
    private let stmt: OpaquePointer
    private let db: OpaquePointer
    private let dbLock: NSLock

    fileprivate init(stmt: OpaquePointer, db: OpaquePointer, lock: NSLock) {
        self.stmt = stmt
        self.db = db
        self.dbLock = lock
    }

    public func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default:
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLError.stepFailed(msg)
        }
    }

    public func finalize() {
        sqlite3_finalize(stmt)
    }

    public func reset() throws {
        let rc = sqlite3_reset(stmt)
        guard rc == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLError.stepFailed(msg)
        }
    }

    public func bind(_ value: String, at index: Int32) throws {
        let rc = sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        guard rc == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLError.bindFailed(msg)
        }
    }

    public func bind(_ value: Int, at index: Int32) throws {
        let rc = sqlite3_bind_int(stmt, index, Int32(value))
        guard rc == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLError.bindFailed(msg)
        }
    }

    public func bind(_ value: Double, at index: Int32) throws {
        let rc = sqlite3_bind_double(stmt, index, value)
        guard rc == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLError.bindFailed(msg)
        }
    }

    public func bindNull(at index: Int32) throws {
        let rc = sqlite3_bind_null(stmt, index)
        guard rc == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLError.bindFailed(msg)
        }
    }

    public func columnText(_ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }

    public func columnInt(_ index: Int32) -> Int {
        Int(sqlite3_column_int(stmt, index))
    }

    public func columnDouble(_ index: Int32) -> Double {
        sqlite3_column_double(stmt, index)
    }
}
