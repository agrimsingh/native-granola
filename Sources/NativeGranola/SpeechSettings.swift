import GranolaSpeech
import SwiftUI

enum SpeechPreferences {
    private static let defaults = UserDefaults.standard

    /// Parakeet beat the live Apple transcriber on noisy and conversational audio (docs/asr-benchmark.md).
    static var retranscribe: Bool {
        get { defaults.object(forKey: "speechRetranscribe") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "speechRetranscribe") }
    }

    static var model: ParakeetModel {
        get { defaults.string(forKey: "speechModel").flatMap(ParakeetModel.init(rawValue:)) ?? .v3 }
        set { defaults.set(newValue.rawValue, forKey: "speechModel") }
    }

    static var separateSpeakers: Bool {
        get { defaults.object(forKey: "speechSeparateSpeakers") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "speechSeparateSpeakers") }
    }

    static var nameSpeakers: Bool {
        get { defaults.object(forKey: "speechNameSpeakers") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "speechNameSpeakers") }
    }

    static var isEnabled: Bool { retranscribe || separateSpeakers }
}

struct SpeechSettings: View {
    @AppStorage("speechRetranscribe") private var retranscribe = true
    @AppStorage("speechModel") private var model = ParakeetModel.v3
    @AppStorage("speechSeparateSpeakers") private var separateSpeakers = true
    @AppStorage("speechNameSpeakers") private var nameSpeakers = true
    @AppStorage("systemAudioScope") private var scope = Preferences.SystemAudioScope.app
    @AppStorage("keepAudio") private var keepAudio = true
    @AppStorage("audioRetentionDays") private var retentionDays = 7
    @State private var sizes: [String: Int64] = [:]
    @State private var refresh = 0
    private var pipeline: SpeechPipeline { .shared }

    var body: some View {
        Form {
            Section {
                Toggle("Record only the meeting app", isOn: Binding(
                    get: { scope == .app }, set: { scope = $0 ? .app : .all }))
                Toggle("Keep meeting audio", isOn: $keepAudio)
                Picker("Delete audio after", selection: $retentionDays) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("Never").tag(0)
                }
                .disabled(!keepAudio)
            } header: {
                Text("Recording")
            } footer: {
                Text("When a meeting starts from a detected app, only that app's audio is recorded, so music or a video elsewhere stays out. Meetings started by hand record all system audio. Saved audio is what the steps below work from; without it, the live transcript is kept as is.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Re-transcribe after the meeting with Parakeet", isOn: $retranscribe)
                Picker("Model", selection: $model) {
                    ForEach(ParakeetModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .disabled(!retranscribe)
                Toggle("Separate speakers", isOn: $separateSpeakers)
                Toggle("Name speakers from attendees", isOn: $nameSpeakers)
                    .disabled(!separateSpeakers)
            } header: {
                Text("After a meeting")
            } footer: {
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(model.displayName, value: status(downloaded: model.isDownloaded, size: sizes[model.rawValue]))
                LabeledContent("Speaker separation",
                               value: status(downloaded: DiarizerModel.isDownloaded, size: sizes["diarizer"]))
                HStack {
                    Button("Download models") {
                        Task {
                            await pipeline.downloadModels()
                            refresh += 1
                        }
                    }
                    .disabled(pipeline.isDownloading || (model.isDownloaded && DiarizerModel.isDownloaded))
                    if let progress = pipeline.downloadProgress {
                        ProgressView(value: progress).frame(maxWidth: 160)
                    }
                    if let error = pipeline.downloadError {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
            } header: {
                Text("Models")
            } footer: {
                Text("About 0.5 GB per Parakeet model and 30 MB for speaker separation, kept in ~/Library/Application Support/FluidAudio/Models. They download automatically the first time they're needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .id(refresh)
        .task(id: refresh) { await loadSizes() }
    }

    private var footer: String {
        var text = "Runs on this Mac once the recording stops, using the saved audio. If it fails, the live transcript stays."
        if nameSpeakers && separateSpeakers {
            text += Intelligence.hasXAIKey
                ? " Naming sends the transcript and attendee list to Grok."
                : " Naming speakers needs an xAI API key (AI tab)."
        }
        return text
    }

    private func status(downloaded: Bool, size: Int64?) -> String {
        guard downloaded else { return "Not downloaded" }
        guard let size, size > 0 else { return "Downloaded" }
        return "Downloaded · " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func loadSizes() async {
        let dirs = ParakeetModel.allCases.map { ($0.rawValue, $0.cacheDirectory) } + [("diarizer", DiarizerModel.cacheDirectory)]
        let computed = await Task.detached(priority: .utility) {
            Dictionary(uniqueKeysWithValues: dirs.map { ($0.0, $0.1.allocatedSize) })
        }.value
        sizes = computed
    }
}
