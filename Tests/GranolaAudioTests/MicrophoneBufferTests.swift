import AVFoundation
import Testing
@testable import GranolaAudio

@Suite struct MicrophoneBufferTests {
    @Test func firstChannelOfMultichannelBuffer() throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 5))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        for c in 0..<5 { for i in 0..<4 { buffer.floatChannelData![c][i] = Float(c * 10 + i) } }

        let mono = try #require(buffer.firstChannel())
        #expect(mono.format.channelCount == 1)
        #expect(mono.format.sampleRate == 48_000)
        #expect(mono.frameLength == 4)
        #expect((0..<4).map { mono.floatChannelData![0][$0] } == [0, 1, 2, 3])
    }

    @Test func monoBufferIsLeftAlone() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        #expect(buffer.firstChannel() == nil)
    }
}
