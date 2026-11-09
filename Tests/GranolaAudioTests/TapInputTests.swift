import AVFoundation
import Testing
@testable import GranolaAudio

@Suite struct TapInputTests {
    private let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    /// Builds what an IOProc receives: one buffer per input stream, each holding interleaved Float32
    /// samples that count up from `first`.
    private func withInput<T>(_ streams: [(channels: UInt32, frames: Int, first: Float)],
                              _ body: (UnsafePointer<AudioBufferList>) throws -> T) rethrows -> T {
        let list = AudioBufferList.allocate(maximumBuffers: max(streams.count, 1))
        list.count = streams.count
        defer {
            list.forEach { $0.mData?.deallocate() }
            free(list.unsafeMutablePointer)
        }
        for (i, stream) in streams.enumerated() {
            let count = stream.frames * Int(stream.channels)
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: max(count, 1))
            for n in 0..<count { samples[n] = stream.first + Float(n) }
            list[i] = AudioBuffer(mNumberChannels: stream.channels, mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                                  mData: UnsafeMutableRawPointer(samples))
        }
        return try body(list.unsafePointer)
    }

    private func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    @Test func copiesTheOnlyBuffer() throws {
        try withInput([(channels: 1, frames: 4, first: 100)]) { input in
            let copy = try #require(TapInput.copy(from: input, format: mono))
            #expect(copy.format == mono)
            #expect(samples(copy) == [100, 101, 102, 103])
        }
    }

    /// With voice processing on, the output device's own input stream comes before the tap's.
    @Test func takesTheTapBehindTheOutputDevicesInputStream() throws {
        try withInput([(channels: 2, frames: 4, first: 0), (channels: 1, frames: 4, first: 100)]) { input in
            let copy = try #require(TapInput.copy(from: input, format: mono))
            #expect(samples(copy) == [100, 101, 102, 103])
        }
        try withInput([(channels: 6, frames: 3, first: 0), (channels: 1, frames: 3, first: 50)]) { input in
            let copy = try #require(TapInput.copy(from: input, format: mono))
            #expect(samples(copy) == [50, 51, 52])
        }
    }

    @Test func copyOutlivesTheCallbackMemory() throws {
        let copy = try withInput([(channels: 2, frames: 2, first: 0), (channels: 1, frames: 2, first: 7)]) { input in
            try #require(TapInput.copy(from: input, format: mono))
        }
        #expect(samples(copy) == [7, 8])
    }

    @Test func rejectsATrailingBufferThatIsNotTheTapsShape() {
        withInput([(channels: 1, frames: 4, first: 100), (channels: 2, frames: 4, first: 0)]) { input in
            #expect(TapInput.copy(from: input, format: mono) == nil)
        }
    }

    @Test func emptyInputIsNotAudio() {
        withInput([(channels: 1, frames: 0, first: 0)]) { input in
            #expect(TapInput.copy(from: input, format: mono) == nil)
        }
        withInput([]) { input in
            #expect(TapInput.copy(from: input, format: mono) == nil)
        }
    }

    @Test func interleavedStereoTapIsOneBuffer() throws {
        let stereo = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        try withInput([(channels: 6, frames: 2, first: 0), (channels: 2, frames: 2, first: 10)]) { input in
            let copy = try #require(TapInput.copy(from: input, format: stereo))
            #expect(copy.frameLength == 2)
            let data = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)[0].mData!
                .assumingMemoryBound(to: Float.self)
            #expect((0..<4).map { data[$0] } == [10, 11, 12, 13])
        }
    }
}
