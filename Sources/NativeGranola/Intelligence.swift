import AppKit
import GranolaCore
import GranolaIntelligence
import SwiftUI

enum Intelligence {
    static func client() throws -> XAIClient {
        try XAIClient(secrets: .shared, model: Preferences.model)
    }

    static var hasXAIKey: Bool { Secrets.shared.get(.xaiAPIKey) != nil }
    static var hasNotion: Bool { Secrets.shared.get(.notionToken) != nil && !Preferences.notionDatabaseID.isEmpty }

    /// Returns the Meeting Notes database ID, finding or creating it under the given parent page.
    static func ensureNotionDatabase(parentPage: String) async throws -> String {
        let notion = try NotionClient(secrets: .shared)
        if let existing = try await notion.findDatabase(title: Preferences.notionDatabaseTitle) {
            Preferences.notionDatabaseID = existing
            return existing
        }
        guard let parentID = NotionClient.pageID(fromURL: parentPage) else {
            throw NotionError.invalidPageID(parentPage)
        }
        let id = try await notion.createMeetingsDatabase(parentPageID: parentID, title: Preferences.notionDatabaseTitle)
        Preferences.notionDatabaseID = id
        return id
    }
}

extension AppState {
    /// Generates AI notes, streaming them into `streamingNotes` so the UI can show progress.
    func generateNotes(meetingID: String, templateID: String? = nil) async {
        guard var meeting = try? store.meeting(id: meetingID), !enhancing.contains(meetingID) else { return }
        let segments = (try? store.segments(meetingID: meetingID)) ?? []
        guard !segments.isEmpty || !meeting.rawNotes.isEmpty else {
            lastError = "Nothing to summarize yet: the transcript and notes are empty."
            return
        }
        enhancing.insert(meetingID)
        streamingNotes[meetingID] = ""
        defer {
            enhancing.remove(meetingID)
            streamingNotes[meetingID] = nil
        }
        do {
            let enhancer = NoteEnhancer(client: try Intelligence.client())
            let template = NoteTemplate.resolve(templateID ?? meeting.templateID ?? Preferences.defaultTemplateID)
            if Self.needsTitle(meeting), !segments.isEmpty,
               let title = try? await enhancer.suggestTitle(meeting: meeting, segments: segments), !title.isEmpty {
                meeting.title = title
            }
            var text = ""
            for try await delta in enhancer.streamEnhance(meeting: meeting, segments: segments, template: template,
                                                          userName: Preferences.userName) {
                text += delta
                streamingNotes[meetingID] = text
            }
            meeting.enhancedNotes = NoteEnhancer.cleanOutput(text)
            meeting.templateID = template.id
            save(meeting)
        } catch {
            report(error)
        }
    }

    func exportToNotion(meetingID: String) async {
        guard var meeting = try? store.meeting(id: meetingID) else { return }
        exporting.insert(meetingID)
        defer { exporting.remove(meetingID) }
        do {
            let notion = try NotionClient(secrets: .shared)
            let databaseID = Preferences.notionDatabaseID.isEmpty
                ? try await Intelligence.ensureNotionDatabase(parentPage: Preferences.notionParentPage)
                : Preferences.notionDatabaseID
            if let previous = meeting.notionPageURL {
                try? await notion.archivePage(id: previous)
            }
            let url = try await notion.exportMeeting(meeting, segments: (try? store.segments(meetingID: meetingID)) ?? [],
                                                     databaseID: databaseID)
            meeting.notionPageURL = url.absoluteString
            save(meeting)
        } catch {
            report(error)
        }
    }

    func postProcess(_ meeting: Meeting) async {
        guard Preferences.autoEnhance, Intelligence.hasXAIKey else { return }
        await generateNotes(meetingID: meeting.id)
    }

    static func needsTitle(_ meeting: Meeting) -> Bool {
        meeting.calendarEventID == nil && meeting.title.hasPrefix("Meeting ")
    }
}

/// Toolbar actions for a meeting: generate notes with a template, export to Notion, copy.
struct IntelligenceActions: View {
    let meetingID: String
    @Environment(AppState.self) private var state

    var body: some View {
        let meeting = state.selectedMeeting
        let busy = state.enhancing.contains(meetingID)
        Menu {
            ForEach(NoteTemplate.builtIn) { template in
                Button(template.name) { Task { await state.generateNotes(meetingID: meetingID, templateID: template.id) } }
            }
        } label: {
            Label(busy ? "Generating…" : "Generate notes", systemImage: "sparkles")
        } primaryAction: {
            Task { await state.generateNotes(meetingID: meetingID) }
        }
        .disabled(busy || state.recorder.isRecording && state.recorder.meeting?.id == meetingID)
        .help("Generate AI notes (click) or pick a template (arrow)")

        Menu {
            Button {
                guard let meeting else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(meeting.enhancedNotes ?? meeting.rawNotes, forType: .string)
            } label: { Label("Copy notes", systemImage: "doc.on.doc") }
            Divider()
            Button {
                Task { await state.exportToNotion(meetingID: meetingID) }
            } label: {
                Label(state.exporting.contains(meetingID) ? "Exporting…" : "Export to Notion", systemImage: "square.and.arrow.up")
            }
            .disabled(state.exporting.contains(meetingID) || Secrets.shared.get(.notionToken) == nil)
            if let url = meeting?.notionPageURL.flatMap(URL.init(string:)) {
                Button { NSWorkspace.shared.open(url) } label: { Label("Open in Notion", systemImage: "arrow.up.forward.square") }
            }
        } label: {
            Label("Share", systemImage: state.exporting.contains(meetingID) ? "arrow.trianglehead.2.clockwise" : "square.and.arrow.up")
        }
        .help(Secrets.shared.get(.notionToken) == nil ? "Copy notes (connect Notion in Settings to export)" : "Copy or export to Notion")
    }
}
