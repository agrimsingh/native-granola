import AVFAudio
import Foundation
import GranolaAudio
import GranolaCore
import GranolaIntelligence
import GranolaSpeech

/// Speech benchmarks, run through the signed bundle so Apple's speech models are available:
///   open -W -n NativeGranola.app --args --benchmark asr <manifest.json> <out.json> [--engines apple,parakeet-v3,parakeet-v2]
///   open -W -n NativeGranola.app --args --benchmark pipeline <system.wav> <mic.wav> <out.json>
///       [--model v2|v3] [--timeline <turns.json>] [--attendees "Name A,Name B"] [--user "My Name"]
/// The manifest is a JSON array of {id, category, audio, reference}. A markdown summary goes to <out>.md.
enum Benchmark {
    struct Item: Codable {
        var id: String
        var category: String
        var audio: String
        var reference: String
    }

    struct Row: Codable {
        var engine: String
        var id: String
        var category: String
        var audioSeconds: Double
        var processingSeconds: Double
        var wer: WordErrorRate
        var hypothesis: String
        var error: String?
    }

    struct EngineLoad: Codable {
        var engine: String
        /// First load in this process, including any download and Core ML compilation.
        var loadSeconds: Double
        var wasDownloaded: Bool
        var modelBytes: Int64?
    }

    struct ASRReport: Codable {
        var loads: [EngineLoad] = []
        var rows: [Row] = []
        var error: String?
    }

