import Foundation
import CSQLite

/// One serial connection. Payloads are Codable; category and identity form a stable migration boundary.
public actor LibraryStore {
    private let connection: SQLiteConnection
    private var db: OpaquePointer { connection.value }
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let connection else { if let connection { sqlite3_close(connection) }; throw SortError.message("Could not open the local library.") }
        self.connection = SQLiteConnection(connection)
        sqlite3_busy_timeout(connection, 5_000)
        var versionStatement: OpaquePointer?
        sqlite3_prepare_v2(connection, "PRAGMA user_version", -1, &versionStatement, nil)
        let version = sqlite3_step(versionStatement) == SQLITE_ROW ? sqlite3_column_int(versionStatement, 0) : 0
        sqlite3_finalize(versionStatement)
        guard version <= 1 else { throw SortError.message("This library was created by a newer BetterNotch version.") }
        let sql = "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; BEGIN IMMEDIATE; CREATE TABLE IF NOT EXISTS records(category TEXT NOT NULL, id TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(category,id)); PRAGMA user_version=1; COMMIT;"
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw SortError.message("Could not initialize the local library.") }
    }
    public func save<T: Encodable & Sendable>(_ value: T, category: String, id: String) throws {
        let data = try JSONEncoder().encode(value)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO records(category,id,payload) VALUES(?,?,?)", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, category, -1, transient); sqlite3_bind_text(stmt, 2, id, -1, transient)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    public func list<T: Decodable & Sendable>(_ type: T.Type, category: String) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM records WHERE category=? ORDER BY rowid", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, category, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var values: [T] = []
        while true {
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return values }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { throw failure() }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
            values.append(try JSONDecoder().decode(type, from: data))
        }
    }
    public func remove(category: String, id: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM records WHERE category=? AND id=?", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, category, -1, transient); sqlite3_bind_text(stmt, 2, id, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    private func failure() -> SortError { .message("Local library: \(String(cString: sqlite3_errmsg(db)))") }
}

private final class SQLiteConnection: @unchecked Sendable {
    let value: OpaquePointer
    init(_ value: OpaquePointer) { self.value = value }
    deinit { sqlite3_close_v2(value) }
}
