import Foundation
import GranolaAudio
import GranolaCore
import GranolaIntelligence

/// Headless test modes, run through the signed bundle so macOS attributes permissions to the app:
///   open -W -n build/NativeGranola.app --args --selftest transcribe-file <audio> <out.json>
///   open -W -n build/NativeGranola.app --args --selftest record <seconds> <out.json> [--no-mic] [--no-system]
enum SelfTest {
    struct Output: Encodable {
        var ok: Bool
        var error: String?
        var warnings: [String] = []
        var segments: [Segment] = []
        var transcript: String = ""
    }

    struct Segment: Encodable {
        var source: String
        var text: String
        var start: Double
        var end: Double
    }

    static func run(_ args: [String]) -> Never {
        Task { @MainActor in
            let output: Output
            var outPath = "/tmp/native-granola-selftest.json"
            do {
                switch args.first {
                case "transcribe-file" where args.count >= 3:
                    outPath = args[2]
                    output = try await transcribeFile(URL(fileURLWithPath: args[1]))
                case "record" where args.count >= 3:
                    outPath = args[2]
                    output = try await record(seconds: Double(args[1]) ?? 10,
                                              mic: !args.contains("--no-mic"), system: !args.contains("--no-system"),
                                              storeURL: URL(fileURLWithPath: outPath + ".sqlite"))
                case "enhance" where args.count >= 2:
                    outPath = args[1]
                    output = try await enhanceSample()
                case "seed-demo" where args.count >= 2:
                    outPath = args[1]
                    output = try await enhanceSample(saveTo: try Store())
                default:
                    output = Output(ok: false, error: "usage: --selftest transcribe-file <audio> <out> | record <seconds> <out>")
                }
            } catch {
                output = Output(ok: false, error: String(describing: error))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(output).write(to: URL(fileURLWithPath: outPath))
            exit(output.ok ? 0 : 1)
        }
        dispatchMain()
    }

    @MainActor
    static func transcribeFile(_ url: URL) async throws -> Output {
        let locale = try await LiveTranscriber.prepare()
        let updates = try await FileTranscriber.transcribe(url: url, locale: locale)
        let segments = updates.map { Segment(source: "file", text: $0.text, start: $0.start, end: $0.end) }
        return Output(ok: true, segments: segments, transcript: updates.map(\.text).joined(separator: " "))
    }

    /// Generates AI notes for a canned meeting with the configured Grok model.
    @MainActor
    static func enhanceSample(saveTo store: Store? = nil) async throws -> Output {
        var meeting = Meeting(title: "Demo: Pricing page launch sync",
                              startedAt: Date().addingTimeInterval(-3600), endedAt: Date().addingTimeInterval(-3600 + 96),
                              attendees: [Attendee(name: "Priya Shah", email: "priya@example.com"),
                                          Attendee(name: "Marcus Lee", email: "marcus@example.com")],
                              rawNotes: "launch date?\nonboarding emails - priya")
        let lines: [(TranscriptSource, String)] = [
            (.microphone, "Okay, let's get started. Main thing today is the pricing page launch."),
            (.system, "So engineering is basically done, but legal still hasn't signed off on the enterprise tier copy."),
            (.microphone, "Can we still make Tuesday?"),
            (.system, "Honestly no. I'd move it to next Thursday to be safe. That gives legal two more days."),
            (.microphone, "Fine, Thursday it is. Priya, can you own the onboarding emails for the new plans?"),
            (.system, "Yes, I'll have drafts by Monday. Marcus, you're updating the pricing table, right?"),
            (.system, "Yep, I'll also add the annual discount, we agreed on fifteen percent."),
            (.microphone, "Great. Let's sync again Wednesday to confirm everything is green."),
        ]
        let segments = lines.enumerated().map { i, line in
            TranscriptSegment(meetingID: meeting.id, source: line.0, text: line.1,
                              startOffset: Double(i * 12), endOffset: Double(i * 12 + 10))
        }
        let enhancer = NoteEnhancer(client: try Intelligence.client())
        let started = Date()
        let notes = try await enhancer.enhance(meeting: meeting, segments: segments, template: .default,
                                               userName: Preferences.userName)
        let title = try await enhancer.suggestTitle(meeting: meeting, segments: segments)
        if let store {
            meeting.enhancedNotes = notes
            try store.upsertMeeting(meeting)
            for segment in segments { try store.upsertSegment(segment) }
        }
        return Output(ok: true, warnings: ["model: \(Preferences.model)", "seconds: \(Int(Date().timeIntervalSince(started)))",
                                           "suggested title: \(title)"],
                      transcript: notes)
    }

    @MainActor
    static func record(seconds: Double, mic: Bool, system: Bool, storeURL: URL) async throws -> Output {
        try? FileManager.default.removeItem(at: storeURL)
        let store = try Store(url: storeURL)
        let recorder = MeetingRecorder(store: store)
        var options = MeetingRecorder.Options()
        options.captureMicrophone = mic
        options.captureSystemAudio = system
        await recorder.start(Meeting(title: "Self test"), options: options)
        if case let .failed(message) = recorder.state {
            return Output(ok: false, error: message, warnings: recorder.warnings)
        }
        try await Task.sleep(for: .seconds(seconds))
        let meeting = await recorder.stop()
        let segments = try store.segments(meetingID: meeting?.id ?? "")
        return Output(
            ok: true, warnings: recorder.warnings,
            segments: segments.map { Segment(source: $0.source.rawValue, text: $0.text, start: $0.startOffset, end: $0.endOffset) },
            transcript: Transcript.format(segments))
    }
}