    static func run(_ args: [String]) -> Never {
        Task {
            let out = URL(fileURLWithPath: args.first == "asr" && args.count >= 3 ? args[2]
                          : args.first == "pipeline" && args.count >= 4 ? args[3] : "/tmp/native-granola-benchmark.json")
            do {
                switch args.first {
                case "asr" where args.count >= 3:
                    let engines = option("--engines", in: args)?.split(separator: ",").map(String.init)
                        ?? ["apple", "parakeet-v3", "parakeet-v2"]
                    try await asr(manifest: URL(fileURLWithPath: args[1]), engines: engines, out: out)
                case "pipeline" where args.count >= 4:
                    try await pipeline(system: URL(fileURLWithPath: args[1]), mic: URL(fileURLWithPath: args[2]),
                                       model: option("--model", in: args).flatMap(ParakeetModel.init(rawValue:)) ?? .v2,
                                       timeline: option("--timeline", in: args).map(URL.init(fileURLWithPath:)),
                                       attendees: option("--attendees", in: args)?.split(separator: ",")
                                           .map { $0.trimmingCharacters(in: .whitespaces) } ?? [],
                                       userName: option("--user", in: args), out: out)
                default:
                    throw BenchmarkError.usage
                }
                exit(0)
            } catch {
                try? write(["error": String(describing: error)], to: out)
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    enum BenchmarkError: Error, CustomStringConvertible {
        case usage
        var description: String {
            "usage: --benchmark asr <manifest.json> <out.json> [--engines …] | pipeline <system> <mic> <out.json>"
        }
    }

    static func option(_ name: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: ASR accuracy and speed

    static func asr(manifest: URL, engines: [String], out: URL) async throws {
        let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: manifest))
        var report = ASRReport()
        for engine in engines {
            let started = Date()
            let transcribe: (URL) async throws -> (String, Double)
            var downloaded = false
            var bytes: Int64?
            switch engine {
            case "apple":
                let locale = try await LiveTranscriber.prepare(locale: Locale(identifier: "en-US"))
                transcribe = { url in
                    let t = Date()
                    let updates = try await FileTranscriber.transcribe(url: url, locale: locale)
                    let text = updates.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                    return (text, Date().timeIntervalSince(t))
                }
            case "parakeet-v3", "parakeet-v2":
                let model: ParakeetModel = engine == "parakeet-v3" ? .v3 : .v2
                downloaded = !model.isDownloaded
                let parakeet = ParakeetTranscriber(model: model)
                try await parakeet.load()
                bytes = model.cacheDirectory.allocatedSize
                transcribe = { url in
                    let r = try await parakeet.transcribe(url: url)
                    return (r.text, r.processingTime)
                }
            default:
                throw BenchmarkError.usage
            }
            report.loads.append(EngineLoad(engine: engine, loadSeconds: Date().timeIntervalSince(started),
                                           wasDownloaded: downloaded, modelBytes: bytes))
            // One untimed warm-up so the first item doesn't carry one-off graph setup.
            if let first = items.first { _ = try? await transcribe(URL(fileURLWithPath: first.audio)) }
            for item in items {
                let url = URL(fileURLWithPath: item.audio)
                let seconds = (try? audioDuration(url)) ?? 0
                do {
                    let (text, elapsed) = try await transcribe(url)
                    report.rows.append(Row(engine: engine, id: item.id, category: item.category, audioSeconds: seconds,
                                           processingSeconds: elapsed,
                                           wer: .compute(reference: item.reference, hypothesis: text), hypothesis: text))
                } catch {
                    report.rows.append(Row(engine: engine, id: item.id, category: item.category, audioSeconds: seconds,
                                           processingSeconds: 0,
                                           wer: .compute(reference: item.reference, hypothesis: ""), hypothesis: "",
                                           error: String(describing: error)))
                }
            }
        }
        try write(report, to: out)
        try summary(report).write(to: out.appendingPathExtension("md"), atomically: true, encoding: .utf8)
    }

    static func summary(_ report: ASRReport) -> String {
        let engines = report.loads.map(\.engine)
        let categories = Array(NSOrderedSet(array: report.rows.map(\.category))) as! [String]
        var lines = ["| Engine | " + categories.joined(separator: " | ") + " | All | RTFx | Load s |",
                     "|---" + String(repeating: "|---", count: categories.count + 3) + "|"]
        for engine in engines {
            let rows = report.rows.filter { $0.engine == engine }
            func wer(_ rs: [Row]) -> String {
                String(format: "%.1f%%", rs.map(\.wer).reduce(WordErrorRate(), +).rate * 100)
            }
            let cells = categories.map { c in wer(rows.filter { $0.category == c }) }
            let audio = rows.map(\.audioSeconds).reduce(0, +), proc = rows.map(\.processingSeconds).reduce(0, +)
            let load = report.loads.first { $0.engine == engine }
            lines.append("| \(engine) | " + cells.joined(separator: " | ") + " | \(wer(rows)) | "
                         + String(format: "%.0fx", proc > 0 ? audio / proc : 0) + " | "
                         + String(format: "%.1f%@", load?.loadSeconds ?? 0, load?.wasDownloaded == true ? " (download)" : "")
                         + " |")
        }
        let errors = report.rows.filter { $0.error != nil }.count
        if errors > 0 { lines.append("\n\(errors) items failed") }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Full post-meeting pipeline on a synthetic meeting

    struct PipelineReport: Codable {
        struct Turn: Codable { var voice: String; var text: String; var start: Double; var end: Double; var me: Bool }
        var liveSeconds: Double
        var processSeconds: Double
        var namingSeconds: Double?
        var outcomeWarnings: [String]
        var retranscribed: [String]
        var droppedEchoes: Int
        var speakerCount: Int
        var names: [String: String]?
        /// Share of system segments whose label maps to the true voice (best one-to-one label→voice mapping).
        var speakerAccuracy: Double?
        var liveTranscript: String
        var finalTranscript: String
    }

    static func pipeline(system: URL, mic: URL, model: ParakeetModel, timeline: URL?, attendees: [String],
                         userName: String?, out: URL) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ng-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let store = try Store(url: work.appendingPathComponent("granola.sqlite"))
        let root = work.appendingPathComponent("Audio")
        let meeting = Meeting(title: "Benchmark meeting", startedAt: Date().addingTimeInterval(-120), endedAt: Date(),
                              attendees: (attendees + [userName].compactMap { $0 }).map { Attendee(name: $0) })
        try store.upsertMeeting(meeting)
        try FileManager.default.createDirectory(at: AudioArchive.directory(meetingID: meeting.id, root: root),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: system, to: AudioArchive.url(meetingID: meeting.id, source: .system, root: root))
        try FileManager.default.copyItem(at: mic, to: AudioArchive.url(meetingID: meeting.id, source: .microphone, root: root))

        // Stand-in for the live transcript: Apple's model over each file, mic echoes filtered.
        let liveStart = Date()
        let locale = try await LiveTranscriber.prepare(locale: Locale(identifier: "en-US"))
        var live: [TranscriptSegment] = []
        for (source, url) in [(TranscriptSource.system, system), (.microphone, mic)] {
            for u in try await FileTranscriber.transcribe(url: url, locale: locale) where !u.text.isEmpty {
                live.append(TranscriptSegment(meetingID: meeting.id, source: source,
                                              text: u.text.trimmingCharacters(in: .whitespaces),
                                              startOffset: u.start, endOffset: u.end))
            }
        }
        let systemLive = live.filter { $0.source == .system }
        live.removeAll { m in m.source == .microphone && systemLive.contains { EchoFilter.isEcho(mic: m, system: $0) } }
        for s in live { try store.upsertSegment(s) }
        let liveSeconds = Date().timeIntervalSince(liveStart)
        let liveTranscript = try store.transcriptText(meetingID: meeting.id)

        let processStart = Date()
        let processor = PostMeetingProcessor(store: store, options: .init(retranscribeWith: model, separateSpeakers: true,
                                                                          audioRoot: root))
        let outcome = try await processor.run(meetingID: meeting.id)
        let processSeconds = Date().timeIntervalSince(processStart)

        var names: [String: String]?
        var namingSeconds: Double?
        if !attendees.isEmpty, outcome.speakerCount > 0 {
            let t = Date()
            let namer = SpeakerNamer(client: try Intelligence.client())
            let segments = try store.segments(meetingID: meeting.id)
            let found = try await namer.nameSpeakers(meeting: meeting, segments: segments, userName: userName)
            try store.setSpeakers(SpeakerAssignment.rename(segments, names: found), meetingID: meeting.id)
            names = found
            namingSeconds = Date().timeIntervalSince(t)
        }

        let final = try store.segments(meetingID: meeting.id)
        var accuracy: Double?
        if let timeline {
            let turns = try JSONDecoder().decode([PipelineReport.Turn].self, from: Data(contentsOf: timeline))
            accuracy = speakerAccuracy(final, turns: turns.filter { !$0.me })
        }
        try write(PipelineReport(liveSeconds: liveSeconds, processSeconds: processSeconds, namingSeconds: namingSeconds,
                                 outcomeWarnings: outcome.warnings, retranscribed: outcome.retranscribed.map(\.rawValue),
                                 droppedEchoes: outcome.droppedEchoes, speakerCount: outcome.speakerCount, names: names,
                                 speakerAccuracy: accuracy, liveTranscript: liveTranscript,
                                 finalTranscript: Transcript.format(final)), to: out)
    }

    static func speakerAccuracy(_ segments: [TranscriptSegment], turns: [PipelineReport.Turn]) -> Double? {
        let system = segments.filter { $0.source == .system }
        guard !system.isEmpty else { return nil }
        var counts: [String: [String: Int]] = [:]
        for s in system {
            let voice = turns.max { overlap(s, $0) < overlap(s, $1) }.map(\.voice) ?? "?"
            counts[s.speaker ?? "Them", default: [:]][voice, default: 0] += 1
        }
        var used = Set<String>(), correct = 0
        for (_, votes) in counts.sorted(by: { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }) {
            if let best = votes.filter({ !used.contains($0.key) }).max(by: { $0.value < $1.value }) {
                used.insert(best.key)
                correct += best.value
            }
        }
        return Double(correct) / Double(system.count)
    }

    private static func overlap(_ s: TranscriptSegment, _ t: PipelineReport.Turn) -> Double {
        min(s.endOffset, t.end) - max(s.startOffset, t.start)
    }

    // MARK: Helpers

    static func audioDuration(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url)
    }
}
