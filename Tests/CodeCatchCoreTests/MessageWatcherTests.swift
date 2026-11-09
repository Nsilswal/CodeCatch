import SQLite3
import XCTest
@testable import CodeCatchCore

/// Builds a minimal fake chat.db and checks the full read → extract → callback path.
final class MessageWatcherTests: XCTestCase {
    private var path: String!
    private var db: OpaquePointer?

    override func setUp() {
        path = NSTemporaryDirectory() + "codecatch-\(UUID().uuidString)/chat.db"
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        exec("""
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, attributedBody BLOB,
                                  date INTEGER, handle_id INTEGER, is_from_me INTEGER);
            INSERT INTO handle VALUES (1, '22395');
            INSERT INTO message (text, date, handle_id, is_from_me)
                VALUES ('Old code 111111', \(now()), 1, 0);
            """)
    }

    override func tearDown() {
        sqlite3_close(db)
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    private func exec(_ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }

    private func now(offset: TimeInterval = 0) -> Int64 {
        Int64((Date().timeIntervalSinceReferenceDate + offset) * 1_000_000_000)
    }

    func testCopiesOnlyNewIncomingRecentCodes() {
        let watcher = MessageWatcher(store: MessageStore(path: path))
        var got: [(String, String?)] = []
        watcher.onCode = { code, m in got.append((code, m.sender)) }

        watcher.start()
        XCTAssertEqual(watcher.state, .watching)
        XCTAssertTrue(got.isEmpty, "existing messages must not be copied on start")

        exec("""
            INSERT INTO message (text, date, handle_id, is_from_me) VALUES ('My code is 222222', \(now()), 1, 1);
            INSERT INTO message (text, date, handle_id, is_from_me) VALUES ('Stale code 333333', \(now(offset: -3600)), 1, 0);
            INSERT INTO message (text, date, handle_id, is_from_me) VALUES ('Your verification code is 444444', \(now()), 1, 0);
            """)
        watcher.check()
        XCTAssertEqual(got.map(\.0), ["444444"])
        XCTAssertEqual(got.first?.1, "22395")

        watcher.check()
        XCTAssertEqual(got.count, 1, "same message must not fire twice")
        watcher.stop()
        XCTAssertEqual(watcher.state, .stopped)
    }

    func testMissingDatabaseReportsError() {
        let watcher = MessageWatcher(store: MessageStore(path: "/nonexistent/chat.db"))
        watcher.start()
        if case .noAccess = watcher.state {} else { XCTFail("got \(watcher.state)") }
        watcher.stop()
    }
}
