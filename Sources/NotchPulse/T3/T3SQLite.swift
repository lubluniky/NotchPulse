import Foundation
import SQLite3

// Thin, read-only SQLite wrapper used by the T3 data layer.
// Not thread-safe by design: every instance is confined to T3Monitor's serial queue.

private let t3SQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct T3SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String

    var description: String { "SQLite \(code): \(message)" }

    /// Errors after which the connection should be dropped and reopened on the next refresh.
    var invalidatesConnection: Bool {
        switch code & 0xFF {
        case SQLITE_CANTOPEN, SQLITE_NOTADB, SQLITE_CORRUPT, SQLITE_IOERR, SQLITE_SCHEMA, SQLITE_READONLY:
            return true
        default:
            return false
        }
    }
}

final class T3SQLiteConnection {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    /// Opens `path` strictly read-only. The database is never written, vacuumed or checkpointed.
    init(readOnlyPath path: String, busyTimeoutMs: Int32 = 750) throws {
        var db: OpaquePointer?
        // NOMUTEX: the connection is only ever touched from one serial queue.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let db { sqlite3_close_v2(db) }
            throw T3SQLiteError(code: rc, message: message)
        }
        handle = db
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, busyTimeoutMs)
        do {
            try execute("PRAGMA query_only = 1")
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        for (_, stmt) in statements { sqlite3_finalize(stmt) }
        statements.removeAll()
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    func execute(_ sql: String) throws {
        guard let handle else { throw T3SQLiteError(code: SQLITE_MISUSE, message: "connection closed") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorMessage)
            throw T3SQLiteError(code: rc, message: message)
        }
    }

    /// Runs `body` inside one read transaction so every query sees the same snapshot.
    /// The transaction is always closed before returning so the writer's checkpoints are never blocked.
    func readTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Executes a (cached) prepared statement, calling `row` for every result row.
    func query(_ sql: String, _ bindings: [String] = [], row: (T3SQLiteRow) throws -> Void) throws {
        let stmt = try prepared(sql)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        for (index, value) in bindings.enumerated() {
            let rc = sqlite3_bind_text(stmt, Int32(index + 1), value, -1, t3SQLiteTransient)
            if rc != SQLITE_OK { throw lastError(rc) }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                try row(T3SQLiteRow(stmt: stmt))
            } else if rc == SQLITE_DONE {
                return
            } else {
                throw lastError(rc)
            }
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] { return cached }
        guard let handle else { throw T3SQLiteError(code: SQLITE_MISUSE, message: "connection closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw lastError(rc)
        }
        statements[sql] = stmt
        return stmt
    }

    private func lastError(_ rc: Int32) -> T3SQLiteError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
        return T3SQLiteError(code: rc, message: message)
    }
}

struct T3SQLiteRow {
    fileprivate let stmt: OpaquePointer

    func string(_ column: Int32) -> String? {
        guard sqlite3_column_type(stmt, column) != SQLITE_NULL,
              let text = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: text)
    }

    func int(_ column: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, column))
    }

    func bool(_ column: Int32) -> Bool {
        sqlite3_column_int64(stmt, column) != 0
    }
}
