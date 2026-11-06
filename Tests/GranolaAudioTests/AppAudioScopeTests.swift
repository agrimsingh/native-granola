import Testing
@testable import GranolaAudio

@Suite struct AppAudioMatcherTests {
    func process(_ bundleID: String?, pid: Int32 = 500, responsible: Int32? = nil, parent: Int32? = nil) -> AudioClientProcess {
        AudioClientProcess(objectID: 1, pid: pid, bundleID: bundleID, responsiblePID: responsible, parentPID: parent)
    }

    @Test func helpersMatchByBundlePrefix() {
        #expect(AppAudioMatcher.matches(bundleID: "com.google.Chrome", target: "com.google.Chrome"))
        #expect(AppAudioMatcher.matches(bundleID: "com.google.Chrome.helper", target: "com.google.Chrome"))
        #expect(AppAudioMatcher.matches(bundleID: "com.google.Chrome.helper.renderer", target: "com.google.chrome"))
        #expect(AppAudioMatcher.matches(bundleID: "com.microsoft.teams2.helper", target: "com.microsoft.teams2"))
        #expect(AppAudioMatcher.matches(bundleID: "com.tinyspeck.slackmacgap.helper", target: "com.tinyspeck.slackmacgap"))
    }

    @Test func siblingAppsAndLookalikesDontMatch() {
        #expect(!AppAudioMatcher.matches(bundleID: "com.google.Chrome.canary", target: "com.google.Chrome"))
        #expect(!AppAudioMatcher.matches(bundleID: "com.google.Chrome.beta.helper", target: "com.google.Chrome"))
        #expect(!AppAudioMatcher.matches(bundleID: "com.google.ChromeRemoteDesktop", target: "com.google.Chrome"))
        #expect(!AppAudioMatcher.matches(bundleID: "com.microsoft.teams2", target: "com.microsoft.teams"))
        #expect(!AppAudioMatcher.matches(bundleID: "com.apple.Music", target: "com.google.Chrome"))
    }

    @Test func familiesCoverHelpersWithOtherPrefixes() {
        #expect(AppAudioMatcher.matches(bundleID: "us.zoom.CptHost", target: "us.zoom.xos"))
        #expect(AppAudioMatcher.matches(bundleID: "com.apple.avconferenced", target: "com.apple.FaceTime"))
        #expect(AppAudioMatcher.matches(bundleID: "com.webex.meetingmanager", target: "com.cisco.webexmeetingsapp"))
    }

    @Test func unbundledAndSharedProcessesMatchThroughTheApp() {
        let app: Set<Int32> = [100]
        #expect(AppAudioMatcher.matches(process("com.apple.WebKit.GPU", responsible: 100), target: "com.apple.Safari", appPIDs: app))
        #expect(!AppAudioMatcher.matches(process("com.apple.WebKit.GPU", responsible: 200), target: "com.apple.Safari", appPIDs: app))
        #expect(AppAudioMatcher.matches(process(nil, parent: 100), target: "com.example.app", appPIDs: app))
        #expect(AppAudioMatcher.matches(process(nil, pid: 100), target: "com.example.app", appPIDs: app))
        #expect(!AppAudioMatcher.matches(process(nil), target: "com.example.app", appPIDs: app))
    }
}

@Suite struct AppTapMonitorTests {
    @Test func fallsBackWhenOthersPlayAndTheAppNeverHas() {
        var monitor = AppTapMonitor(grace: 10)
        #expect(monitor.observe(at: 0, matched: 2, targetPlaying: false, othersPlaying: true) == .keep)
        #expect(monitor.observe(at: 9, matched: 2, targetPlaying: false, othersPlaying: true) == .keep)
        #expect(monitor.observe(at: 10, matched: 2, targetPlaying: false, othersPlaying: true) == .fallBack(.appSilent))
    }

    @Test func reportsAppNotFoundWhenNothingMatched() {
        var monitor = AppTapMonitor(grace: 5)
        _ = monitor.observe(at: 0, matched: 0, targetPlaying: false, othersPlaying: true)
        #expect(monitor.observe(at: 6, matched: 0, targetPlaying: false, othersPlaying: true) == .fallBack(.appNotFound))
    }

    @Test func silenceEverywhereKeepsTheAppScope() {
        var monitor = AppTapMonitor(grace: 5)
        for t in stride(from: 0.0, through: 60, by: 1) {
            #expect(monitor.observe(at: t, matched: 0, targetPlaying: false, othersPlaying: false) == .keep)
        }
    }

    @Test func onceTheAppHasPlayedItNeverFallsBack() {
        var monitor = AppTapMonitor(grace: 5)
        _ = monitor.observe(at: 0, matched: 1, targetPlaying: true, othersPlaying: false)
        for t in stride(from: 1.0, through: 120, by: 1) {
            #expect(monitor.observe(at: t, matched: 1, targetPlaying: false, othersPlaying: true) == .keep)
        }
    }

    @Test func interruptedMismatchRestartsTheGracePeriod() {
        var monitor = AppTapMonitor(grace: 10)
        _ = monitor.observe(at: 0, matched: 1, targetPlaying: false, othersPlaying: true)
        _ = monitor.observe(at: 8, matched: 1, targetPlaying: false, othersPlaying: false)
        #expect(monitor.observe(at: 12, matched: 1, targetPlaying: false, othersPlaying: true) == .keep)
        #expect(monitor.observe(at: 22, matched: 1, targetPlaying: false, othersPlaying: true) == .fallBack(.appSilent))
    }
}
