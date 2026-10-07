import Foundation
import SQLite3
import XrashReport

/// Disposable, app-owned metadata. Paths are the identity: reports are assumed
/// immutable, so neither content fingerprints nor a second file identity is kept.
public actor ReportMetadataCache {
    /// The wrapper distinguishes a successful read with no IPS header from a miss.
    public struct Header: Codable, Sendable {
        public var value: ReportHeader?

        public init(_ value: ReportHeader?) {
            self.value = value
        }
    }

    public struct Entry: Sendable {
        public var header: Header?
        /// Nil is unparsed; an empty string is a successful parse with no reason.
        public var reason: String?
    }

    // Bump only when the stored representation or parsing semantics change.
    private static let version = 1
    private static let retention: TimeInterval = 30 * 24 * 60 * 60
    private static let cleanupInterval: TimeInterval = 24 * 60 * 60
    private let url: URL
    private var database: OpaquePointer?
    private var disabled = false
    private var rebuilt = false

    public init(url: URL) {
        self.url = url
    }

    deinit { sqlite3_close(database) }

    public func load(_ paths: [String]) -> [String: Entry] {
        access(fallback: [:]) {
            let statement = try prepare("SELECT header, reason FROM reports WHERE path = ?")
            defer { sqlite3_finalize(statement) }
            var result = [String: Entry]()
            for path in paths {
                sqlite3_reset(statement)
                try bind(path, to: statement)
                guard try step(statement) == SQLITE_ROW else { continue }
                var header: Header?
                if let bytes = sqlite3_column_blob(statement, 0) {
                    let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
                    header = try? PropertyListDecoder().decode(Header.self, from: data)
                }
                let reason = sqlite3_column_text(statement, 1).map {
                    String(decoding: UnsafeBufferPointer(start: $0, count: Int(sqlite3_column_bytes(statement, 1))), as: UTF8.self)
                }
                result[path] = Entry(header: header, reason: reason)
            }
            return result
        }
    }

    /// One transaction for a completed refresh. Touch current paths before
    /// expiring absent ones, including on the first launch after a long absence.
    public func saveRefresh(
        paths: [String], headers: [String: Header], allowCleanup: Bool, now: Date = Date()
    ) {
        access(fallback: ()) {
            try transaction {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let insert = try prepare("""
                INSERT INTO reports(path, header, last_seen) VALUES (?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET header = excluded.header
                """)
                defer { sqlite3_finalize(insert) }
                for (path, header) in headers {
                    sqlite3_reset(insert)
                    try bind(path, to: insert)
                    let data = try encoder.encode(header)
                    try data.withUnsafeBytes {
                        try check(sqlite3_bind_blob64(insert, 2, $0.baseAddress, UInt64($0.count), transient))
                    }
                    try check(sqlite3_bind_double(insert, 3, now.timeIntervalSince1970))
                    _ = try step(insert)
                }

                let touch = try prepare("UPDATE reports SET last_seen = ? WHERE path = ?")
                defer { sqlite3_finalize(touch) }
                for path in paths {
                    sqlite3_reset(touch)
                    try check(sqlite3_bind_double(touch, 1, now.timeIntervalSince1970))
                    try bind(path, to: touch, index: 2)
                    _ = try step(touch)
                }

                guard allowCleanup else { return }
                let lastCleanup = try scalar("SELECT last_cleanup FROM maintenance")
                guard now.timeIntervalSince1970 - lastCleanup >= Self.cleanupInterval else { return }
                let prune = try prepare("DELETE FROM reports WHERE last_seen < ?")
                defer { sqlite3_finalize(prune) }
                try check(sqlite3_bind_double(prune, 1, now.timeIntervalSince1970 - Self.retention))
                _ = try step(prune)
                let mark = try prepare("UPDATE maintenance SET last_cleanup = ?")
                defer { sqlite3_finalize(mark) }
                try check(sqlite3_bind_double(mark, 1, now.timeIntervalSince1970))
                _ = try step(mark)
            }
        }
    }

    public func saveReasons(_ reasons: [String: String], now: Date = Date()) {
        guard !reasons.isEmpty else { return }
        access(fallback: ()) {
            try transaction {
                let statement = try prepare("""
                INSERT INTO reports(path, reason, last_seen) VALUES (?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET reason = excluded.reason
                """)
                defer { sqlite3_finalize(statement) }
                for (path, reason) in reasons {
                    sqlite3_reset(statement)
                    try bind(path, to: statement)
                    try bind(reason, to: statement, index: 2)
                    try check(sqlite3_bind_double(statement, 3, now.timeIntervalSince1970))
                    _ = try step(statement)
                }
            }
        }
    }

    public func remove(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        access(fallback: ()) {
            try transaction {
                let statement = try prepare("DELETE FROM reports WHERE path = ?")
                defer { sqlite3_finalize(statement) }
                for path in paths {
                    sqlite3_reset(statement)
                    try bind(path, to: statement)
                    _ = try step(statement)
                }
            }
        }
    }

    // MARK: SQLite

    private struct Failure: Error { var code: Int32 }
    private var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private func access<Value>(fallback: Value, _ body: () throws -> Value) -> Value {
        guard !disabled else { return fallback }
        do {
            try open()
            return try body()
        } catch {
            sqlite3_close(database)
            database = nil
            let code = (error as? Failure)?.code
            if !rebuilt, code == SQLITE_CORRUPT || code == SQLITE_NOTADB {
                rebuilt = true
                do {
                    try FileManager.default.removeItem(at: url)
                    // A rollback journal can remain after an interrupted write.
                    try? FileManager.default.removeItem(atPath: url.path + "-journal")
                    try open()
                    return try body()
                } catch {}
            }
            // A cache failure must never prevent reading the actual report.
            sqlite3_close(database)
            database = nil
            disabled = true
            return fallback
        }
    }

    private func open() throws {
        guard database == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try check(sqlite3_open(url.path, &database))
        try execute("PRAGMA auto_vacuum = FULL")
        if try scalar("PRAGMA user_version") != Double(Self.version) {
            try transaction {
                try execute("DROP TABLE IF EXISTS reports; DROP TABLE IF EXISTS maintenance")
                try execute("""
                CREATE TABLE reports(path TEXT PRIMARY KEY, header BLOB, reason TEXT, last_seen REAL NOT NULL);
                CREATE TABLE maintenance(last_cleanup REAL NOT NULL);
                INSERT INTO maintenance VALUES (0);
                PRAGMA user_version = \(Self.version);
                """)
            }
        }
    }

    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else { throw Failure(code: code) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(database, sql, -1, &statement, nil))
        return statement!
    }

    private func bind(_ text: String, to statement: OpaquePointer, index: Int32 = 1) throws {
        try check(sqlite3_bind_text64(statement, index, text, UInt64(text.utf8.count), transient, UInt8(SQLITE_UTF8)))
    }

    private func step(_ statement: OpaquePointer) throws -> Int32 {
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW || code == SQLITE_DONE else { throw Failure(code: code) }
        return code
    }

    private func scalar(_ sql: String) throws -> Double {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        _ = try step(statement)
        return sqlite3_column_double(statement, 0)
    }

    private func execute(_ sql: String) throws {
        try check(sqlite3_exec(database, sql, nil, nil, nil))
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
