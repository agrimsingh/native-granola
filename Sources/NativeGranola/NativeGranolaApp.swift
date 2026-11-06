import AppKit
import SwiftUI

struct NativeGranolaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(state)
        } label: {
            MenuBarLabel(recorder: state.recorder)
        }
        .menuBarExtraStyle(.window)

        Window("Native Granola", id: "main") {
            MainWindow()
                .environment(state)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1100, height: 720)

        Settings {
            SettingsView()
                .environment(state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated { DetectionCoordinator.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let recorder = AppState.shared.recorder
        guard recorder.isRecording else { return .terminateNow }
        Task { @MainActor in
            await AppState.shared.stopMeeting()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct MenuBarLabel: View {
    let recorder: GranolaAudioRecorderRef
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if recorder.isRecording {
                Image(systemName: "waveform.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
            } else {
                Image(systemName: "note.text")
            }
        }
        .onAppear {
            DetectionCoordinator.shared.openMainWindow = { showMainWindow(openWindow) }
            showMainWindow(openWindow)
        }
    }
}

/// Brings the app forward and opens the main window, since a menu bar app has no Dock icon.
@MainActor
func showMainWindow(_ openWindow: OpenWindowAction) {
    NSApp.activate()
    openWindow(id: "main")
}
