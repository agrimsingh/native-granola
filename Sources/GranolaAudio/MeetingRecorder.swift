import AVFAudio
import Foundation
import GranolaCore
import Observation
import os

/// Runs a recording session: captures mic + system audio as two separate streams, transcribes
/// each on-device, and persists finalized segments to the store as they arrive.
@MainActor @Observable
public final class MeetingRecorder {
    public enum State: Equatable {
        case idle, preparing, recording, stopping
        case failed(String)
    }

    public struct Options: Sendable {
        public var captureMicrophone = true
        public var captureSystemAudio = true
        public var echoCancellation = true
        public var locale: Locale = .current
        public init() {}
    }

    public private(set) var state: State = .idle
    public private(set) var meeting: Meeting?
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var volatileText: [TranscriptSource: String] = [:]
    public private(set) var levels: [TranscriptSource: Float] = [:]
    public private(set) var warnings: [String] = []

    public var isRecording: Bool { state == .recording }

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let log = Logger(subsystem: "com.nativegranola", category: "recorder")
    @ObservationIgnored private var system: SystemAudioCapture?
    @ObservationIgnored private var mic: MicrophoneCapture?
    @ObservationIgnored private var transcribers: [TranscriptSource: LiveTranscriber] = [:]
    @ObservationIgnored private var lastLevelPublish: [TranscriptSource: Date] = [:]

    public init(store: Store) {
        self.store = store
    }

    /// Starts recording into `meeting` (persisted immediately). `vocabulary` biases recognition
    /// toward names and terms, e.g. attendee names.
    public func start(_ meeting: Meeting, options: Options = Options(), vocabulary: [String] = []) async {
        guard state == .idle || isFailed else { return }
        state = .preparing
        warnings = []
        segments = []
        volatileText = [:]
        var meeting = meeting
        meeting.endedAt = nil
        self.meeting = meeting
        do {
            try store.upsertMeeting(meeting)
            let locale = try await LiveTranscriber.prepare(locale: options.locale)
            let sessionStart = meeting.startedAt

            if options.captureMicrophone {
                if await MicrophoneCapture.requestPermission() {
                    try await startSource(.microphone, locale: locale, sessionStart: sessionStart, vocabulary: vocabulary)
                    let capture = MicrophoneCapture(voiceProcessing: options.echoCancellation)
                    try capture.start(handler: handler(for: .microphone))
                    mic = capture
                } else {
                    warnings.append("Microphone access is off, so your side of the call won't be transcribed.")
                }
            }
            if options.captureSystemAudio {
                try await startSource(.system, locale: locale, sessionStart: sessionStart, vocabulary: vocabulary)
                let capture = SystemAudioCapture()
                try capture.start(handler: handler(for: .system))
                system = capture
            }
            state = .recording
        } catch {
            log.error("Failed to start recording: \(String(describing: error))")
            await teardown()
            state = .failed(String(describing: error))
        }
    }

    /// Stops capture, waits for the final words to be transcribed, and marks the meeting ended.
    @discardableResult
    public func stop() async -> Meeting? {
        guard state == .recording || state == .preparing else { return meeting }
        state = .stopping
        await teardown()
        if var meeting {
            meeting.endedAt = Date()
            try? store.upsertMeeting(meeting)
            self.meeting = meeting
        }
        volatileText = [:]
        levels = [:]
        state = .idle
        return meeting
    }

    /// Update the user's raw notes for the in-progress meeting.
    public func updateNotes(_ notes: String) {
        guard var meeting else { return }
        meeting.rawNotes = notes
        self.meeting = meeting
        try? store.upsertMeeting(meeting)
    }

    public func updateTitle(_ title: String) {
        guard var meeting else { return }
        meeting.title = title
        self.meeting = meeting
        try? store.upsertMeeting(meeting)
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func startSource(_ source: TranscriptSource, locale: Locale, sessionStart: Date, vocabulary: [String]) async throws {
        let transcriber = LiveTranscriber(source: source, sessionStart: sessionStart) { [weak self] update in
            Task { @MainActor in self?.receive(update) }
        }
        try await transcriber.start(locale: locale, contextualStrings: vocabulary)
        transcribers[source] = transcriber
    }

    private func handler(for source: TranscriptSource) -> @Sendable (AVAudioPCMBuffer) -> Void {
        let transcriber = transcribers[source]
        return { [weak self] buffer in
            transcriber?.append(buffer)
            let level = buffer.rmsLevel
            Task { @MainActor in self?.publishLevel(level, for: source) }
        }
    }

    private func publishLevel(_ level: Float, for source: TranscriptSource) {
        let now = Date()
        if let last = lastLevelPublish[source], now.timeIntervalSince(last) < 0.1 { return }
        lastLevelPublish[source] = now
        levels[source] = level
    }

    private func receive(_ update: TranscriptUpdate) {
        guard let meeting, !update.text.isEmpty else {
            if update.isFinal { volatileText[update.source] = nil }
            return
        }
        guard update.isFinal else {
            volatileText[update.source] = update.text
            return
        }
        volatileText[update.source] = nil
        let segment = TranscriptSegment(meetingID: meeting.id, source: update.source, text: update.text,
                                        startOffset: update.start, endOffset: update.end)
        switch segment.source {
        case .microphone:
            if segments.contains(where: { EchoFilter.isEcho(mic: segment, system: $0) }) { return }
        case .system:
            for echo in segments where EchoFilter.isEcho(mic: echo, system: segment) {
                segments.removeAll { $0.id == echo.id }
                try? store.deleteSegment(id: echo.id, meetingID: meeting.id)
            }
        }
        let index = segments.firstIndex { $0.startOffset > segment.startOffset } ?? segments.endIndex
        segments.insert(segment, at: index)
        do { try store.upsertSegment(segment) } catch { log.error("Saving segment failed: \(String(describing: error))") }
    }

    private func teardown() async {
        mic?.stop()
        system?.stop()
        mic = nil
        system = nil
        let active = transcribers
        transcribers = [:]
        for transcriber in active.values { await transcriber.finish() }
    }
}
