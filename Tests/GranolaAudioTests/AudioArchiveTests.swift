import AVFAudio
import Foundation
import GranolaCore
import Testing
@testable import GranolaAudio

@Suite struct AudioArchiveWriterTests {
    func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("archive-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A 440 Hz tone at 48 kHz stereo, the kind of buffer a system tap delivers.
    func tone(seconds: Double, rate: Double = 48_000, channels: AVAudioChannelCount = 2) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(channels) {
            for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = 0.5 * sin(2 * .pi * 440 * Float(i) / Float(rate)) }
        }
        return buffer
    }

    func read(_ url: URL) throws -> (file: AVAudioFile, samples: [Float]) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        var samples: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        return (file, samples)
    }

    func rms(_ samples: ArraySlice<Float>) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
    }

    @Test func writesSixteenKilohertzMonoFloatAlignedToSessionTime() throws {
        let url = AudioArchive.url(meetingID: "m1", source: .system, root: tempDir())
        let writer = AudioArchiveWriter(url: url)
        writer.write(tone(seconds: 1), at: 0.5)
        writer.write(tone(seconds: 1), at: 3.0)
        writer.close()

        let (file, samples) = try read(url)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.fileFormat.commonFormat == .pcmFormatFloat32)
        #expect(abs(Double(samples.count) - 4.0 * 16_000) < 200)
        #expect(rms(samples[0..<7_000]) == 0)
        #expect(rms(samples[9_000..<23_000]) > 0.2)
        #expect(rms(samples[25_000..<47_000]) == 0)
        #expect(rms(samples[49_000..<63_000]) > 0.2)
    }

    @Test func contiguousBuffersArentPadded() throws {
        let url = tempDir().appendingPathComponent("mic.caf")
        let writer = AudioArchiveWriter(url: url)
        var offset = 0.0
        for _ in 0..<50 {
            let buffer = tone(seconds: 0.1, rate: 44_100, channels: 1)
            writer.write(buffer, at: offset)
            offset += 0.1
        }
        writer.close()
        let (_, samples) = try read(url)
        #expect(abs(Double(samples.count) - 5 * 16_000) < 200)
        #expect(samples[1_000..<79_000].filter { $0 == 0 }.count < 100)
    }

    @Test func padSilenceExtendsToTheMeetingEnd() throws {
        let url = tempDir().appendingPathComponent("system.caf")
        let writer = AudioArchiveWriter(url: url)
        writer.write(tone(seconds: 0.5), at: 0)
        writer.padSilence(through: 10)
        let written = writer.framesWritten
        writer.close()
        #expect(written == 160_000)
        #expect(try read(url).samples.count == 160_000)
    }

    @Test func nothingWrittenMeansNoFile() {
        let url = tempDir().appendingPathComponent("system.caf")
        let writer = AudioArchiveWriter(url: url)
        writer.padSilence(through: 10)
        writer.close()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite struct RecordingPolicyTests {
    @Test func resumesOnlyShortSleepsWithTheAppStillRunning() {
        #expect(RecordingPolicy.shouldResume(afterSleeping: 60, sourceAppRunning: true))
        #expect(!RecordingPolicy.shouldResume(afterSleeping: 60, sourceAppRunning: false))
        #expect(!RecordingPolicy.shouldResume(afterSleeping: 3 * 3600, sourceAppRunning: true))
    }

    @Test func recoveredMeetingsEndAtTheirLastWords() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let meeting = Meeting(title: "x", startedAt: start)
        let segments = [
            TranscriptSegment(meetingID: meeting.id, source: .system, text: "a", startOffset: 10, endOffset: 95),
            TranscriptSegment(meetingID: meeting.id, source: .microphone, text: "b", startOffset: 20, endOffset: 30),
        ]
        #expect(RecordingPolicy.recoveredEnd(of: meeting, segments: segments) == start.addingTimeInterval(95))
        #expect(RecordingPolicy.recoveredEnd(of: meeting, segments: []) == start)
    }

    @Test func pruneDeletesOnlyOldArchives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prune-\(UUID().uuidString)")
        let now = Date()
        func make(_ id: String, age days: Double) throws {
            let url = AudioArchive.url(meetingID: id, source: .system, root: root)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: url)
            let date = now.addingTimeInterval(-days * 86_400)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.deletingLastPathComponent().path)
        }
        try make("old", age: 10)
        try make("recent", age: 2)
        try make("active", age: 30)
        let deleted = AudioArchive.prune(olderThanDays: 7, root: root, now: now, keeping: ["active"])
        #expect(deleted == ["old"])
        #expect(!AudioArchive.hasAudio(meetingID: "old", root: root))
        #expect(AudioArchive.hasAudio(meetingID: "recent", root: root))
        #expect(AudioArchive.hasAudio(meetingID: "active", root: root))
        #expect(AudioArchive.prune(olderThanDays: 0, root: root, now: now).isEmpty)
    }
}
