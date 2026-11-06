import AppKit
import GranolaCore
import SwiftUI

struct MainWindow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            MeetingList()
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 360)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        if state.recorder.isRecording {
                            Button { Task { await state.stopMeeting() } } label: {
                                Label("Stop", systemImage: "stop.circle.fill")
                            }
                            .tint(Theme.danger)
                        } else {
                            Button { Task { await state.startMeeting() } } label: {
                                Label("New note", systemImage: "square.and.pencil")
                            }
                            .disabled(state.recorder.state == .preparing)
                            .help("New note")
                        }
                    }
                }
        } detail: {
            if let meeting = state.selectedMeeting {
                MeetingDetailView(meetingID: meeting.id)
                    .id(meeting.id)
            } else {
                EmptyDetail()
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .searchable(text: $state.searchText, placement: .sidebar, prompt: "Search notes and transcripts")
        .onChange(of: state.searchText) { state.runSearch() }
        .tint(Theme.accentFill)
    }
}

private struct EmptyDetail: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let hasNotes = !state.meetings.isEmpty
        VStack(spacing: 12) {
            Text("Your meeting notes live here")
                .font(Theme.serif(28))
                .tracking(-0.4)
                .foregroundStyle(Theme.ink)
            Text(hasNotes
                 ? "Pick one from the sidebar, or start a new note when a call begins. Native Granola transcribes both sides of the conversation."
                 : "Start a note when a call begins. Native Granola transcribes both sides of the conversation and writes up the notes when you're done.")
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button {
                Task { await state.startMeeting() }
            } label: {
                Label("Start new note", systemImage: "square.and.pencil")
            }
            .buttonStyle(PillButtonStyle(kind: .accent))
            .disabled(state.recorder.isRecording || state.recorder.state == .preparing)
            .padding(.top, 10)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
}

struct MeetingList: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        List(selection: $state.selectedMeetingID) {
            if !state.searchText.isEmpty {
                ForEach(hitsByMeeting, id: \.first!.meetingID) { hits in
                    SearchResultRow(hits: hits, query: state.searchText)
                        .tag(hits[0].meetingID)
                        .listRowBackground(SelectionBackground(selected: state.selectedMeetingID == hits[0].meetingID))
                }
            } else {
                ForEach(groups, id: \.title) { group in
                    Section {
                        ForEach(group.meetings) { meeting in
                            MeetingRow(meeting: meeting, isRecording: state.recorder.isRecording && state.recorder.meeting?.id == meeting.id)
                                .tag(meeting.id)
                                .listRowBackground(SelectionBackground(selected: state.selectedMeetingID == meeting.id))
                                .contextMenu {
                                    Button("Delete", role: .destructive) { state.delete(meeting) }
                                }
                        }
                    } header: {
                        Text(group.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.sidebar)
        .background(NativeSelectionHidden())
        .overlay {
            if !state.searchText.isEmpty && state.searchHits.isEmpty {
                SidebarMessage(title: "No results", detail: "Nothing in your notes or transcripts matches “\(state.searchText)”.")
            } else if state.searchText.isEmpty && state.meetings.isEmpty {
                SidebarMessage(title: "No notes yet", detail: "Notes from your calls will show up here.")
            }
        }
    }

    /// One row per meeting so a single selection never highlights several rows.
    private var hitsByMeeting: [[SearchHit]] {
        var order: [String] = []
        var byMeeting: [String: [SearchHit]] = [:]
        for hit in state.searchHits {
            if byMeeting[hit.meetingID] == nil { order.append(hit.meetingID) }
            byMeeting[hit.meetingID, default: []].append(hit)
        }
        return order.compactMap { byMeeting[$0] }
    }

    private var groups: [(title: String, meetings: [Meeting])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: state.meetings) { meeting -> String in
            if calendar.isDateInToday(meeting.startedAt) { return "Today" }
            if calendar.isDateInYesterday(meeting.startedAt) { return "Yesterday" }
            return meeting.startedAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
        return grouped
            .map { (title: $0.key, meetings: $0.value) }
            .sorted { ($0.meetings.first?.startedAt ?? .distantPast) > ($1.meetings.first?.startedAt ?? .distantPast) }
    }
}

/// The sidebar's own selection fill, drawn in place of the system's accent-blue highlight.
private struct SelectionBackground: View {
    let selected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Theme.selection : .clear)
            .padding(.horizontal, 10)
    }
}

/// Turns off the table view's selection drawing behind a SwiftUI `List`, keeping selection itself
/// (clicks, arrow keys, accessibility) native.
private struct NativeSelectionHidden: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            var ancestor = view.superview
            for _ in 0..<6 {
                guard let current = ancestor else { return }
                if let table = Self.table(in: current) {
                    if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                    return
                }
                ancestor = current.superview
            }
        }
    }

    private static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews { if let table = table(in: sub) { return table } }
        return nil
    }
}

