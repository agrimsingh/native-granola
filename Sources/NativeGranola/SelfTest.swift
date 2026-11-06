import AVFAudio
import Foundation
import GranolaAudio
import GranolaCore
import GranolaIntelligence

/// Headless test modes, run through the signed bundle so macOS attributes permissions to the app:
///   open -W -n build/NativeGranola.app --args --selftest transcribe-file <audio> <out.json>
///   open -W -n build/NativeGranola.app --args --selftest record <seconds> <out.json> [--no-mic] [--no-system]
///       [--no-aec] [--app <bundleID>] [--keep-audio] [--suspend <atSeconds> <forSeconds>]
///   open -W -n build/NativeGranola.app --args --selftest audio-processes <bundleID> <out.json>
/// `--keep-audio` writes the archive under `<out.json>.audio/`; `--suspend` pauses and resumes mid-recording.
enum SelfTest {
    struct Output: Encodable {
        var ok: Bool
        var error: String?
        var warnings: [String] = []
        var segments: [Segment] = []
        var transcript: String = ""
        var archives: [Archive]?
        var processes: [Process]?
    }

    struct Archive: Encodable {
        var source: String
        var path: String
        var seconds: Double
        var sampleRate: Double
        var channels: UInt32
        var float32: Bool
        /// Whole seconds into the file whose level is clearly above silence.
        var loudSeconds: [Int]
    }

    struct Process: Encodable {
        var pid: Int32
        var bundleID: String?
        var parentPID: Int32?
        var responsiblePID: Int32?
        var playing: Bool
        var matched: Bool
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
                    var options = MeetingRecorder.Options()
                    options.captureMicrophone = !args.contains("--no-mic")
                    options.captureSystemAudio = !args.contains("--no-system")
                    options.echoCancellation = !args.contains("--no-aec")
                    if let app = value(after: "--app", in: args) { options.systemAudioScope = .app(bundleID: app) }
                    if args.contains("--keep-audio") { options.audioArchiveRoot = URL(fileURLWithPath: outPath + ".audio") }
                    var suspend: (at: Double, for: Double)?
                    if let i = args.firstIndex(of: "--suspend"), i + 2 < args.count,
                       let at = Double(args[i + 1]), let duration = Double(args[i + 2]) {
                        suspend = (at, duration)
                    }
                    output = try await record(seconds: Double(args[1]) ?? 10, options: options, suspend: suspend,
                                              storeURL: URL(fileURLWithPath: outPath + ".sqlite"))
                case "audio-processes" where args.count >= 3:
                    outPath = args[2]
                    output = Output(ok: true, processes: SystemAudioCapture.processes(matching: args[1]).map {
                        Process(pid: $0.process.pid, bundleID: $0.process.bundleID, parentPID: $0.process.parentPID,
                                responsiblePID: $0.process.responsiblePID, playing: $0.process.isRunningOutput,
                                matched: $0.matched)
                    })
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

    static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func record(seconds: Double, options: MeetingRecorder.Options, suspend: (at: Double, for: Double)?,
                       storeURL: URL) async throws -> Output {
        try? FileManager.default.removeItem(at: storeURL)
        if let root = options.audioArchiveRoot { try? FileManager.default.removeItem(at: root) }
        let store = try Store(url: storeURL)
        let recorder = MeetingRecorder(store: store)
        await recorder.start(Meeting(title: "Self test"), options: options)
        if case let .failed(message) = recorder.state {
            return Output(ok: false, error: message, warnings: recorder.warnings)
        }
        if let suspend {
            try await Task.sleep(for: .seconds(suspend.at))
            await recorder.suspend()
            try await Task.sleep(for: .seconds(suspend.for))
            await recorder.resume()
            try await Task.sleep(for: .seconds(max(0, seconds - suspend.at - suspend.for)))
        } else {
            try await Task.sleep(for: .seconds(seconds))
        }
        let meeting = await recorder.stop()
        let segments = try store.segments(meetingID: meeting?.id ?? "")
        let archives = options.audioArchiveRoot.map { root in
            TranscriptSource.allCases.compactMap { archive(AudioArchive.url(meetingID: meeting?.id ?? "", source: $0, root: root), source: $0) }
        }
        return Output(
            ok: true, warnings: recorder.warnings,
            segments: segments.map { Segment(source: $0.source.rawValue, text: $0.text, start: $0.startOffset, end: $0.endOffset) },
            transcript: Transcript.format(segments), archives: archives)
    }

    static func archive(_ url: URL, source: TranscriptSource) -> Archive? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate))
        else { return nil }
        var loud: [Int] = []
        var second = 0
        while file.framePosition < file.length, (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 {
            let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
            if rms > 0.005 { loud.append(second) }
            second += 1
        }
        return Archive(source: source.rawValue, path: url.path, seconds: Double(file.length) / file.fileFormat.sampleRate,
                       sampleRate: file.fileFormat.sampleRate, channels: file.fileFormat.channelCount,
                       float32: file.fileFormat.commonFormat == .pcmFormatFloat32, loudSeconds: loud)
    }
}
