import GranolaCore
import SwiftUI

struct MeetingDetailView: View {
    let meetingID: String
    @Environment(AppState.self) private var state
    @State private var draft: Meeting?
    @State private var tab: Tab = .notes
    @State private var showTranscript = false
    @State private var saveTask: Task<Void, Never>?

    enum Tab: String, CaseIterable { case enhanced = "Enhanced", notes = "My notes" }

    private var isLive: Bool { state.recorder.isRecording && state.recorder.meeting?.id == meetingID }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                if let draft {
                    header(draft)
                    Divider()
                    content(draft)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
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
                Toggle(isOn: $showTranscript) { Label("Transcript", systemImage: "waveform") }
                    .help("Show transcript")
            }
        }
    }

    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: binding(\.title))
                .textFieldStyle(.plain)
                .font(.largeTitle.bold())
            HStack(spacing: 10) {
                Label(meeting.startedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                if let duration = meeting.duration {
                    Label(Transcript.timestamp(duration), systemImage: "clock")
                } else if isLive {
                    Label("Recording", systemImage: "record.circle").foregroundStyle(.red)
                }
                if !meeting.attendees.isEmpty {
                    Label(meeting.attendees.map(\.displayName).joined(separator: ", "), systemImage: "person.2")
                        .lineLimit(1)
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            if meeting.enhancedNotes != nil {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private func content(_ meeting: Meeting) -> some View {
        if let streaming = state.streamingNotes[meetingID] {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Writing notes…", systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                        .symbolEffect(.pulse)
                    MarkdownView(markdown: streaming)
                }
                .padding(.horizontal, 28).padding(.vertical, 18)
            }
        } else if tab == .enhanced, let enhanced = meeting.enhancedNotes {
            ScrollView {
                MarkdownView(markdown: enhanced)
                    .padding(.horizontal, 28).padding(.vertical, 18)
            }
        } else {
            TextEditor(text: binding(\.rawNotes))
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 22).padding(.vertical, 12)
                .overlay(alignment: .topLeading) {
                    if meeting.rawNotes.isEmpty {
                        Text(isLive ? "Jot down anything important. Native Granola is transcribing in the background."
                                    : "Write notes…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 28).padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
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

struct TranscriptPanel: View {
    let meeting: Meeting
    let isLive: Bool
    @Environment(AppState.self) private var state

    var body: some View {
        let segments = state.segments(for: meeting)
        VStack(spacing: 0) {
            HStack {
                Text("Transcript").font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Transcript.format(segments), forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("Copy transcript")
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(segments) { segment in
                            Bubble(text: segment.text, source: segment.source, time: segment.startOffset)
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
                    .padding(12)
                }
                .onChange(of: segments.count) { withAnimation { proxy.scrollTo("bottom") } }
            }
            if segments.isEmpty && !isLive {
                ContentUnavailableView("No transcript", systemImage: "waveform.slash")
            }
        }
        .background(.background.secondary)
    }
}

struct Bubble: View {
    let text: String
    let source: TranscriptSource
    let time: TimeInterval?

    var body: some View {
        let mine = source == .microphone
        HStack {
            if mine { Spacer(minLength: 30) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(mine ? Color.green.opacity(0.18) : Color.gray.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 10))
                if let time {
                    Text("\(source.speakerLabel) · \(Transcript.timestamp(time))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if !mine { Spacer(minLength: 30) }
        }
    }
}
