import GranolaCore
import GranolaIntelligence
import SwiftUI

struct MeetingDetailView: View {
    let meetingID: String
    @Environment(AppState.self) private var state
    @State private var draft: Meeting
    @State private var tab: Tab
    @State private var saveTask: Task<Void, Never>?
    @State private var pageWidth: CGFloat = 800

    enum Tab: String { case enhanced = "AI notes", notes = "My notes", transcript = "Transcript" }

    private var isLive: Bool { state.recorder.isRecording && state.recorder.meeting?.id == meetingID }

    /// The note starts from `meeting` rather than loading it once on screen: a view with nothing
    /// to show has nothing for `onAppear` to fire on, which left the whole pane blank.
    init(meeting: Meeting) {
        meetingID = meeting.id
        _draft = State(initialValue: meeting)
        _tab = State(initialValue: meeting.enhancedNotes != nil ? .enhanced : .notes)
    }

    var body: some View {
        page(draft)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
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
                document(meeting) { MarkdownView(markdown: streaming, bodySize: bodySize) }
            } else if tab == .enhanced, let enhanced = meeting.enhancedNotes {
                document(meeting) { MarkdownView(markdown: enhanced, bodySize: bodySize) }
            } else if tab == .transcript {
                document(meeting, anchor: isLive ? .bottom : .top) {
                    TranscriptView(meeting: meeting, isLive: isLive, bodySize: bodySize)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header(meeting).readableColumn(padding: pagePadding)
                    editor(meeting).readableColumn(padding: pagePadding)
                }
            }
            if isLive || NoteDock.offersGenerate(meeting, state: state) {
                VStack(spacing: 0) {
                    LinearGradient(colors: [Theme.canvas.opacity(0), Theme.canvas], startPoint: .top, endPoint: .bottom)
                        .frame(height: 32)
                    Theme.canvas.frame(height: 46)
                }
                .allowsHitTesting(false)
                NoteDock(meeting: meeting, isLive: isLive)
                    .padding(.bottom, 20)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pageWidth = $0 }
    }

    private var pagePadding: CGFloat { pageWidth < 480 ? 28 : Theme.pagePadding }
    private var bodySize: CGFloat { pageWidth >= 1000 ? 15 : 14.5 }

    private func tabs(_ meeting: Meeting) -> [Tab] {
        meeting.enhancedNotes != nil ? [.enhanced, .notes, .transcript] : [.notes, .transcript]
    }

    private var titleSize: CGFloat {
        switch pageWidth {
        case ..<400: 23
        case ..<560: 26
        case ..<760: 29
        case ..<1000: 32
        default: 34
        }
    }

    private func document(_ meeting: Meeting, anchor: UnitPoint? = nil,
                          @ViewBuilder content: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(meeting)
                content()
            }
            .readableColumn(padding: pagePadding)
            .padding(.bottom, 110)
        }
        .defaultScrollAnchor(anchor)
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
            } else {
                NoteTabSwitcher(tab: $tab, tabs: tabs(meeting))
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
            metadataRow(meeting, density: .tight).fixedSize()
            metadataRow(meeting, density: .minimal).fixedSize()
            metadataRow(meeting, density: .micro).fixedSize()
            metadataRow(meeting, density: .nano).fixedSize()
            metadataRow(meeting, density: .nano)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Steps down in order: weekday, time, names to a count, duration, app name, people count.
    private enum MetaDensity: Comparable { case full, compact, tight, minimal, micro, nano }

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
                    .monospacedDigit()
                if let duration = meeting.duration, density < .minimal {
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
                    case .tight, .minimal, .micro: Text(names.count == 1 ? People.short(meeting.attendees) : "\(names.count) people")
                    case .nano: if names.count > 3 { Text("+\(names.count - 3)") }
                    }
                }
                .help(names.joined(separator: "\n"))
            }
            if let app {
                MetaPill {
                    if let icon = AppInfo.icon(bundleID: app.id) {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    }
                    if density < .micro { Text(app.name) }
                }
                .help(app.name)
                .accessibilityLabel(app.name)
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
            .padding(.bottom, 100)
    }

    private func binding(_ keyPath: WritableKeyPath<Meeting, String>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { value in
                draft[keyPath: keyPath] = value
                scheduleSave()
            })
    }

    /// Pick up changes made elsewhere (AI notes, Notion URL) without clobbering in-progress typing.
    private func refreshFromStore() {
        guard saveTask == nil, let latest = state.selectedMeeting, latest.id == meetingID else { return }
        let hadEnhanced = draft.enhancedNotes != nil
        draft = latest
        if !hadEnhanced, latest.enhancedNotes != nil { tab = .enhanced }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            state.update(draft)
            saveTask = nil
        }
    }
}

