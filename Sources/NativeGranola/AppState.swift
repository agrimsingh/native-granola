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
        recorder.onWarning = { [weak self] in self?.lastError = $0 }
        endUnfinishedMeetings()
        refresh()
        selectedMeetingID = meetings.first?.id
        NotificationCenter.default.addObserver(forName: Store.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        SystemEvents.shared.start(state: self)
        let retention = Preferences.audioRetentionDays
        Task.detached(priority: .background) { AudioArchive.prune(olderThanDays: retention) }
    }

    /// Meetings left in progress by a crash or a kill end where their transcript does.
    private func endUnfinishedMeetings() {
        let unfinished = (try? store.unfinishedMeetings()) ?? []
        for var meeting in unfinished where meeting.id != recorder.meeting?.id {
            let segments = (try? store.segments(meetingID: meeting.id)) ?? []
            meeting.endedAt = RecordingPolicy.recoveredEnd(of: meeting, segments: segments)
            save(meeting)
            log.info("Ended meeting \(meeting.id, privacy: .public) left unfinished by the last run")
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
        if Preferences.systemAudioScope == .app, let sourceApp { options.systemAudioScope = .app(bundleID: sourceApp) }
        if Preferences.keepAudio { options.audioArchiveRoot = AudioArchive.root }
        let vocabulary = attendees.compactMap(\.name) + Preferences.customVocabulary
        lastError = nil
        await recorder.start(meeting, options: options, vocabulary: vocabulary)
        if case let .failed(message) = recorder.state { lastError = message }
        if let warning = recorder.warnings.first { lastError = warning }
        DetectionCoordinator.shared.recordingChanged(recorder.isRecording)
        refresh()
    }

    func stopMeeting(endedAt: Date? = nil) async {
        guard recorder.isRecording, let meeting = await recorder.stop(endedAt: endedAt) else { return }
        DetectionCoordinator.shared.recordingChanged(false)
        refresh()
        await afterMeetingEnded(meeting)
    }

    /// Runs once the recorder has stopped and the meeting's audio files are closed.
    func afterMeetingEnded(_ meeting: Meeting) async {
        if AudioArchive.hasAudio(meetingID: meeting.id) { await meetingAudioReady(meeting) }
        await postProcess(meeting)
    }

    /// The meeting's audio is complete at `AudioArchive.url(meetingID:source:)`: 16 kHz mono Float32,
    /// sample 0 at `meeting.startedAt`, both files padded to the meeting's end. Post-meeting audio
    /// processing (re-transcription, speaker separation) hooks in here, before notes are generated.
    func meetingAudioReady(_ meeting: Meeting) async {}

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
        AudioArchive.delete(meetingID: meeting.id)
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

    enum SystemAudioScope: String, CaseIterable {
        /// Only the app the meeting was detected in, falling back to everything if that fails.
        case app
        case all
    }

    static var systemAudioScope: SystemAudioScope {
        get { defaults.string(forKey: "systemAudioScope").flatMap(SystemAudioScope.init) ?? .app }
        set { defaults.set(newValue.rawValue, forKey: "systemAudioScope") }
    }

    /// Keep each meeting's audio for post-meeting processing.
    static var keepAudio: Bool {
        get { defaults.object(forKey: "keepAudio") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepAudio") }
    }

    /// Saved audio older than this is deleted on launch; 0 keeps it forever.
    static var audioRetentionDays: Int {
        get { defaults.object(forKey: "audioRetentionDays") as? Int ?? 7 }
        set { defaults.set(newValue, forKey: "audioRetentionDays") }
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
