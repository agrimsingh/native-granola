import Foundation
import Testing
@testable import GranolaDetection

@Suite struct AppIdentityTests {
    @Test(arguments: [
        ("com.google.Chrome.helper", "com.google.Chrome"),
        ("com.google.Chrome.helper.renderer", "com.google.Chrome"),
        ("com.google.chrome.helper", "com.google.Chrome"),
        ("com.microsoft.edgemac.helper", "com.microsoft.edgemac"),
        ("company.thebrowser.Browser.helper", "company.thebrowser.Browser"),
        ("com.brave.Browser.helper", "com.brave.Browser"),
        ("org.mozilla.firefox", "org.mozilla.firefox"),
        ("org.mozilla.plugincontainer", "org.mozilla.firefox"),
        ("com.apple.WebKit.GPU", "com.apple.Safari"),
        ("com.apple.WebKit.WebContent", "com.apple.Safari"),
        ("com.tinyspeck.slackmacgap.helper", "com.tinyspeck.slackmacgap"),
        ("com.hnc.Discord.helper.Renderer", "com.hnc.Discord"),
        ("us.zoom.CptHost", "us.zoom.xos"),
        ("us.zoom.xos", "us.zoom.xos"),
        ("com.apple.avconferenced", "com.apple.FaceTime"),
        ("com.webex.meetingmanager", "com.cisco.webexmeetingsapp"),
        ("com.example.SomeApp", "com.example.SomeApp"),
    ])
    func normalization(raw: String, expected: String) {
        #expect(AppIdentity.normalizedBundleID(raw) == expected)
    }

