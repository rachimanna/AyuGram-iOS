import Foundation
import SQLite3

/// Minimal, dependency-free SQLite wrapper (replaces Android Room for the AyuGram database).
/// Not thread-safe by itself: callers serialize access (AyuDatabase uses one serial queue).
final class SQLiteDatabase {
    enum DBError: Swift.Error, CustomStringConvertible {
        case open(String), prepare(String, sql: String), step(String)
        var description: String {
            switch self {
            case .open(let m): return "open: \(m)"
            case .prepare(let m, let sql): return "prepare: \(m) — \(sql)"
            case .step(let m): return "step: \(m)"
            }
        }
    }

    enum Value {
        case int(Int64), double(Double), text(String), blob(Data), null
    }

    private var handle: OpaquePointer?
    let path: String

    /// SQLITE_TRANSIENT: makes SQLite copy bound buffers.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &handle, flags, nil) != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            handle = nil
            throw DBError.open(msg)
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit {
        sqlite3_close(handle)
    }

    var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
    }

    var lastInsertRowId: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }

    func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(err)
            throw DBError.step(msg)
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: [Value] = []) throws -> Int {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw DBError.step(lastErrorMessage) }
        return changes
    }

    func query(_ sql: String, _ args: [Value] = [], _ row: (Row) throws -> Void) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                try row(Row(stmt: stmt))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw DBError.step(lastErrorMessage)
            }
        }
    }

    func scalarInt(_ sql: String, _ args: [Value] = []) throws -> Int64? {
        var result: Int64?
        try query(sql, args) { result = $0.int(0) }
        return result
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ args: [Value]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.prepare(lastErrorMessage, sql: sql)
        }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, Self.transient)
            case .blob(let v):
                _ = v.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(buf.count), Self.transient)
                }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    struct Row {
        let stmt: OpaquePointer?

        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }

        func text(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }

        func blob(_ i: Int32) -> Data? {
            let count = Int(sqlite3_column_bytes(stmt, i))
            guard count > 0, let ptr = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: ptr, count: count)
        }
    }
}

extension SQLiteDatabase.Value {
    static func optText(_ s: String?) -> Self { s.map { .text($0) } ?? .null }
    static func bool(_ b: Bool) -> Self { .int(b ? 1 : 0) }
}
