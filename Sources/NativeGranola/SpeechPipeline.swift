import Foundation
import GranolaCore
import GranolaIntelligence
import GranolaSpeech
import Observation
import os

/// Post-meeting transcript work (Parakeet re-transcription, speaker separation, speaker naming), one
/// meeting at a time so only one set of models is in memory. Call `process(meetingID:)` after the
/// recorder has stopped and saved the meeting; it returns when that meeting is done.
@MainActor @Observable
final class SpeechPipeline {
    static let shared = SpeechPipeline()

    enum Status: Equatable {
        case queued
        case transcribing
        case separatingSpeakers
        case namingSpeakers
        /// Finished; `notes` holds anything worth surfacing (e.g. "kept the live transcript").
        case done(notes: [String])
        case failed(String)

        var label: String {
            switch self {
            case .queued: "Waiting to improve transcript…"
            case .transcribing: "Improving transcript…"
            case .separatingSpeakers: "Separating speakers…"
            case .namingSpeakers: "Naming speakers…"
            case .done: "Transcript improved"
            case let .failed(message): "Transcript processing failed: \(message)"
            }
        }

        var isActive: Bool {
            switch self {
            case .done, .failed: false
            default: true
            }
        }
    }

    /// Per meeting ID. Entries stay after finishing so the UI can show the result.
    private(set) var status: [String: Status] = [:]
    private(set) var downloadProgress: Double?
    private(set) var downloadError: String?

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.nativegranola", category: "speech")

    static func process(meetingID: String) async {
        await shared.process(meetingID: meetingID)
    }

    func process(meetingID: String) async {
        guard SpeechPreferences.isEnabled else { return }
        if let running = tasks[meetingID] { return await running.value }
        status[meetingID] = .queued
        let previous = tail
        let task = Task {
            await previous?.value
            await run(meetingID)
        }
        tasks[meetingID] = task
        tail = task
        await task.value
        tasks[meetingID] = nil
    }

    func cancel(meetingID: String) {
        tasks[meetingID]?.cancel()
    }

    private func run(_ meetingID: String) async {
        guard !Task.isCancelled else { return finish(meetingID, .failed("Cancelled")) }
        let store = AppState.shared.store
        let processor = PostMeetingProcessor(store: store, options: .init(
            retranscribeWith: SpeechPreferences.retranscribe ? SpeechPreferences.model : nil,
            separateSpeakers: SpeechPreferences.separateSpeakers))
        do {
            var outcome = try await processor.run(meetingID: meetingID) { stage in
                Task { @MainActor in SpeechPipeline.shared.advance(meetingID, to: stage) }
            }
            if SpeechPreferences.nameSpeakers, outcome.speakerCount > 0, Intelligence.hasXAIKey,
               let meeting = try store.meeting(id: meetingID) {
                status[meetingID] = .namingSpeakers
                do {
                    let segments = try store.segments(meetingID: meetingID)
                    let names = try await SpeakerNamer(client: try Intelligence.client())
                        .nameSpeakers(meeting: meeting, segments: segments, userName: Preferences.userName)
                    try Task.checkCancellation()
                    if !names.isEmpty {
                        try store.setSpeakers(SpeakerAssignment.rename(segments, names: names), meetingID: meetingID)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    outcome.warnings.append("Naming speakers failed: \(error.localizedDescription)")
                }
            }
            for warning in outcome.warnings { log.warning("\(meetingID): \(warning)") }
            finish(meetingID, .done(notes: outcome.warnings))
        } catch is CancellationError {
            finish(meetingID, .failed("Cancelled"))
        } catch {
            log.error("\(meetingID): \(String(describing: error))")
            finish(meetingID, .failed(String(describing: error)))
        }
    }

    private func advance(_ meetingID: String, to stage: PostMeetingProcessor.Stage) {
        guard status[meetingID]?.isActive == true else { return }
        status[meetingID] = stage == .separatingSpeakers ? .separatingSpeakers : .transcribing
    }

    private func finish(_ meetingID: String, _ result: Status) {
        status[meetingID] = result
    }

    // MARK: Models

    var isDownloading: Bool { downloadProgress != nil }

    /// Downloads whatever the current preferences need. Models also download on first use.
    func downloadModels() async {
        guard !isDownloading else { return }
        downloadError = nil
        downloadProgress = 0
        defer { downloadProgress = nil }
        var steps: [@Sendable ((@Sendable (Double) -> Void)?) async throws -> Void] = []
        let model = SpeechPreferences.model
        if !model.isDownloaded { steps.append { try await model.download(progress: $0) } }
        if !DiarizerModel.isDownloaded { steps.append { try await DiarizerModel.download(progress: $0) } }
        for (i, step) in steps.enumerated() {
            let base = Double(i) / Double(steps.count), share = 1 / Double(steps.count)
            do {
                try await step { fraction in
                    Task { @MainActor in
                        let pipeline = SpeechPipeline.shared
                        guard pipeline.downloadProgress != nil else { return }
                        pipeline.downloadProgress = base + share * min(max(fraction, 0), 1)
                    }
                }
            } catch {
                downloadError = error.localizedDescription
                return
            }
        }
    }
}