    @Test(arguments: [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.FaceTime", "FaceTime"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("desktop.WhatsApp", "WhatsApp"),
        ("com.hnc.Discord", "Discord"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("com.google.Chrome.helper", "Google Chrome"),
        ("com.microsoft.edgemac.helper", "Microsoft Edge"),
        ("company.thebrowser.Browser.helper", "Arc"),
        ("com.brave.Browser.helper", "Brave"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.apple.WebKit.GPU", "Safari"),
    ])
    func friendlyNames(bundleID: String, name: String) {
        #expect(AppIdentity.friendlyName(forBundleID: bundleID) == name)
    }

    @Test func unknownAppHasNoFriendlyName() {
        #expect(AppIdentity.friendlyName(forBundleID: "com.example.SomeApp") == nil)
    }

    @Test(arguments: [
        ("com.tinyspeck.slackmacgap", "Huddle detected"),
        ("com.tinyspeck.slackmacgap.helper", "Huddle detected"),
        ("com.apple.FaceTime", "Call detected"),
        ("com.apple.avconferenced", "Call detected"),
        ("net.whatsapp.WhatsApp", "Call detected"),
        ("desktop.WhatsApp", "Call detected"),
        ("us.zoom.xos", "Meeting detected"),
        ("com.microsoft.teams2", "Meeting detected"),
        ("com.google.Chrome", "Meeting detected"),
        ("com.example.SomeApp", "Meeting detected"),
    ])
    func promptTitles(bundleID: String, title: String) {
        #expect(AppIdentity.promptTitle(forBundleID: bundleID) == title)
    }

    @Test func systemServices() {
        for id in ["com.apple.corespeechd", "com.apple.CoreSpeech", "com.apple.SpeechRecognitionCore.speechrecognitiond",
                   "com.apple.siri.embeddedspeech", "com.apple.assistantd", "com.apple.DictationIM", "corespeechd"] {
            #expect(AppIdentity.isSystemService(id), "\(id)")
        }
        for id in ["com.apple.FaceTime", "com.apple.avconferenced", "us.zoom.xos", "com.google.Chrome.helper", "com.apple.Safari"] {
            #expect(!AppIdentity.isSystemService(id), "\(id)")
        }
    }

    @Test func browserAndMeetingAppClassification() {
        #expect(AppIdentity.isBrowser("com.google.Chrome.helper"))
        #expect(!AppIdentity.isBrowser("us.zoom.xos"))
        #expect(AppIdentity.isKnownMeetingApp("us.zoom.xos"))
        #expect(!AppIdentity.isKnownMeetingApp("com.google.Chrome"))
        #expect(!AppIdentity.isKnownMeetingApp("com.example.SomeApp"))
    }
}

@Suite struct MicAppResolverTests {
    @Test func filtersNormalizesAndMergesHelpers() {
        let processes = [
            AudioProcessSnapshot(pid: 10, bundleID: "com.google.Chrome", isRunningInput: false, isRunningOutput: true),
            AudioProcessSnapshot(pid: 11, bundleID: "com.google.Chrome.helper", isRunningInput: true),
            AudioProcessSnapshot(pid: 12, bundleID: "com.google.Chrome.helper.renderer", isRunningInput: true),
            AudioProcessSnapshot(pid: 20, bundleID: "us.zoom.xos", isRunningInput: true),
            AudioProcessSnapshot(pid: 21, bundleID: "us.zoom.CptHost", isRunningInput: true),
            AudioProcessSnapshot(pid: 30, bundleID: "com.apple.corespeechd", isRunningInput: true),
            AudioProcessSnapshot(pid: 31, bundleID: nil, processName: "corespeechd", isRunningInput: true),
            AudioProcessSnapshot(pid: 40, bundleID: "com.native.granola", isRunningInput: true),
            AudioProcessSnapshot(pid: 99, bundleID: "com.example.Ours", isRunningInput: true),
            AudioProcessSnapshot(pid: 50, bundleID: "com.example.Recorder", isRunningInput: true),
            AudioProcessSnapshot(pid: 60, bundleID: "", processName: "sox", isRunningInput: true),
            AudioProcessSnapshot(pid: 70, bundleID: "com.apple.Music", isRunningInput: false, isRunningOutput: true),
        ]
        let apps = MicAppResolver.resolve(
            processes,
            ownPID: 99,
            excludedBundleIDs: ["com.native.granola"],
            nameLookup: { id, _ in id == "com.example.Recorder" ? "Recorder" : nil }
        )
        #expect(apps == [
            MicApp(bundleID: "com.google.Chrome", name: "Google Chrome", pid: 11),
            MicApp(bundleID: "com.example.Recorder", name: "Recorder", pid: 50),
            MicApp(bundleID: "sox", name: "sox", pid: 60),
            MicApp(bundleID: "us.zoom.xos", name: "Zoom", pid: 20),
        ])
    }

    @Test func faceTimeCaptureDaemonCountsAsFaceTime() {
        let apps = MicAppResolver.resolve(
            [AudioProcessSnapshot(pid: 5, bundleID: "com.apple.avconferenced", isRunningInput: true)],
            ownPID: 1
        )
        #expect(apps == [MicApp(bundleID: "com.apple.FaceTime", name: "FaceTime", pid: 5)])
    }
}

@Suite struct MicActivitySmokeTests {
    /// Prints the live Core Audio process list. Run with GRANOLA_MIC_SMOKE=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRANOLA_MIC_SMOKE"] != nil))
    func printLiveMicApps() {
        let processes = MicActivityMonitor.audioProcesses()
        print("[smoke] \(processes.count) Core Audio process objects")
        for p in processes where p.isRunningInput || p.isRunningOutput {
            print("[smoke]   pid=\(p.pid) bundle=\(p.bundleID ?? "-") name=\(p.processName ?? "-") input=\(p.isRunningInput) output=\(p.isRunningOutput)")
        }
        let apps = MicActivityMonitor.currentMicApps()
        print("[smoke] mic apps: \(apps.isEmpty ? "(none)" : apps.map { "\($0.name) [\($0.bundleID) pid \($0.pid)]" }.joined(separator: ", "))")
    }
}