struct NoteTabSwitcher: View {
    @Binding var tab: MeetingDetailView.Tab
    let tabs: [MeetingDetailView.Tab]
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { option in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { tab = option }
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(tab == option ? Theme.ink : Theme.inkSecondary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 5)
                        .background {
                            if tab == option {
                                Capsule()
                                    .fill(Theme.segmentSelected)
                                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
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

/// The floating pill at the bottom of a note, holding the one action that matters right now:
/// stop while live, generate once the call is over.
struct NoteDock: View {
    let meeting: Meeting
    let isLive: Bool
    @Environment(AppState.self) private var state

    /// Whether the dock owns the Generate action; the toolbar offers it only when this is false.
    @MainActor static func offersGenerate(_ meeting: Meeting, state: AppState) -> Bool {
        meeting.enhancedNotes == nil && !meeting.isInProgress && Intelligence.hasXAIKey
            && state.streamingNotes[meeting.id] == nil
    }

    var body: some View {
        let recorder = state.recorder
        HStack(spacing: 4) {
            if isLive {
                HStack(spacing: 8) {
                    DancingBars(level: max(recorder.levels[.microphone] ?? 0, recorder.levels[.system] ?? 0))
                    ElapsedTime(since: meeting.startedAt)
                }
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Recording")
                Button {
                    Task { await state.stopMeeting() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(PillButtonStyle(kind: .danger))
            } else {
                Button {
                    Task { await state.generateNotes(meetingID: meeting.id) }
                } label: {
                    Label("Generate notes", systemImage: "sparkles")
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .disabled(state.enhancing.contains(meeting.id))
                .contextMenu {
                    ForEach(NoteTemplate.builtIn) { template in
                        Button(template.name) {
                            Task { await state.generateNotes(meetingID: meeting.id, templateID: template.id) }
                        }
                    }
                }
                .help("Generate AI notes (right-click to pick a template)")
            }
        }
        .padding(4)
        .background(Theme.raised, in: Capsule())
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
    }
}

/// The transcript as part of the note: speaker and time over each turn, in reading order.
struct TranscriptView: View {
    let meeting: Meeting
    let isLive: Bool
    var bodySize: CGFloat = 14.5
    @Environment(AppState.self) private var state

    var body: some View {
        let segments = state.segments(for: meeting)
        let otherSide = meeting.otherSideLabel(userName: Preferences.userName)
        let pending = isLive ? TranscriptSource.allCases.compactMap { source in
            state.recorder.volatileText[source].flatMap { $0.isEmpty ? nil : (source: source, text: $0) }
        } : []
        if segments.isEmpty && pending.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(isLive ? "Listening…" : "No transcript")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(isLive ? "What you and the other side say will appear here."
                            : "Nothing was transcribed for this meeting.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(TranscriptTurn.turns(segments, otherSide: otherSide)) { turn in
                    TranscriptLine(speaker: turn.speaker, mine: turn.source == .microphone, time: turn.start,
                                   text: turn.text, bodySize: bodySize)
                }
                ForEach(pending, id: \.source) { line in
                    TranscriptLine(speaker: line.source == .microphone ? line.source.speakerLabel : otherSide,
                                   mine: line.source == .microphone, time: nil, text: line.text, bodySize: bodySize)
                        .opacity(0.55)
                }
            }
        }
    }
}

/// Consecutive segments from the same speaker, shown as one turn.
struct TranscriptTurn: Identifiable {
    let id: String
    let source: TranscriptSource
    let speaker: String
    let start: TimeInterval
    var text: String

    static func turns(_ segments: [TranscriptSegment], otherSide: String) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        for segment in segments.sorted(by: { $0.startOffset < $1.startOffset }) {
            let speaker = segment.displaySpeaker(otherSide: otherSide)
            if let last = turns.last, last.source == segment.source, last.speaker == speaker {
                turns[turns.count - 1].text += " " + segment.text
            } else {
                turns.append(TranscriptTurn(id: segment.id, source: segment.source, speaker: speaker,
                                            start: segment.startOffset, text: segment.text))
            }
        }
        return turns
    }
}

struct TranscriptLine: View {
    let speaker: String
    let mine: Bool
    let time: TimeInterval?
    let text: String
    var bodySize: CGFloat = 14.5

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(speaker)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(mine ? Theme.accentInk : Theme.ink)
                if let time {
                    Text(Transcript.timestamp(time))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            Text(text)
                .font(.system(size: bodySize))
                .lineSpacing(bodySize * 0.32)
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

