import GranolaCore
import SwiftUI

struct MeetingDetailView: View {
    let meetingID: String
    @Environment(AppState.self) private var state
    @State private var draft: Meeting?
    @State private var tab: Tab = .notes
    @State private var showTranscript = false
    @State private var saveTask: Task<Void, Never>?
    @State private var pageWidth: CGFloat = 800

    enum Tab: String, CaseIterable { case enhanced = "AI notes", notes = "My notes" }

    private var isLive: Bool { state.recorder.isRecording && state.recorder.meeting?.id == meetingID }

    var body: some View {
        HStack(spacing: 0) {
            if let draft {
                page(draft)
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                if showTranscript {
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                        .ignoresSafeArea(.container, edges: .top)
                    TranscriptPanel(meeting: draft, isLive: isLive)
                        .frame(width: 320)
                        .background { Theme.sunken.ignoresSafeArea(.container, edges: .top) }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: showTranscript)
        .background(Theme.canvas)
        .onAppear(perform: load)
        .onChange(of: state.meetings) { refreshFromStore() }
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItemGroup {
                IntelligenceActions(meetingID: meetingID)
                    .tint(Theme.ink)
            }
        }
    }

    private func page(_ meeting: Meeting) -> some View {
        ZStack(alignment: .bottom) {
            if let streaming = state.streamingNotes[meetingID] {
                document(meeting, markdown: streaming)
            } else if tab == .enhanced, let enhanced = meeting.enhancedNotes {
                document(meeting, markdown: enhanced)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header(meeting).readableColumn()
                    editor(meeting).readableColumn()
                }
            }
            LinearGradient(colors: [Theme.canvas.opacity(0), Theme.canvas], startPoint: .top, endPoint: .bottom)
                .frame(height: 72)
                .allowsHitTesting(false)
            NoteDock(meeting: meeting, isLive: isLive, showTranscript: $showTranscript)
                .padding(.bottom, 20)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
    }

    private var titleSize: CGFloat {
        switch pageWidth {
        case ..<560: 26
        case ..<760: 29
        case ..<1000: 32
        default: 34
        }
    }

    private func document(_ meeting: Meeting, markdown: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(meeting)
                MarkdownView(markdown: markdown)
            }
            .readableColumn()
            .padding(.bottom, 110)
        }
    }

    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Untitled meeting", text: binding(\.title), axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.serif(titleSize))
                .tracking(-0.5)
                .lineLimit(1...3)
                .foregroundStyle(Theme.ink)
            metadata(meeting)
            if state.streamingNotes[meetingID] != nil {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles").symbolEffect(.pulse)
                    Text("Writing notes…")
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.accentInk)
                .padding(.vertical, 5)
            } else if meeting.enhancedNotes != nil {
                NoteTabSwitcher(tab: $tab)
            }
        }
        .padding(.top, 30)
        .padding(.bottom, 22)
    }

    /// Pills never truncate: the row steps down to shorter wording until it fits, and only the
    /// last resort is allowed to squeeze.
    private func metadata(_ meeting: Meeting) -> some View {
        ViewThatFits(in: .horizontal) {
            metadataRow(meeting, density: .full).fixedSize()
            metadataRow(meeting, density: .compact).fixedSize()
            metadataRow(meeting, density: .minimal).fixedSize()
            metadataRow(meeting, density: .minimal)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum MetaDensity { case full, compact, minimal }

    private func metadataRow(_ meeting: Meeting, density: MetaDensity) -> some View {
        let names = meeting.attendees.map(\.displayName)
        let app = meeting.sourceApp.flatMap { id in AppInfo.name(bundleID: id).map { (id: id, name: $0) } }
        return HStack(spacing: 6) {
            if isLive {
                MetaPill {
                    RecordingDot()
                    Text("Recording").foregroundStyle(Theme.danger)
                }
                .fixedSize()
                .layoutPriority(2)
            }
            MetaPill {
                Image(systemName: "calendar")
                Text(meeting.startedAt.formatted(density == .full
                    ? .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
                    : density == .compact ? .dateTime.month(.abbreviated).day().hour().minute()
                    : .dateTime.month(.abbreviated).day()))
                if let duration = meeting.duration {
                    Text("·").foregroundStyle(Theme.inkTertiary)
                    Text(Self.duration(duration))
                }
            }
            .layoutPriority(1)
            .help(meeting.startedAt.formatted(date: .complete, time: .shortened))
            if !names.isEmpty {
                MetaPill {
                    AvatarStack(attendees: meeting.attendees, size: 15)
                    switch density {
                    case .full: Text(names.joined(separator: ", "))
                    case .compact: Text(People.short(meeting.attendees))
                    case .minimal: if names.count > 3 { Text("+\(names.count - 3)") }
                    }
                }
                .help(names.joined(separator: "\n"))
            }
            if let app {
                MetaPill {
                    if let icon = AppInfo.icon(bundleID: app.id) {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    }
                    if density != .minimal { Text(app.name) }
                }
                .help(app.name)
            }
        }
    }

    /// "31 min", "1 hr 5 min", "40 sec".
    static func duration(_ seconds: TimeInterval) -> String {
        let rounded = Duration.seconds(seconds.rounded())
        return seconds < 60
            ? rounded.formatted(.units(allowed: [.seconds], width: .abbreviated))
            : rounded.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }

    private func editor(_ meeting: Meeting) -> some View {
        TextEditor(text: binding(\.rawNotes))
            .font(.system(size: 14.5))
            .lineSpacing(4.5)
            .foregroundStyle(Theme.ink)
            .tint(Theme.accentInk)
            .scrollContentBackground(.hidden)
            .overlay(alignment: .topLeading) {
                if meeting.rawNotes.isEmpty {
                    Text(isLive ? "Jot down anything important. Native Granola is transcribing in the background."
                                : "Write notes…")
                        .font(.system(size: 14.5))
                        .foregroundStyle(Theme.inkSecondary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, -5)
            .padding(.bottom, 80)
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
        HStack(spacing: 0) {
            ForEach(MeetingDetailView.Tab.allCases, id: \.self) { option in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { tab = option }
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(tab == option ? Theme.ink : Theme.inkSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background {
                            if tab == option {
                                Capsule()
                                    .fill(Theme.raised)
                                    .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "selection", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.softFill, in: Capsule())
    }
}

/// The floating pill at the bottom of a note: transcript toggle with audio bars, plus the one
/// action that matters right now (stop while live, generate once the call is over).
struct NoteDock: View {
    let meeting: Meeting
    let isLive: Bool
    @Binding var showTranscript: Bool
    @Environment(AppState.self) private var state

    var body: some View {
        let recorder = state.recorder
        HStack(spacing: 4) {
            Button {
                showTranscript.toggle()
            } label: {
                HStack(spacing: 8) {
                    DancingBars(level: isLive ? max(recorder.levels[.microphone] ?? 0, recorder.levels[.system] ?? 0) : nil)
                    if isLive {
                        ElapsedTime(since: meeting.startedAt)
                    } else {
                        Text("Transcript")
                    }
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(showTranscript ? Theme.accentInk : Theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(showTranscript ? Theme.accentGround : .clear, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(showTranscript ? "Hide transcript" : "Show transcript")

            if isLive {
                Button {
                    Task { await state.stopMeeting() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(PillButtonStyle(kind: .danger))
            } else if meeting.enhancedNotes == nil, !meeting.isInProgress, Intelligence.hasXAIKey,
                      state.streamingNotes[meeting.id] == nil {
                Button {
                    Task { await state.generateNotes(meetingID: meeting.id) }
                } label: {
                    Label("Generate notes", systemImage: "sparkles")
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .disabled(state.enhancing.contains(meeting.id))
            }
        }
        .padding(4)
        .background(Theme.raised, in: Capsule())
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
    }
}

struct TranscriptPanel: View {
    let meeting: Meeting
    let isLive: Bool
    @Environment(AppState.self) private var state

    var body: some View {
        let segments = state.segments(for: meeting)
        let hasVolatile = isLive && state.recorder.volatileText.values.contains { !$0.isEmpty }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Transcript")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                if isLive { RecordingDot() }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Transcript.format(segments), forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").foregroundStyle(Theme.inkSecondary)
                }
                .buttonStyle(.borderless)
                .help("Copy transcript")
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if segments.isEmpty && !hasVolatile {
                VStack(spacing: 6) {
                    Image(systemName: isLive ? "waveform" : "waveform.slash")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.inkTertiary)
                        .padding(.bottom, 4)
                    Text(isLive ? "Listening…" : "No transcript")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    if isLive {
                        Text("What you and the other side say will appear here.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.inkSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(TranscriptTurn.turns(segments)) { turn in
                                Bubble(text: turn.text, source: turn.source, speaker: turn.speaker, time: turn.start)
                            }
                            if isLive {
                                ForEach(TranscriptSource.allCases, id: \.self) { source in
                                    if let text = state.recorder.volatileText[source], !text.isEmpty {
                                        Bubble(text: text, source: source, speaker: source.speakerLabel, time: nil).opacity(0.55)
                                    }
                                }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(16)
                    }
                    .onChange(of: segments.count) { withAnimation { proxy.scrollTo("bottom") } }
                }
            }
        }
        .background(Theme.sunken)
    }
}

/// Consecutive segments from the same speaker, shown as one bubble.
struct TranscriptTurn: Identifiable {
    let id: String
    let source: TranscriptSource
    let speaker: String
    let start: TimeInterval
    var text: String

    static func turns(_ segments: [TranscriptSegment]) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        for segment in segments.sorted(by: { $0.startOffset < $1.startOffset }) {
            if let last = turns.last, last.source == segment.source, last.speaker == segment.displaySpeaker {
                turns[turns.count - 1].text += " " + segment.text
            } else {
                turns.append(TranscriptTurn(id: segment.id, source: segment.source, speaker: segment.displaySpeaker,
                                            start: segment.startOffset, text: segment.text))
            }
        }
        return turns
    }
}

struct Bubble: View {
    let text: String
    let source: TranscriptSource
    let speaker: String
    let time: TimeInterval?

    var body: some View {
        let mine = source == .microphone
        HStack {
            if mine { Spacer(minLength: 32) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if let time {
                    Text("\(speaker) · \(Transcript.timestamp(time))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.inkSecondary)
                        .monospacedDigit()
                        .padding(.horizontal, 4)
                }
                Text(text)
                    .font(.system(size: 13))
                    .lineSpacing(2.5)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(mine ? Theme.accentGround : Theme.raised,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if !mine { Spacer(minLength: 32) }
        }
    }
}
