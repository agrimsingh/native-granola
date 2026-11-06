import AVFAudio
import Foundation
import GranolaCore
import os

/// Converts buffers to a fixed format (resampling, downmixing), recreating the converter whenever the
/// input format changes, e.g. after a device switch. Not thread-safe.
final class BufferConverter {
    let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private let log = Logger(subsystem: "com.nativegranola", category: "converter")

    init(format: AVAudioFormat) {
        self.format = format
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.downmix = true
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            log.error("Audio conversion failed: \(String(describing: error))")
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }
}

extension AVAudioPCMBuffer {
    static func silence(format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        for b in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = b.mData { memset(data, 0, Int(b.mDataByteSize)) }
        }
        return buffer
    }
}

/// Writes one source's audio to its `AudioArchive` file as 16 kHz mono Float32. Each buffer goes at
/// its session offset and gaps are filled with silence, so a sample's position in the file is its
/// time since the meeting started. Not thread-safe; the file is created on the first write.
public final class AudioArchiveWriter {
    public static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioArchive.sampleRate,
                                             channels: 1, interleaved: false)!

    public let url: URL
    public private(set) var framesWritten: AVAudioFramePosition = 0
    private var file: AVAudioFile?
    private var failed = false
    private let converter = BufferConverter(format: AudioArchiveWriter.format)
    private let log = Logger(subsystem: "com.nativegranola", category: "archive")

    /// Offsets closer than this to the write position are treated as contiguous (converter rounding).
    private static let tolerance: AVAudioFramePosition = 160

    public init(url: URL) {
        self.url = url
    }

    public var duration: TimeInterval { Double(framesWritten) / AudioArchive.sampleRate }

    public func write(_ buffer: AVAudioPCMBuffer, at offset: TimeInterval) {
        guard !failed, let converted = converter.convert(buffer), let file = openIfNeeded() else { return }
        do {
            try pad(to: AVAudioFramePosition((max(0, offset) * AudioArchive.sampleRate).rounded()), file: file)
            try file.write(from: converted)
            framesWritten += AVAudioFramePosition(converted.frameLength)
        } catch {
            fail(error)
        }
    }

    /// Extends the file with silence up to `offset`, e.g. so it covers the whole meeting.
    public func padSilence(through offset: TimeInterval) {
        guard !failed, let file else { return }
        do { try pad(to: AVAudioFramePosition((offset * AudioArchive.sampleRate).rounded()), file: file) } catch { fail(error) }
    }

    public func close() {
        file?.close()
        file = nil
    }

    private func pad(to target: AVAudioFramePosition, file: AVAudioFile) throws {
        guard target - framesWritten > Self.tolerance else { return }
        let chunk = AVAudioFrameCount(AudioArchive.sampleRate)
        guard let silence = AVAudioPCMBuffer.silence(format: Self.format, frames: chunk) else { return }
        while framesWritten < target {
            silence.frameLength = AVAudioFrameCount(min(AVAudioFramePosition(chunk), target - framesWritten))
            try file.write(from: silence)
            framesWritten += AVAudioFramePosition(silence.frameLength)
        }
    }

    private func openIfNeeded() -> AVAudioFile? {
        if let file { return file }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: AudioArchive.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            self.file = file
            return file
        } catch {
            fail(error)
            return nil
        }
    }

    private func fail(_ error: Error) {
        log.error("Writing \(self.url.lastPathComponent, privacy: .public) failed: \(String(describing: error))")
        failed = true
        close()
    }
}
