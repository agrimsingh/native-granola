import Foundation
import GranolaAudio
import GranolaCore
import Observation
import os

@MainActor @Observable
final class AppState {
    static let shared = AppState()

    let store: Store
    let recorder: MeetingRecorder
    var meetings: [Meeting] = []
    var selectedMeetingID: String?
    var searchText = ""
    var searchHits: [SearchHit] = []
    var lastError: String?
    var enhancing: Set<String> = []
    var exporting: Set<String> = []
    /// Notes being streamed in from the model, keyed by meeting ID.
    var streamingNotes: [String: String] = [:]

    @ObservationIgnored private let log = Logger(subsystem: "com.nativegranola", category: "app")
    @ObservationIgnored private var refreshScheduled = false

    private init() {
        do {
            store = try Store()
        } catch {
            fatalError("Could not open the database at \(Store.defaultURL.path): \(error)")
        }
        recorder = MeetingRecorder(store: store)
        refresh()
        selectedMeetingID = meetings.first?.id
        NotificationCenter.default.addObserver(forName: Store.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
    }

    var currentMeeting: Meeting? { recorder.meeting.flatMap { recorder.isRecording ? $0 : nil } }

    var selectedMeeting: Meeting? {
        guard let id = selectedMeetingID else { return nil }
        if recorder.meeting?.id == id { return recorder.meeting }
        return meetings.first { $0.id == id } ?? (try? store.meeting(id: id))
    }

    // MARK: Recording

    func startMeeting(title: String? = nil, attendees: [Attendee] = [], calendarEventID: String? = nil,
                      sourceApp: String? = nil) async {
        guard !recorder.isRecording else { return }
        let meeting = Meeting(
            title: title ?? "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))",
            calendarEventID: calendarEventID, attendees: attendees, sourceApp: sourceApp)
        selectedMeetingID = meeting.id
        var options = MeetingRecorder.Options()
        options.echoCancellation = Preferences.echoCancellation
        let vocabulary = attendees.compactMap(\.name) + Preferences.customVocabulary
        lastError = nil
        await recorder.start(meeting, options: options, vocabulary: vocabulary)
        if case let .failed(message) = recorder.state { lastError = message }
        if let warning = recorder.warnings.first { lastError = warning }
        DetectionCoordinator.shared.recordingChanged(recorder.isRecording)
        refresh()
    }

    func stopMeeting() async {
        guard recorder.isRecording, let meeting = await recorder.stop() else { return }
        DetectionCoordinator.shared.recordingChanged(false)
        refresh()
        await afterMeetingEnded(meeting)
    }

    func afterMeetingEnded(_ meeting: Meeting) async {
        await postProcess(meeting)
    }

    // MARK: Editing

    func update(_ meeting: Meeting) {
        if recorder.meeting?.id == meeting.id {
            recorder.updateTitle(meeting.title)
            recorder.updateNotes(meeting.rawNotes)
        } else {
            save(meeting)
        }
    }

    func save(_ meeting: Meeting) {
        do { try store.upsertMeeting(meeting) } catch { report(error) }
    }

    func delete(_ meeting: Meeting) {
        guard recorder.meeting?.id != meeting.id || !recorder.isRecording else { return }
        do { try store.deleteMeeting(id: meeting.id) } catch { report(error) }
        if selectedMeetingID == meeting.id { selectedMeetingID = nil }
    }

    func segments(for meeting: Meeting) -> [TranscriptSegment] {
        if recorder.meeting?.id == meeting.id, recorder.isRecording { return recorder.segments }
        return (try? store.segments(meetingID: meeting.id)) ?? []
    }

    // MARK: Lists

    func runSearch() {
        searchHits = searchText.trimmingCharacters(in: .whitespaces).isEmpty ? [] : ((try? store.search(searchText)) ?? [])
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    func refresh() {
        do { meetings = try store.listMeetings(limit: 500) } catch { report(error) }
        if !searchText.isEmpty { runSearch() }
    }

    func report(_ error: Error) {
        log.error("\(String(describing: error))")
        lastError = String(describing: error)
    }
}

enum Preferences {
    private static let defaults = UserDefaults.standard

    static var echoCancellation: Bool {
        get { defaults.object(forKey: "echoCancellation") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "echoCancellation") }
    }

    static var customVocabulary: [String] {
        get { defaults.stringArray(forKey: "customVocabulary") ?? [] }
        set { defaults.set(newValue, forKey: "customVocabulary") }
    }

    static var userName: String {
        get { defaults.string(forKey: "userName") ?? NSFullUserName() }
        set { defaults.set(newValue, forKey: "userName") }
    }

    static var autoStop: Bool {
        get { defaults.object(forKey: "autoStop") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoStop") }
    }

    /// ~5s for a meeting's notes, versus ~45s for grok-4.7 at similar quality.
    static let defaultModel = "grok-4.20-0309-non-reasoning"

    static var model: String {
        get { defaults.string(forKey: "xaiModel") ?? defaultModel }
        set { defaults.set(newValue, forKey: "xaiModel") }
    }

    static var autoEnhance: Bool {
        get { defaults.object(forKey: "autoEnhance") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoEnhance") }
    }

    static var defaultTemplateID: String {
        get { defaults.string(forKey: "defaultTemplateID") ?? "general" }
        set { defaults.set(newValue, forKey: "defaultTemplateID") }
    }

    static let notionDatabaseTitle = "Meeting Notes"

    static var notionParentPage: String {
        get { defaults.string(forKey: "notionParentPage") ?? "" }
        set { defaults.set(newValue, forKey: "notionParentPage") }
    }

    static var notionDatabaseID: String {
        get { defaults.string(forKey: "notionDatabaseID") ?? "" }
        set { defaults.set(newValue, forKey: "notionDatabaseID") }
    }
}