private struct SearchResultRow: View {
    let hits: [SearchHit]
    let query: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            VStack(alignment: .leading, spacing: 2) {
                Text(hits[0].meetingTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(hits[0].meetingStartedAt, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkSecondary)
            }
            let matches = hits.filter { $0.kind != .title }
            ForEach(Array(matches.prefix(expanded ? matches.count : 2).enumerated()), id: \.offset) { _, hit in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: icon(hit.kind))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Text(snippet(hit))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
            }
            if matches.count > 2 && !expanded {
                Button("+\(matches.count - 2) more") { expanded = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accentInk)
                    .padding(.leading, 18)
            }
        }
        .padding(.vertical, 4)
    }

    private func icon(_ kind: SearchHit.Kind) -> String {
        switch kind {
        case .transcript: "waveform"
        case .enhancedNotes: "sparkles"
        case .notes: "pencil"
        case .title: "textformat"
        }
    }

    private func label(_ kind: SearchHit) -> String {
        switch kind.kind {
        case .transcript: "Transcript"
        case .enhancedNotes: "AI notes"
        case .notes: "My notes"
        case .title: "Title"
        }
    }

    /// Each match leads with where it was found ("Transcript 00:23", "AI notes").
    private func snippet(_ hit: SearchHit) -> AttributedString {
        var place = label(hit)
        if hit.kind == .transcript, let offset = hit.startOffset { place += " " + Transcript.timestamp(offset) }
        var prefix = AttributedString(place + "  ")
        prefix.foregroundColor = Theme.inkTertiary
        prefix.font = .system(size: 11, weight: .medium).monospacedDigit()
        return prefix + Self.snippet(hit.snippet, query: query)
    }

    /// Snippets are cut from markdown with the match wrapped in `**`. Block syntax is dropped so
    /// headings and bullets don't run together, and only bold runs that contain a query term are
    /// highlighted; bold from the notes themselves goes back to plain text.
    static func snippet(_ text: String, query: String) -> AttributedString {
        let terms = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let joined = text
            .split(whereSeparator: \.isNewline)
            .map { line in
                line.trimmingCharacters(in: .whitespaces)
                    .replacing(#/^(#{1,6}\s+|[-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+|>\s*)/#, with: "")
            }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let flat = leadingUpToMatch(joined, terms: terms)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = (try? AttributedString(markdown: flat, options: options)) ?? AttributedString(flat)
        for run in result.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
            let words = String(result[run.range].characters).lowercased()
            if terms.contains(where: { words.contains($0) }) {
                result[run.range].foregroundColor = Theme.ink
                result[run.range].backgroundColor = Theme.match
            } else {
                result[run.range].inlinePresentationIntent = nil
            }
        }
        return result
    }
}

extension SearchResultRow {
    /// Trims long lead-ins so the first match lands inside the two visible lines.
    static func leadingUpToMatch(_ text: String, terms: [String], keep: Int = 28) -> String {
        let lower = text.lowercased()
        guard let match = terms.compactMap({ lower.range(of: "**" + $0) }).min(by: { $0.lowerBound < $1.lowerBound }),
              lower.distance(from: lower.startIndex, to: match.lowerBound) > keep * 2 else { return text }
        let cutOffset = lower.distance(from: lower.startIndex, to: match.lowerBound) - keep
        var cut = text.index(text.startIndex, offsetBy: cutOffset)
        let dropped = text[..<cut]
        guard dropped.components(separatedBy: "**").count % 2 == 1 else { return text }
        if let space = text[cut...].firstIndex(of: " "), space < text.index(text.startIndex, offsetBy: cutOffset + keep) {
            cut = text.index(after: space)
        }
        return "…" + text[cut...]
    }
}

private struct SidebarMessage: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.center)
        }
        .padding(24)
    }
}

struct MeetingRow: View {
    let meeting: Meeting
    let isRecording: Bool
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Group {
                    if isRecording {
                        HStack(spacing: 0) {
                            Text("Recording · ").foregroundStyle(Theme.danger)
                            ElapsedTime(since: meeting.startedAt).foregroundStyle(Theme.danger)
                        }
                    } else {
                        Text(subtitle).foregroundStyle(Theme.inkSecondary)
                    }
                }
                .font(.system(size: 12))
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isRecording {
                DancingBars(level: max(state.recorder.levels[.microphone] ?? 0, state.recorder.levels[.system] ?? 0),
                            height: 11)
            } else if meeting.enhancedNotes != nil {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.inkTertiary)
                    .help("Has AI notes")
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        let time = meeting.startedAt.formatted(date: .omitted, time: .shortened)
        return meeting.attendees.isEmpty ? time : "\(time) · \(People.short(meeting.attendees))"
    }
}
