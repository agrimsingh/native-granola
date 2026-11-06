import AVFAudio
import Foundation
import GranolaCore
import Observation
import os

/// Runs a recording session: captures mic + system audio as two separate streams, transcribes
/// each on-device, persists finalized segments to the store as they arrive, and optionally keeps
/// each stream's audio in the `AudioArchive`.
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
        public var systemAudioScope: SystemAudioCapture.Scope = .all
        /// Where to keep each source's audio (`AudioArchive` layout), or nil to not keep it.
        public var audioArchiveRoot: URL?
        public var locale: Locale = .current
        public init() {}
    }

    public private(set) var state: State = .idle
    public private(set) var meeting: Meeting?
    public private(set) var segments: [TranscriptSegment] = []
    public private(set) var volatileText: [TranscriptSource: String] = [:]
    public private(set) var levels: [TranscriptSource: Float] = [:]
    public private(set) var warnings: [String] = []
    /// True while capture is paused (e.g. the Mac is asleep); `state` stays `.recording`.
    public private(set) var isSuspended = false

    public var isRecording: Bool { state == .recording }

    /// Called with each warning raised after recording started, e.g. a system audio fallback.
    @ObservationIgnored public var onWarning: ((String) -> Void)?

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let log = Logger(subsystem: "com.nativegranola", category: "recorder")
    @ObservationIgnored private var system: SystemAudioCapture?
    @ObservationIgnored private var mic: MicrophoneCapture?
    @ObservationIgnored private var transcribers: [TranscriptSource: LiveTranscriber] = [:]
    @ObservationIgnored private var pipelines: [TranscriptSource: SourcePipeline] = [:]
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var suspension: Task<Void, Never>?

    private struct Session {
        var meetingID: String
        var start: Date
        var options: Options
        var locale: Locale
        var vocabulary: [String]
    }

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
        isSuspended = false
        var meeting = meeting
        meeting.endedAt = nil
        self.meeting = meeting
        do {
            try store.upsertMeeting(meeting)
            let locale = try await LiveTranscriber.prepare(locale: options.locale)
            session = Session(meetingID: meeting.id, start: meeting.startedAt, options: options,
                              locale: locale, vocabulary: vocabulary)
            try await startSources(initial: true)
            state = .recording
        } catch {
            log.error("Failed to start recording: \(String(describing: error))")
            await teardown()
            state = .failed(String(describing: error))
        }
    }

    /// Stops capture, waits for the final words to be transcribed, closes the audio files and marks
    /// the meeting ended (at `endedAt`, default now). When this returns the archive files are complete.
    @discardableResult
    public func stop(endedAt: Date? = nil) async -> Meeting? {
        guard state == .recording || state == .preparing else { return meeting }
        state = .stopping
        let end = endedAt ?? Date()
        await teardown(end: end)
        if var meeting {
            meeting.endedAt = end
            try? store.upsertMeeting(meeting)
            self.meeting = meeting
        }
        volatileText = [:]
        levels = [:]
        isSuspended = false
        state = .idle
        return meeting
    }

    /// Pauses capture without ending the meeting, e.g. before the Mac sleeps. Pending words are
    /// finalized; the audio files stay open and the gap is filled with silence on resume.
    public func suspend() async {
        guard state == .recording, !isSuspended else { return }
        isSuspended = true
        let task = Task { await self.stopSources() }
        suspension = task
        await task.value
        volatileText = [:]
        levels = [:]
    }

    /// Restarts capture after `suspend()`. Devices can take a moment to come back after wake, so this retries.
    public func resume() async {
        guard state == .recording, isSuspended else { return }
        await suspension?.value
        suspension = nil
        for attempt in 1...3 {
            do {
                try await startSources(initial: false)
                isSuspended = false
                return
            } catch {
                log.error("Resume attempt \(attempt) failed: \(String(describing: error))")
                await stopSources()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        warn("Recording couldn't resume after sleep. Stop and start a new meeting to keep transcribing.")
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

    private func startSources(initial: Bool) async throws {
        guard let session else { return }
        let options = session.options
        if options.captureMicrophone {
            if await MicrophoneCapture.requestPermission() {
                let pipeline = try await startPipeline(.microphone, session: session)
                let capture = MicrophoneCapture(voiceProcessing: options.echoCancellation)
                try capture.start(handler: pipeline.handler)
                mic = capture
            } else if initial {
                warnings.append("Microphone access is off, so your side of the call won't be transcribed.")
            }
        }
        if options.captureSystemAudio {
            let pipeline = try await startPipeline(.system, session: session)
            let capture = SystemAudioCapture(scope: options.systemAudioScope) { [weak self] reason in
                Task { @MainActor in self?.systemAudioFellBack(reason) }
            }
            try capture.start(handler: pipeline.handler)
            if options.systemAudioScope != .all, capture.activeScope == .all { systemAudioFellBack(.appNotFound) }
            system = capture
        }
    }

    private func startPipeline(_ source: TranscriptSource, session: Session) async throws -> SourcePipeline {
        let pipeline = pipelines[source] ?? SourcePipeline(
            source: source, sessionStart: session.start,
            archiveURL: session.options.audioArchiveRoot.map {
                AudioArchive.url(meetingID: session.meetingID, source: source, root: $0)
            },
            onLevel: { [weak self] level in
                Task { @MainActor in
                    guard let self, self.isRecording, !self.isSuspended else { return }
                    self.levels[source] = level
                }
            })
        pipelines[source] = pipeline
        let transcriber = LiveTranscriber(source: source, sessionStart: session.start) { [weak self] update in
            Task { @MainActor in self?.receive(update) }
        }
        try await transcriber.start(locale: session.locale, contextualStrings: session.vocabulary)
        transcribers[source] = transcriber
        pipeline.setTranscriber(transcriber)
        return pipeline
    }

    private func systemAudioFellBack(_ reason: AppTapMonitor.Reason) {
        guard var session, session.options.systemAudioScope != .all else { return }
        session.options.systemAudioScope = .all
        self.session = session
        warn(reason == .appNotFound
            ? "Couldn't find the meeting app's audio, so all system audio is being transcribed."
            : "The meeting app hasn't played any audio while other apps have, so all system audio is being transcribed.")
    }

    private func warn(_ message: String) {
        log.info("\(message, privacy: .public)")
        warnings.append(message)
        onWarning?(message)
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
        let nearby = segments.reversed().prefix { $0.endOffset >= segment.startOffset - 60 }
        switch segment.source {
        case .microphone:
            if nearby.contains(where: { EchoFilter.isEcho(mic: segment, system: $0) }) { return }
        case .system:
            for echo in nearby where EchoFilter.isEcho(mic: echo, system: segment) {
                segments.removeAll { $0.id == echo.id }
                try? store.deleteSegment(id: echo.id, meetingID: meeting.id)
            }
        }
        let index = segments.lastIndex { $0.startOffset <= segment.startOffset }.map { $0 + 1 } ?? 0
        segments.insert(segment, at: index)
        do { try store.upsertSegment(segment) } catch { log.error("Saving segment failed: \(String(describing: error))") }
    }

    /// Stops capture and finishes the transcribers, keeping the pipelines (timeline + open audio files).
    private func stopSources() async {
        mic?.stop()
        system?.stop()
        mic = nil
        system = nil
        for pipeline in pipelines.values {
            await pipeline.drain()
            pipeline.setTranscriber(nil)
        }
        let active = transcribers
        transcribers = [:]
        for transcriber in active.values { await transcriber.finish() }
    }

    private func teardown(end: Date? = nil) async {
        await suspension?.value
        suspension = nil
        await stopSources()
        let endOffset = end.map { max(0, $0.timeIntervalSince(session?.start ?? $0)) } ?? 0
        for pipeline in pipelines.values { await pipeline.close(at: endOffset) }
        pipelines = [:]
        session = nil
    }
}
