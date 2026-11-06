import AppKit
import GranolaAudio

/// Pauses recording while the Mac sleeps, and on wake either resumes it or, if the sleep was long
/// or the meeting app has quit, ends the meeting at the moment the Mac went to sleep.
@MainActor
final class SystemEvents {
    static let shared = SystemEvents()

    private weak var state: AppState?
    private var observers: [NSObjectProtocol] = []
    private var sleptAt: Date?

    private init() {}

    func start(state: AppState) {
        guard observers.isEmpty else { return }
        self.state = state
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didWake() }
            },
        ]
    }

    private func willSleep() {
        guard let recorder = state?.recorder, recorder.isRecording, !recorder.isSuspended else { return }
        sleptAt = Date()
        Task { await recorder.suspend() }
    }

    private func didWake() {
        guard let state, let sleptAt else { return }
        self.sleptAt = nil
        guard state.recorder.isRecording else { return }
        let appRunning = state.recorder.meeting?.sourceApp.map {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
        } ?? true
        if RecordingPolicy.shouldResume(afterSleeping: Date().timeIntervalSince(sleptAt), sourceAppRunning: appRunning) {
            Task { await state.recorder.resume() }
        } else {
            Task { await state.stopMeeting(endedAt: sleptAt) }
        }
    }
}
