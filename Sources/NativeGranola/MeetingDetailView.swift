import GranolaCore
import SwiftUI

struct MeetingDetailView: View {
    let meetingID: String
    @Environment(AppState.self) private var state
    @State private var draft: Meeting?
    @State private var tab: Tab = .notes
    @State private var showTranscript = false
    @State private var saveTask: Task<Void, Never>?

    enum Tab: String, CaseIterable {
        case enhanced = "AI notes", notes = "My notes"

        var systemImage: String { self == .enhanced ? "sparkles" : "pencil.line" }
    }

    private var isLive: Bool { state.recorder.isRecording && state.recorder.meeting?.id == meetingID }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                if let draft {
                    header(draft)
                    content(draft)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) { bottomBar(draft) }
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            if showTranscript, let draft {
                TranscriptPanel(meeting: draft, isLive: isLive)
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 480)
            }
        }
        .onAppear(perform: load)
        .onChange(of: state.meetings) { refreshFromStore() }
        .toolbar {
            ToolbarItemGroup {
                IntelligenceActions(meetingID: meetingID)
                Toggle(isOn: $showTranscript) { Label("Transcript", systemImage: "text.bubble") }
                    .help("Show transcript")
            }
        }
    }

    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Untitled meeting", text: binding(\.title))
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .bold))
            metadata(meeting)
            if state.streamingNotes[meetingID] != nil {
                Label("Writing notes…", systemImage: "sparkles")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse)
                    .padding(.vertical, 5)
            } else if meeting.enhancedNotes != nil {
                NoteTabSwitcher(tab: $tab)
            }
        }
        .readableColumn()
        .padding(.top, 28)
        .padding(.bottom, 14)
    }

    private func metadata(_ meeting: Meeting) -> some View {
        HStack(spacing: 6) {
            MetaChip(meeting.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()),
                     systemImage: "calendar")
            if let duration = meeting.duration {
                MetaChip(Transcript.timestamp(duration), systemImage: "clock")
            } else if isLive {
                MetaChip(text: "Recording") { RecordingDot() }
            }
            if !meeting.attendees.isEmpty {
                MetaChip(text: meeting.attendees.map(\.displayName).joined(separator: ", ")) {
                    AvatarStack(attendees: meeting.attendees, size: 16)
                }
                .help(meeting.attendees.map(\.displayName).joined(separator: "\n"))
            }
            if let bundleID = meeting.sourceApp, let name = AppInfo.name(bundleID: bundleID) {
                MetaChip(text: name) { MeetingGlyph(meeting: meeting, size: 14) }
            }
        }
    }

    @ViewBuilder
    private func content(_ meeting: Meeting) -> some View {
        if let streaming = state.streamingNotes[meetingID] {
            ScrollView {
                MarkdownView(markdown: streaming)
                    .readableColumn()
                    .padding(.top, 8).padding(.bottom, 80)
            }
        } else if tab == .enhanced, let enhanced = meeting.enhancedNotes {
            ScrollView {
                MarkdownView(markdown: enhanced)
                    .readableColumn()
                    .padding(.top, 8).padding(.bottom, 80)
            }
        } else {
            GeometryReader { geometry in
                let inset = max(Theme.pagePadding, (geometry.size.width - Theme.readableWidth) / 2) - 5
                TextEditor(text: binding(\.rawNotes))
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .contentMargins(.horizontal, inset, for: .scrollContent)
                    .contentMargins(.vertical, 8, for: .scrollContent)
                    .overlay(alignment: .topLeading) {
                        if meeting.rawNotes.isEmpty {
                            Text(isLive ? "Jot down anything important. Native Granola is transcribing in the background."
                                        : "Write notes…")
                                .font(.system(size: 14))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, inset + 5).padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func bottomBar(_ meeting: Meeting) -> some View {
        if isLive {
            RecordingBar(meeting: meeting, showTranscript: $showTranscript)
                .padding(.bottom, 20)
        } else if meeting.enhancedNotes == nil, !meeting.isInProgress, Intelligence.hasXAIKey,
                  !state.enhancing.contains(meetingID) {
            Button {
                Task { await state.generateNotes(meetingID: meetingID) }
            } label: {
                Label("Generate notes", systemImage: "sparkles")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(Theme.accent)
            .padding(.bottom, 20)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<Meeting, String>) -> Binding<String> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? "" },
            set: { value in
                draft?[keyPath: keyPath] = value
                scheduleSave()
            })
    }

    private func load() {
        draft = state.selectedMeeting
        tab = draft?.enhancedNotes != nil ? .enhanced : .notes
        showTranscript = showTranscript || isLive
    }

    /// Pick up changes made elsewhere (AI notes, Notion URL) without clobbering in-progress typing.
    private func refreshFromStore() {
        guard saveTask == nil, let latest = state.selectedMeeting, latest.id == meetingID else { return }
        let hadEnhanced = draft?.enhancedNotes != nil
        draft = latest
        if !hadEnhanced, latest.enhancedNotes != nil { tab = .enhanced }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let draft else { return }
            state.update(draft)
            saveTask = nil
        }
    }
}

struct NoteTabSwitcher: View {
    @Binding var tab: MeetingDetailView.Tab
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MeetingDetailView.Tab.allCases, id: \.self) { option in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { tab = option }
                } label: {
                    Label(option.rawValue, systemImage: option.systemImage)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(tab == option ? .primary : .secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background {
                            if tab == option {
                                Capsule()
                                    .fill(Color.primary.opacity(0.1))
                                    .matchedGeometryEffect(id: "selection", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.04), in: Capsule())
    }
}

/// Floating controls shown at the bottom of a meeting while it's being recorded.
struct RecordingBar: View {
    let meeting: Meeting
    @Binding var showTranscript: Bool
    @Environment(AppState.self) private var state

    var body: some View {
        let recorder = state.recorder
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                RecordingDot()
                ElapsedTime(since: meeting.startedAt)
                    .font(.callout.weight(.medium))
            }
            HStack(spacing: 12) {
                speaker("Me", level: recorder.levels[.microphone] ?? 0)
                speaker("Them", level: recorder.levels[.system] ?? 0)
            }
            Divider().frame(height: 16)
            Button {
                showTranscript.toggle()
            } label: {
                Image(systemName: "text.bubble")
            }
            .buttonStyle(.borderless)
            .help(showTranscript ? "Hide transcript" : "Show transcript")
            Button {
                Task { await state.stopMeeting() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: Capsule())
    }

    private func speaker(_ label: String, level: Float) -> some View {
        HStack(spacing: 5) {
            LiveBars(level: level)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct TranscriptPanel: View {
    let meeting: Meeting
    let isLive: Bool
    @Environment(AppState.self) private var state

    var body: some View {
        let segments = state.segments(for: meeting)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Transcript").font(.headline)
                if isLive { RecordingDot() }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Transcript.format(segments), forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy transcript")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(TranscriptTurn.turns(segments)) { turn in
                            Bubble(text: turn.text, source: turn.source, time: turn.start)
                        }
                        if isLive {
                            ForEach(TranscriptSource.allCases, id: \.self) { source in
                                if let text = state.recorder.volatileText[source], !text.isEmpty {
                                    Bubble(text: text, source: source, time: nil).opacity(0.55)
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(16)
                }
                .onChange(of: segments.count) { withAnimation { proxy.scrollTo("bottom") } }
            }
            .overlay {
                if segments.isEmpty, !isLive || state.recorder.volatileText.values.allSatisfy(\.isEmpty) {
                    ContentUnavailableView(
                        isLive ? "Listening…" : "No transcript",
                        systemImage: isLive ? "waveform" : "waveform.slash",
                        description: Text(isLive ? "What you and the other side say will show up here." : ""))
                }
            }
        }
        .background(.background.secondary)
    }
}

/// Consecutive segments from the same speaker, shown as one bubble.
struct TranscriptTurn: Identifiable {
    let id: String
    let source: TranscriptSource
    let start: TimeInterval
    var text: String

    static func turns(_ segments: [TranscriptSegment]) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        for segment in segments.sorted(by: { $0.startOffset < $1.startOffset }) {
            if let last = turns.last, last.source == segment.source {
                turns[turns.count - 1].text += " " + segment.text
            } else {
                turns.append(TranscriptTurn(id: segment.id, source: segment.source, start: segment.startOffset,
                                            text: segment.text))
            }
        }
        return turns
    }
}

struct Bubble: View {
    let text: String
    let source: TranscriptSource
    let time: TimeInterval?

    var body: some View {
        let mine = source == .microphone
        HStack {
            if mine { Spacer(minLength: 36) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if let time {
                    Text("\(source.speakerLabel) · \(Transcript.timestamp(time))")
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                Text(text)
                    .font(.callout)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(mine ? Theme.accent.opacity(0.2) : Color.primary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if !mine { Spacer(minLength: 36) }
        }
    }
}
