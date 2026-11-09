import Foundation
import SQLite3

public struct IncomingMessage: Equatable {
    public let rowID: Int64
    public let text: String
    public let sender: String?
    public let date: Date
}

public struct MessageStoreError: Error, LocalizedError {
    public let code: Int32
    public let message: String
    public var errorDescription: String? { message }

    /// SQLITE_AUTH / SQLITE_CANTOPEN / SQLITE_PERM usually mean no Full Disk Access.
    public var isPermissionError: Bool {
        code == SQLITE_AUTH || code == SQLITE_CANTOPEN || code == SQLITE_PERM
    }
}

/// Read-only access to the Messages database. A new connection is opened
/// for every query. Queries only run when the folder changes, so this is cheap.
/// It also never holds a lock on Messages' files.
public final class MessageStore {
    public static let defaultPath = NSString(string: "~/Library/Messages/chat.db").expandingTildeInPath

    public let path: String

    public init(path: String = MessageStore.defaultPath) {
        self.path = path
    }

    public func maxRowID() throws -> Int64 {
        try withDB { db in
            let stmt = try prepare(db, "SELECT IFNULL(MAX(ROWID), 0) FROM message")
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw error(db) }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    /// Incoming messages (not sent by the user) with ROWID greater than `rowID`.
    public func messages(after rowID: Int64, limit: Int = 50) throws -> [IncomingMessage] {
        try withDB { db in
            let sql = """
                SELECT m.ROWID, m.text, m.attributedBody, m.date, h.id
                FROM message m
                LEFT JOIN handle h ON m.handle_id = h.ROWID
                WHERE m.ROWID > ? AND m.is_from_me = 0
                ORDER BY m.ROWID ASC
                LIMIT ?
                """
            let stmt = try prepare(db, sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, rowID)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var result: [IncomingMessage] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw error(db) }

                let id = sqlite3_column_int64(stmt, 0)
                var text = columnString(stmt, 1)
                if text?.isEmpty ?? true, let blob = columnData(stmt, 2) {
                    text = AttributedBodyDecoder.decode(blob)
                }
                guard let text, !text.isEmpty else { continue }
                result.append(IncomingMessage(
                    rowID: id,
                    text: text,
                    sender: columnString(stmt, 4),
                    date: Self.appleDate(sqlite3_column_int64(stmt, 3))
                ))
            }
            return result
        }
    }

    /// Messages stores dates as time since 2001-01-01. Older macOS uses seconds.
    /// Newer macOS uses nanoseconds.
    static func appleDate(_ raw: Int64) -> Date {
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    // MARK: - SQLite helpers

    private func withDB<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard rc == SQLITE_OK, let db else {
            throw MessageStoreError(code: rc, message: String(cString: sqlite3_errstr(rc)))
        }
        sqlite3_busy_timeout(db, 500)
        return try body(db)
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw error(db)
        }
        return stmt
    }

    private func error(_ db: OpaquePointer) -> MessageStoreError {
        MessageStoreError(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
    }

    private func columnString(_ stmt: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    private func columnData(_ stmt: OpaquePointer, _ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
}
