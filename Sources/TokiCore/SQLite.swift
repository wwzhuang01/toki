import Foundation
import SQLite3

enum ReadFailure: Error { case invalidData, sqlite(String), decompression }

final class ReadDatabase {
    private let handle: OpaquePointer

    init(_ path: String) throws {
        let walPath = path + "-wal"
        let hasNonEmptyWal = (FileStamp(walPath)?.size ?? 0) > 0
        let openPath: String
        let flags: Int32
        if !hasNonEmptyWal {
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "?#")
            let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
            openPath = "file:\(encoded)?mode=ro&immutable=1"
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        } else {
            openPath = path
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        }
        var database: OpaquePointer?
        let status = sqlite3_open_v2(openPath, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw ReadFailure.sqlite("Cannot open read-only database")
        }
        handle = database
        sqlite3_busy_timeout(handle, 100)
    }

    deinit { sqlite3_close(handle) }

    func rows(_ sql: String, binds: [String] = [], _ body: (OpaquePointer) throws -> Void = { _ in }) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ReadFailure.sqlite(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in binds.enumerated() {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try body(statement)
            case SQLITE_DONE: return
            default: throw ReadFailure.sqlite(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    func transaction<Result>(_ read: () throws -> Result) throws -> Result {
        try rows("BEGIN")
        do {
            let result = try read()
            try rows("COMMIT")
            return result
        } catch {
            try? rows("ROLLBACK")
            throw error
        }
    }

    func tables() throws -> Set<String> {
        var names: Set<String> = []
        try rows("SELECT name FROM sqlite_master WHERE type = 'table'") { names.insert(Self.string($0, 0)) }
        return names
    }

    func columns(_ table: String) throws -> Set<String> {
        var names: Set<String> = []
        try rows("PRAGMA table_info(\(table))") { names.insert(Self.string($0, 1)) }
        return names
    }

    static func string(_ row: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(row, index) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(row, index))), as: UTF8.self)
    }

    static func integer(_ row: OpaquePointer, _ index: Int32) -> Int64? {
        sqlite3_column_type(row, index) == SQLITE_NULL ? nil : sqlite3_column_int64(row, index)
    }

    static func data(_ row: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(row, index) == SQLITE_BLOB else { return nil }
        guard let bytes = sqlite3_column_blob(row, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, index)))
    }
}
