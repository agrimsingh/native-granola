import Foundation
import GranolaCore
import Testing
@testable import GranolaSpeech

@Suite struct PostMeetingProcessorTests {
    static func makeStore(ended: Bool = true) throws -> (Store, Meeting, [TranscriptSegment]) {
        let store = try Store.inMemory()
        let meeting = Meeting(id: "m1", title: "Sync", startedAt: Date(), endedAt: ended ? Date() : nil)
        try store.upsertMeeting(meeting)
        let segments = [
            TranscriptSegment(id: "a", meetingID: "m1", source: .system, text: "hello there", startOffset: 0, endOffset: 2),
            TranscriptSegment(id: "b", meetingID: "m1", source: .microphone, text: "hi", startOffset: 3, endOffset: 4),
        ]
        for s in segments { try store.upsertSegment(s) }
        return (store, meeting, segments)
    }

    static var emptyRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ng-speech-tests-\(UUID().uuidString)")
    }

    @Test func missingAudioKeepsLiveTranscript() async throws {
        let (store, _, segments) = try Self.makeStore()
        let processor = PostMeetingProcessor(
            store: store, options: .init(retranscribeWith: .v3, separateSpeakers: true, audioRoot: Self.emptyRoot))
        let outcome = try await processor.run(meetingID: "m1")
        #expect(outcome.retranscribed.isEmpty)
        #expect(outcome.speakerCount == 0)
        #expect(try store.segments(meetingID: "m1") == segments)
    }

    @Test func refusesMeetingsInProgress() async throws {
        let (store, _, _) = try Self.makeStore(ended: false)
        let processor = PostMeetingProcessor(store: store, options: .init(audioRoot: Self.emptyRoot))
        await #expect(throws: PostMeetingError.self) { try await processor.run(meetingID: "m1") }
        await #expect(throws: PostMeetingError.self) { try await processor.run(meetingID: "nope") }
    }

    @Test func dropsMicEchoesOfSystemAudio() {
        let segments = [
            TranscriptSegment(id: "s", meetingID: "m", source: .system, text: "we should move the launch to Thursday",
                              startOffset: 10, endOffset: 13),
            TranscriptSegment(id: "echo", meetingID: "m", source: .microphone, text: "move the launch to Thursday",
                              startOffset: 10.5, endOffset: 13.2),
            TranscriptSegment(id: "me", meetingID: "m", source: .microphone, text: "sounds good to me",
                              startOffset: 14, endOffset: 15),
        ]
        #expect(PostMeetingProcessor.removingEchoes(segments).map(\.id) == ["s", "me"])
    }
}
