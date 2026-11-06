import Foundation
import SQLite3

public enum StoreError: Error, CustomStringConvertible {
    case sqlite(code: Int32, message: String)

    public var description: String {
        switch self {
        case let .sqlite(code, message): "SQLite error \(code): \(message)"
        }
    }
}

/// SQLite-backed storage for meetings and transcripts. Safe to use from any thread, and from
/// several processes at once (the app writes while the MCP server process reads).
public final class Store: @unchecked Sendable {
    public static let didChangeNotification = Notification.Name("GranolaStoreDidChange")

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NativeGranola", isDirectory: true)
            .appendingPathComponent("granola.sqlite")
    }

    private var db: OpaquePointer?
    private let lock = NSLock()

    public convenience init(url: URL = Store.defaultURL, readOnly: Bool = false) throws {
        if !readOnly {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try self.init(path: url.path, readOnly: readOnly)
    }

    /// In-memory store, for tests.
    public static func inMemory() throws -> Store {
        try Store(path: ":memory:", readOnly: false)
    }

    private init(path: String, readOnly: Bool) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw StoreError.sqlite(code: rc, message: message)
        }
        sqlite3_busy_timeout(db, 5000)
        if !readOnly { try migrate() }
    }

    deinit { sqlite3_close(db) }

    // MARK: Schema

    private func migrate() throws {
        try exec("""
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS meetings (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL,
                calendar_event_id TEXT,
                attendees_json TEXT NOT NULL DEFAULT '[]',
                source_app TEXT,
                raw_notes TEXT NOT NULL DEFAULT '',
                enhanced_notes TEXT,
                template_id TEXT,
                folder TEXT,
                notion_page_url TEXT,
                updated_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS meetings_started_at ON meetings(started_at DESC);
            CREATE TABLE IF NOT EXISTS segments (
                id TEXT PRIMARY KEY,
                meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                source TEXT NOT NULL,
                text TEXT NOT NULL,
                start_offset REAL NOT NULL,
                end_offset REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS segments_meeting ON segments(meeting_id, start_offset);
            CREATE VIRTUAL TABLE IF NOT EXISTS meetings_fts USING fts5(
                meeting_id UNINDEXED, title, raw_notes, enhanced_notes, tokenize = 'porter unicode61'
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts USING fts5(
                segment_id UNINDEXED, meeting_id UNINDEXED, text, tokenize = 'porter unicode61'
            );
            """)
        if try !columns(of: "segments").contains("speaker") {
            try exec("ALTER TABLE segments ADD COLUMN speaker TEXT")
        }
    }

    private func columns(of table: String) throws -> Set<String> {
        Set(try query("PRAGMA table_info(\(table))") { $0.string(1) ?? "" })
    }

    // MARK: Meetings

    public func upsertMeeting(_ m: Meeting) throws {
        try locked {
            let attendees = String(decoding: try JSONEncoder().encode(m.attendees), as: UTF8.self)
            try run("""
                INSERT INTO meetings (id, title, started_at, ended_at, calendar_event_id, attendees_json,
                    source_app, raw_notes, enhanced_notes, template_id, folder, notion_page_url, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                    title=excluded.title, started_at=excluded.started_at, ended_at=excluded.ended_at,
                    calendar_event_id=excluded.calendar_event_id, attendees_json=excluded.attendees_json,
                    source_app=excluded.source_app, raw_notes=excluded.raw_notes,
                    enhanced_notes=excluded.enhanced_notes, template_id=excluded.template_id,
                    folder=excluded.folder, notion_page_url=excluded.notion_page_url,
                    updated_at=excluded.updated_at
                """,
                m.id, m.title, m.startedAt, m.endedAt, m.calendarEventID, attendees, m.sourceApp,
                m.rawNotes, m.enhancedNotes, m.templateID, m.folder, m.notionPageURL, Date())
            try run("DELETE FROM meetings_fts WHERE meeting_id = ?", m.id)
            try run("INSERT INTO meetings_fts (meeting_id, title, raw_notes, enhanced_notes) VALUES (?,?,?,?)",
                    m.id, m.title, m.rawNotes, m.enhancedNotes ?? "")
        }
        notify(m.id)
    }

    public func meeting(id: String) throws -> Meeting? {
        try locked { try query("SELECT \(Self.meetingColumns) FROM meetings WHERE id = ?", id, map: Self.meeting).first }
    }

    /// Most recent first. `since`/`until` filter on the meeting start time.
    public func listMeetings(limit: Int = 50, offset: Int = 0, since: Date? = nil, until: Date? = nil) throws -> [Meeting] {
        try locked {
            try query("""
                SELECT \(Self.meetingColumns) FROM meetings
                WHERE started_at >= ? AND started_at <= ?
                ORDER BY started_at DESC LIMIT ? OFFSET ?
                """,
                since ?? Date.distantPast, until ?? Date.distantFuture, limit, offset, map: Self.meeting)
        }
    }

    /// Meetings that were never ended, e.g. because the app crashed or was killed mid-recording.
    public func unfinishedMeetings() throws -> [Meeting] {
        try locked {
            try query("SELECT \(Self.meetingColumns) FROM meetings WHERE ended_at IS NULL ORDER BY started_at DESC",
                      map: Self.meeting)
        }
    }

    public func deleteMeeting(id: String) throws {
        try locked {
            try run("DELETE FROM segments_fts WHERE meeting_id = ?", id)
            try run("DELETE FROM meetings_fts WHERE meeting_id = ?", id)
            try run("DELETE FROM segments WHERE meeting_id = ?", id)
            try run("DELETE FROM meetings WHERE id = ?", id)
        }
        notify(id)
    }

    // MARK: Transcript

    /// Insert or replace a finalized transcript segment.
    public func upsertSegment(_ s: TranscriptSegment) throws {
        try locked { try writeSegment(s) }
        notify(s.meetingID)
    }

    /// Swap a meeting's whole transcript in one transaction, e.g. after re-transcribing the saved audio.
    public func replaceSegments(meetingID: String, with segments: [TranscriptSegment]) throws {
        try locked {
            try exec("BEGIN IMMEDIATE")
            do {
                try run("DELETE FROM segments_fts WHERE meeting_id = ?", meetingID)
                try run("DELETE FROM segments WHERE meeting_id = ?", meetingID)
                for s in segments { try writeSegment(s) }
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
        notify(meetingID)
    }

    /// Set speaker labels by segment id. Pass nil to clear a label.
    public func setSpeakers(_ speakers: [String: String?], meetingID: String) throws {
        try locked {
            try exec("BEGIN IMMEDIATE")
            do {
                for (id, speaker) in speakers {
                    try run("UPDATE segments SET speaker = ? WHERE id = ? AND meeting_id = ?", speaker, id, meetingID)
                }
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
        notify(meetingID)
    }

    private func writeSegment(_ s: TranscriptSegment) throws {
        try run("""
            INSERT INTO segments (id, meeting_id, source, text, start_offset, end_offset, speaker) VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET text=excluded.text, start_offset=excluded.start_offset,
                end_offset=excluded.end_offset, speaker=excluded.speaker
            """, s.id, s.meetingID, s.source.rawValue, s.text, s.startOffset, s.endOffset, s.speaker)
        try run("DELETE FROM segments_fts WHERE segment_id = ?", s.id)
        try run("INSERT INTO segments_fts (segment_id, meeting_id, text) VALUES (?,?,?)", s.id, s.meetingID, s.text)
    }

    public func deleteSegment(id: String, meetingID: String) throws {
        try locked {
            try run("DELETE FROM segments_fts WHERE segment_id = ?", id)
            try run("DELETE FROM segments WHERE id = ?", id)
        }
        notify(meetingID)
    }

    public func segments(meetingID: String) throws -> [TranscriptSegment] {
        try locked {
            // A read-only store (the MCP server) may open a database the app hasn't migrated yet.
            let speaker = try columns(of: "segments").contains("speaker") ? "speaker" : "NULL"
            return try query("""
                SELECT id, meeting_id, source, text, start_offset, end_offset, \(speaker) FROM segments
                WHERE meeting_id = ? ORDER BY start_offset
                """, meetingID) { row in
                TranscriptSegment(
                    id: row.string(0)!, meetingID: row.string(1)!,
                    source: TranscriptSource(rawValue: row.string(2)!) ?? .system,
                    text: row.string(3)!, startOffset: row.double(4), endOffset: row.double(5),
                    speaker: row.string(6))
            }
        }
    }

    public func transcriptText(meetingID: String) throws -> String {
        Transcript.format(try segments(meetingID: meetingID))
    }

    // MARK: Search

    /// Full-text search across titles, notes and transcripts. Words are ANDed; the last word is a prefix match.
    public func search(_ text: String, limit: Int = 20) throws -> [SearchHit] {
        guard let match = Self.ftsQuery(text) else { return [] }
        return try locked {
            let notes = try query("""
                SELECT f.meeting_id, m.title, m.started_at,
                    snippet(meetings_fts, 1, '**', '**', '…', 12),
                    snippet(meetings_fts, 2, '**', '**', '…', 24),
                    snippet(meetings_fts, 3, '**', '**', '…', 24)
                FROM meetings_fts f JOIN meetings m ON m.id = f.meeting_id
                WHERE meetings_fts MATCH ? ORDER BY bm25(meetings_fts) LIMIT ?
                """, match, limit) { row -> SearchHit in
                let title = row.string(3) ?? "", notes = row.string(4) ?? "", enhanced = row.string(5) ?? ""
                let (kind, snippet): (SearchHit.Kind, String) =
                    enhanced.contains("**") ? (.enhancedNotes, enhanced)
                    : notes.contains("**") ? (.notes, notes) : (.title, title)
                return SearchHit(meetingID: row.string(0)!, meetingTitle: row.string(1)!,
                                 meetingStartedAt: row.date(2)!, kind: kind, snippet: snippet)
            }
            let transcript = try query("""
                SELECT f.meeting_id, m.title, m.started_at, snippet(segments_fts, 2, '**', '**', '…', 24),
                    s.start_offset
                FROM segments_fts f JOIN meetings m ON m.id = f.meeting_id JOIN segments s ON s.id = f.segment_id
                WHERE segments_fts MATCH ? ORDER BY bm25(segments_fts) LIMIT ?
                """, match, limit) { row in
                SearchHit(meetingID: row.string(0)!, meetingTitle: row.string(1)!, meetingStartedAt: row.date(2)!,
                          kind: .transcript, snippet: row.string(3) ?? "", startOffset: row.double(4))
            }
            let noteShare = min(notes.count, max(1, limit / 2))
            return Array(notes.prefix(noteShare)) + Array(transcript.prefix(limit - noteShare))
        }
    }

    static func ftsQuery(_ text: String) -> String? {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return nil }
        return words.enumerated().map { i, w in
            i == words.count - 1 ? "\"\(w)\"*" : "\"\(w)\""
        }.joined(separator: " ")
    }

    // MARK: Row mapping

    private static let meetingColumns = """
        id, title, started_at, ended_at, calendar_event_id, attendees_json, source_app, raw_notes,
        enhanced_notes, template_id, folder, notion_page_url
        """

    private static func meeting(_ row: Row) -> Meeting {
        let attendees = row.string(5).flatMap { try? JSONDecoder().decode([Attendee].self, from: Data($0.utf8)) } ?? []
        return Meeting(
            id: row.string(0)!, title: row.string(1)!, startedAt: row.date(2)!, endedAt: row.date(3),
            calendarEventID: row.string(4), attendees: attendees, sourceApp: row.string(6),
            rawNotes: row.string(7) ?? "", enhancedNotes: row.string(8), templateID: row.string(9),
            folder: row.string(10), notionPageURL: row.string(11))
    }

    // MARK: SQLite plumbing

    private func notify(_ meetingID: String) {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: ["meetingID": meetingID])
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func error(_ rc: Int32) -> StoreError {
        .sqlite(code: rc, message: String(cString: sqlite3_errmsg(db)))
    }

    private func exec(_ sql: String) throws {
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, transient)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Date: sqlite3_bind_double(stmt, idx, v.timeIntervalSince1970)
            default: sqlite3_bind_text(stmt, idx, String(describing: arg!), -1, transient)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ args: Any?...) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc) }
    }

    private func query<T>(_ sql: String, _ args: Any?..., map: (Row) throws -> T) throws -> [T] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc) }
            out.append(try map(Row(stmt: stmt)))
        }
        return out
    }

    struct Row {
        let stmt: OpaquePointer?
        func string(_ i: Int32) -> String? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, i))
        }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func date(_ i: Int32) -> Date? {
            sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: double(i))
        }
    }
}
