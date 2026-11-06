import GranolaIntelligence
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            SpeechSettings().tabItem { Label("Transcription", systemImage: "waveform") }
            AISettings().tabItem { Label("AI", systemImage: "sparkles") }
            TemplateSettings().tabItem { Label("Templates", systemImage: "list.bullet.rectangle") }
            NotionSettings().tabItem { Label("Notion", systemImage: "doc.richtext") }
            IntegrationSettings().tabItem { Label("Cursor MCP", systemImage: "point.3.connected.trianglepath.dotted") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

private struct GeneralSettings: View {
    @AppStorage("userName") private var userName = NSFullUserName()
    @AppStorage("echoCancellation") private var echoCancellation = true
    @AppStorage("autoEnhance") private var autoEnhance = true
    @AppStorage("autoStop") private var autoStop = true
    @State private var vocabulary = Preferences.customVocabulary.joined(separator: ", ")

    var body: some View {
        Form {
            TextField("Your name", text: $userName)
            Toggle("Echo cancellation (for calls on speakers)", isOn: $echoCancellation)
            Toggle("Generate AI notes when a meeting ends", isOn: $autoEnhance)
            Toggle("Stop recording when the call app releases the mic", isOn: $autoStop)
            TextField("Custom vocabulary (comma separated)", text: $vocabulary, axis: .vertical)
                .onChange(of: vocabulary) {
                    Preferences.customVocabulary = vocabulary.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
            Text("Names and terms here, plus calendar attendees, help the transcriber spell them right.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AISettings: View {
    @AppStorage("xaiModel") private var model = Preferences.defaultModel
    @State private var key = ""
    @State private var status = ""
    @State private var models: [String] = []

    var body: some View {
        Form {
            SecureField("xAI API key", text: $key, prompt: Text(placeholder))
            HStack {
                Button("Save key") { save() }.disabled(key.isEmpty)
                Button("Test") { Task { await test() } }
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Picker("Model", selection: $model) {
                ForEach(Array(Set(models + [model])).sorted(), id: \.self) { Text($0).tag($0) }
            }
            Text("Used for enhanced notes, titles and chat. Transcription stays on-device.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await loadModels() }
    }

    private var placeholder: String {
        Secrets.shared.source(of: .xaiAPIKey).map { "Saved (\($0.rawValue))" } ?? "xai-…"
    }

    private func save() {
        do {
            try Secrets.shared.set(key, for: .xaiAPIKey)
            key = ""
            status = "Saved to Keychain"
            Task { await loadModels() }
        } catch { status = error.localizedDescription }
    }

    private func test() async {
        do {
            let reply = try await Intelligence.client().complete(
                messages: [.init(role: .user, content: "Reply with the single word: ready")], model: model)
            status = "OK: \(reply.prefix(40))"
        } catch { status = String(describing: error) }
    }

    private func loadModels() async {
        guard Secrets.shared.get(.xaiAPIKey) != nil else { return }
        if let list = try? await Intelligence.client().listModels() {
            models = list.filter { $0.hasPrefix("grok") && !$0.contains("imagine") }
        }
    }
}

private struct NotionSettings: View {
    @AppStorage("notionParentPage") private var parentPage = ""
    @AppStorage("notionDatabaseID") private var databaseID = ""
    @State private var token = ""
    @State private var status = ""

    var body: some View {
        Form {
            SecureField("Integration token", text: $token,
                        prompt: Text(Secrets.shared.source(of: .notionToken) != nil ? "Saved" : "ntn_…"))
            TextField("Parent page URL", text: $parentPage, prompt: Text("https://www.notion.so/…"))
            HStack {
                Button("Save & connect") { Task { await connect() } }
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if !databaseID.isEmpty {
                LabeledContent("Database", value: databaseID).font(.caption)
            }
            Text("Create an internal integration at notion.so/profile/integrations, then add it to the parent page under ••• → Connections. Native Granola creates a \"Meeting Notes\" database there.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func connect() async {
        do {
            if !token.isEmpty { try Secrets.shared.set(token, for: .notionToken); token = "" }
            databaseID = try await Intelligence.ensureNotionDatabase(parentPage: parentPage)
            status = "Connected"
        } catch { status = String(describing: error) }
    }
}

private struct IntegrationSettings: View {
    @State private var status = ""

    var body: some View {
        Form {
            Text("Let Cursor (and other MCP clients) search and read your meetings. Native Granola adds itself to ~/.cursor/mcp.json as a local stdio server; nothing leaves your Mac.")
                .font(.callout)
            LabeledContent("Command", value: MCPInstaller.command)
                .font(.caption.monospaced())
            HStack {
                Button(MCPInstaller.isInstalled ? "Reinstall in Cursor" : "Add to Cursor") {
                    do { try MCPInstaller.install(); status = "Added. Restart Cursor's MCP servers to pick it up." }
                    catch { status = String(describing: error) }
                }
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

enum MCPInstaller {
    static let serverName = "native-granola"
    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/mcp.json")
    }
    static var command: String { Bundle.main.executableURL?.path ?? CommandLine.arguments[0] }

    static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any] else { return false }
        return servers[serverName] != nil
    }

    static func install() throws {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL) {
            json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        var servers = json["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": command, "args": ["--mcp"]]
        json["mcpServers"] = servers
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: configURL, options: .atomic)
    }
}
