import AVFAudio
import Foundation
import GranolaCore

/// One source's path from capture to the transcriber and the audio archive. Buffers leave the
/// capture thread straight away and are processed on a serial queue. The pipeline lives for the
/// whole recording session, across capture restarts and sleep, so offsets never reset and each
/// source keeps writing to a single file.
final class SourcePipeline: @unchecked Sendable {
    let source: TranscriptSource
    private let sessionStart: Date
    private let queue: DispatchQueue
    private let onLevel: @Sendable (Float) -> Void
    private var timeline = SourceTimeline()
    private var transcriber: LiveTranscriber?
    private let archive: AudioArchiveWriter?
    private var lastLevelAt: TimeInterval = -1

    init(source: TranscriptSource, sessionStart: Date, archiveURL: URL?, onLevel: @escaping @Sendable (Float) -> Void) {
        self.source = source
        self.sessionStart = sessionStart
        self.onLevel = onLevel
        archive = archiveURL.map(AudioArchiveWriter.init)
        queue = DispatchQueue(label: "com.nativegranola.pipeline.\(source.rawValue)", qos: .userInitiated)
    }

    var handler: @Sendable (AVAudioPCMBuffer) -> Void {
        { [self] buffer in ingest(buffer) }
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        let arrival = Date().timeIntervalSince(sessionStart)
        queue.async { self.process(buffer, arrival: arrival) }
    }

    func setTranscriber(_ transcriber: LiveTranscriber?) {
        queue.sync { self.transcriber = transcriber }
    }

    /// Waits until every buffer handed in so far has been processed.
    func drain() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { done.resume() }
        }
    }

    /// Pads the archive with silence through `end` and closes it.
    func close(at end: TimeInterval) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.archive?.padSilence(through: end)
                self.archive?.close()
                done.resume()
            }
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer, arrival: TimeInterval) {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let placement = timeline.place(duration: duration, arrivedAt: arrival)
        transcriber?.append(buffer, at: placement.start)
        archive?.write(buffer, at: placement.start)
        if arrival - lastLevelAt >= 0.1 {
            lastLevelAt = arrival
            onLevel(buffer.rmsLevel)
        }
    }
}
