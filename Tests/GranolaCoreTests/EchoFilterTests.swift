import Testing
@testable import GranolaCore

@Suite struct EchoFilterTests {
    func seg(_ source: TranscriptSource, _ text: String, _ start: Double) -> TranscriptSegment {
        TranscriptSegment(meetingID: "m", source: source, text: text, startOffset: start, endOffset: start + 3)
    }

    @Test func overlappingSimilarTextIsEcho() {
        #expect(EchoFilter.isEcho(mic: seg(.microphone, "we should ship the pricing page friday", 10.5),
                                  system: seg(.system, "We should ship the pricing page on Friday.", 10)))
    }

    @Test func differentTextIsNotEcho() {
        #expect(!EchoFilter.isEcho(mic: seg(.microphone, "sounds good to me, let's do it", 10),
                                   system: seg(.system, "we should ship the pricing page friday", 10)))
    }

    @Test func farApartInTimeIsNotEcho() {
        #expect(!EchoFilter.isEcho(mic: seg(.microphone, "we should ship the pricing page friday", 60),
                                   system: seg(.system, "we should ship the pricing page friday", 10)))
    }

    @Test func shortUtterancesAreKept() {
        #expect(!EchoFilter.isEcho(mic: seg(.microphone, "yes okay", 10), system: seg(.system, "yes okay", 10)))
    }

    @Test func deleteSegmentRemovesFromSearch() throws {
        let store = try Store.inMemory()
        let m = Meeting(title: "x")
        try store.upsertMeeting(m)
        let s = seg(.microphone, "unique echo words here", 1)
        var stored = s
        stored.meetingID = m.id
        try store.upsertSegment(stored)
        try store.deleteSegment(id: stored.id, meetingID: m.id)
        #expect(try store.segments(meetingID: m.id).isEmpty)
        #expect(try store.search("unique").isEmpty)
    }
}
