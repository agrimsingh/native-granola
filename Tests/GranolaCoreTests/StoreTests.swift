import Foundation
import SQLite3
import Testing
@testable import GranolaCore

@Suite struct StoreTests {
    @Test func meetingRoundTrip() throws {
        let store = try Store.inMemory()
        let m = Meeting(title: "Weekly sync", attendees: [Attendee(name: "Sam", email: "sam@x.com")], rawNotes: "ship it")
        try store.upsertMeeting(m)
        let loaded = try #require(try store.meeting(id: m.id))
        #expect(loaded.title == "Weekly sync")
        #expect(loaded.attendees.first?.email == "sam@x.com")
        #expect(abs(loaded.startedAt.timeIntervalSince(m.startedAt)) < 0.001)
        #expect(loaded.endedAt == nil)
    }

    @Test func transcriptOrderingAndFormat() throws {
        let store = try Store.inMemory()
        let m = Meeting(title: "Call")
        try store.upsertMeeting(m)
        try store.upsertSegment(TranscriptSegment(meetingID: m.id, source: .system, text: "Hi there", startOffset: 5, endOffset: 6))
        try store.upsertSegment(TranscriptSegment(meetingID: m.id, source: .microphone, text: "Hello", startOffset: 1, endOffset: 2))
        #expect(try store.transcriptText(meetingID: m.id) == "[00:01] Me: Hello\n[00:05] Them: Hi there")
    }

    @Test func searchFindsTranscriptAndNotes() throws {
        let store = try Store.inMemory()
        let m = Meeting(title: "Pricing review", rawNotes: "discuss enterprise tier")
        try store.upsertMeeting(m)
        try store.upsertSegment(TranscriptSegment(meetingID: m.id, source: .system, text: "the roadmap for quarterly planning", startOffset: 30, endOffset: 33))
        let transcriptHits = try store.search("quarter")
        #expect(transcriptHits.contains { $0.kind == .transcript && $0.startOffset == 30 })
        let notesHits = try store.search("enterprise")
        #expect(notesHits.contains { $0.kind == .notes && $0.meetingID == m.id })
        #expect(try store.search("   ").isEmpty)
    }

    @Test func noteHitsDontCrowdOutTranscriptHits() throws {
        let store = try Store.inMemory()
        for i in 0..<5 {
            let m = Meeting(title: "Budget review \(i)")
            try store.upsertMeeting(m)
            try store.upsertSegment(TranscriptSegment(meetingID: m.id, source: .system, text: "the budget is tight",
                                                      startOffset: 1, endOffset: 2))
        }
        let hits = try store.search("budget", limit: 4)
        #expect(hits.count == 4)
        #expect(hits.contains { $0.kind == .transcript })
        #expect(hits.contains { $0.kind != .transcript })
    }

    @Test func updatingMeetingReplacesSearchIndex() throws {
        let store = try Store.inMemory()
        var m = Meeting(title: "Old title")
        try store.upsertMeeting(m)
        m.title = "New title"
        try store.upsertMeeting(m)
        #expect(try store.search("Old").isEmpty)
        #expect(try store.search("New").count == 1)
    }

    @Test func deleteCascades() throws {
        let store = try Store.inMemory()
        let m = Meeting(title: "Temp")
        try store.upsertMeeting(m)
        try store.upsertSegment(TranscriptSegment(meetingID: m.id, source: .system, text: "bye", startOffset: 0, endOffset: 1))
        try store.deleteMeeting(id: m.id)
        #expect(try store.meeting(id: m.id) == nil)
        #expect(try store.segments(meetingID: m.id).isEmpty)
        #expect(try store.search("bye").isEmpty)
    }

    @Test func speakersRoundTripAndShowInTranscript() throws {
        let store = try Store.inMemory()
        let m = Meeting(title: "Panel")
        try store.upsertMeeting(m)
        let a = TranscriptSegment(meetingID: m.id, source: .system, text: "first", startOffset: 0, endOffset: 1)
        let b = TranscriptSegment(meetingID: m.id, source: .system, text: "second", startOffset: 2, endOffset: 3)
        try store.upsertSegment(a)
        try store.upsertSegment(b)
        try store.setSpeakers([a.id: "Speaker 1", b.id: "Priya"], meetingID: m.id)
        #expect(try store.segments(meetingID: m.id).map(\.displaySpeaker) == ["Speaker 1", "Priya"])
        #expect(try store.transcriptText(meetingID: m.id).contains("Priya: second"))
        try store.setSpeakers([b.id: nil], meetingID: m.id)
        #expect(try store.segments(meetingID: m.id).last?.displaySpeaker == "Them")
    }

    @Test func replaceSegmentsSwapsTranscriptAndIndex() throws {
        let store = try Store.inMemory()
        let m = Meeting(title: "Redo")
        try store.upsertMeeting(m)
        try store.upsertSegment(TranscriptSegment(meetingID: m.id, source: .system, text: "garbled wurds", startOffset: 0, endOffset: 1))
        try store.replaceSegments(meetingID: m.id, with: [
            TranscriptSegment(meetingID: m.id, source: .system, text: "clean words", startOffset: 0, endOffset: 1, speaker: "Speaker 2"),
        ])
        #expect(try store.segments(meetingID: m.id).map(\.text) == ["clean words"])
        #expect(try store.search("wurds").isEmpty)
        #expect(try store.search("clean").count == 1)
    }

    @Test func unfinishedMeetingsAreThoseWithoutAnEnd() throws {
        let store = try Store.inMemory()
        var done = Meeting(title: "Done")
        done.endedAt = Date()
        let open = Meeting(title: "Open")
        try store.upsertMeeting(done)
        try store.upsertMeeting(open)
        #expect(try store.unfinishedMeetings().map(\.id) == [open.id])
    }

    @Test func migratesOldDatabaseWithoutSpeakerColumn() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("old-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, """
            CREATE TABLE segments (id TEXT PRIMARY KEY, meeting_id TEXT NOT NULL, source TEXT NOT NULL,
                text TEXT NOT NULL, start_offset REAL NOT NULL, end_offset REAL NOT NULL);
            """, nil, nil, nil)
        sqlite3_close(db)

        let store = try Store(url: url)
        let m = Meeting(title: "Old")
        try store.upsertMeeting(m)
        try store.upsertSegment(TranscriptSegment(meetingID: m.id, source: .microphone, text: "hi", startOffset: 0, endOffset: 1, speaker: "Me"))
        #expect(try store.segments(meetingID: m.id).first?.speaker == "Me")
    }
}
