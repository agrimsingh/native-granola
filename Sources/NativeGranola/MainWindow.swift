import GranolaCore
import SwiftUI

struct MainWindow: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            MeetingList()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let meeting = state.selectedMeeting {
                MeetingDetailView(meetingID: meeting.id)
                    .id(meeting.id)
            } else {
                ContentUnavailableView("No note selected", systemImage: "note.text",
                                       description: Text("Start a new note from the menu bar, or pick one from the list."))
            }
        }
        .searchable(text: $state.searchText, placement: .sidebar, prompt: "Search notes and transcripts")
        .onChange(of: state.searchText) { state.runSearch() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if state.recorder.isRecording {
                    Button { Task { await state.stopMeeting() } } label: {
                        Label("Stop", systemImage: "stop.circle.fill")
                    }
                    .tint(.red)
                } else {
                    Button { Task { await state.startMeeting() } } label: {
                        Label("New note", systemImage: "square.and.pencil")
                    }
                    .disabled(state.recorder.state == .preparing)
                }
            }
        }
    }
}

struct MeetingList: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        List(selection: $state.selectedMeetingID) {
            if !state.searchText.isEmpty {
                ForEach(state.searchHits, id: \.self) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.meetingTitle).font(.headline).lineLimit(1)
                        Text(snippet(hit.snippet)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(hit.meetingStartedAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .tag(hit.meetingID)
                }
            } else {
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.meetings) { meeting in
                            MeetingRow(meeting: meeting, isRecording: state.recorder.isRecording && state.recorder.meeting?.id == meeting.id)
                                .tag(meeting.id)
                                .contextMenu {
                                    Button("Delete", role: .destructive) { state.delete(meeting) }
                                }
                        }
                    }
                }
            }
        }
    }

    private func snippet(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
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

struct MeetingRow: View {
    let meeting: Meeting
    let isRecording: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).lineLimit(1)
                HStack(spacing: 4) {
                    Text(meeting.startedAt, format: .dateTime.hour().minute())
                    if !meeting.attendees.isEmpty {
                        Text("· \(meeting.attendees.count) people")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isRecording {
                Image(systemName: "waveform").foregroundStyle(.green).symbolEffect(.variableColor.iterative)
            } else if meeting.enhancedNotes != nil {
                Image(systemName: "sparkles").foregroundStyle(.secondary).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}
