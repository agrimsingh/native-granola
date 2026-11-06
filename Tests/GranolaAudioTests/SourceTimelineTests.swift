import Testing
@testable import GranolaAudio

@Suite struct SourceTimelineTests {
    @Test func firstBufferStartsAtItsCaptureTime() {
        var timeline = SourceTimeline()
        let p = timeline.place(duration: 0.1, arrivedAt: 2.1)
        #expect(abs(p.start - 2.0) < 1e-9)
        #expect(abs(p.gap - 2.0) < 1e-9)
    }

    @Test func contiguousBuffersIgnoreDeliveryJitter() {
        var timeline = SourceTimeline()
        _ = timeline.place(duration: 0.1, arrivedAt: 1.1)
        let jittered = [1.23, 1.29, 1.42, 1.5]
        var expected = 1.1
        for arrival in jittered {
            let p = timeline.place(duration: 0.1, arrivedAt: arrival)
            #expect(abs(p.start - expected) < 1e-9)
            #expect(abs(p.gap) < 1e-9)
            expected += 0.1
        }
    }

    @Test func restartAfterAPauseLeavesAGap() {
        var timeline = SourceTimeline()
        _ = timeline.place(duration: 1, arrivedAt: 1)
        _ = timeline.place(duration: 1, arrivedAt: 2)
        let p = timeline.place(duration: 0.1, arrivedAt: 602.1)
        #expect(abs(p.start - 602) < 1e-9)
        #expect(abs(p.gap - 600) < 1e-9)
        let next = timeline.place(duration: 0.1, arrivedAt: 602.25)
        #expect(abs(next.start - 602.1) < 1e-9)
    }

    @Test func droppedAudioIsResyncedOnceItExceedsTheThreshold() {
        var timeline = SourceTimeline(gapThreshold: 0.5)
        _ = timeline.place(duration: 0.1, arrivedAt: 0.1)
        #expect(timeline.place(duration: 0.1, arrivedAt: 0.6).gap == 0)
        let p = timeline.place(duration: 0.1, arrivedAt: 1.0)
        #expect(abs(p.start - 0.9) < 1e-9)
    }

    @Test func offsetsAreNeverNegative() {
        var timeline = SourceTimeline()
        #expect(timeline.place(duration: 0.5, arrivedAt: 0.2).start == 0)
    }
}
