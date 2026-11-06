import Foundation

/// A Core Audio client process, as seen when deciding which processes belong to the meeting app.
public struct AudioClientProcess: Sendable, Hashable {
    public var objectID: UInt32
    public var pid: Int32
    public var bundleID: String?
    /// The process macOS holds responsible for this one: the app, for XPC services such as WebKit's GPU process.
    public var responsiblePID: Int32?
    public var parentPID: Int32?
    public var isRunningOutput: Bool

    public init(objectID: UInt32, pid: Int32, bundleID: String?, responsiblePID: Int32? = nil,
                parentPID: Int32? = nil, isRunningOutput: Bool = false) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.responsiblePID = responsiblePID
        self.parentPID = parentPID
        self.isRunningOutput = isRunningOutput
    }
}

/// Decides which audio processes play a meeting app's audio. Apps rarely play from their main
/// process: Chrome uses an audio-service helper, Zoom and Teams have their own helpers, and WebKit
/// apps play through the shared GPU process, which is attributed back to the app as its responsible process.
public enum AppAudioMatcher {
    /// Lowercased bundle ID -> lowercased bundle ID prefixes of related processes that don't share its prefix.
    static let families: [String: [String]] = [
        "us.zoom.xos": ["us.zoom."],
        "com.apple.facetime": ["com.apple.avconferenced"],
        "com.cisco.webexmeetingsapp": ["com.webex.", "com.cisco.webex"],
        "cisco-systems.spark": ["com.webex.", "com.cisco.webex"],
        "org.mozilla.firefox": ["org.mozilla.plugincontainer"],
    ]

    /// Suffixes that make a different app rather than a helper, e.g. `com.google.Chrome.canary`.
    static let siblingSuffixes: Set<String> = ["beta", "dev", "canary", "nightly"]

    public static func matches(bundleID: String, target: String) -> Bool {
        let id = bundleID.lowercased(), app = target.lowercased()
        if id == app { return true }
        if id.hasPrefix(app + ".") {
            let next = id.dropFirst(app.count + 1).split(separator: ".").first.map(String.init) ?? ""
            return !siblingSuffixes.contains(next)
        }
        return families[app]?.contains { id.hasPrefix($0) } ?? false
    }

    /// `appPIDs` are the PIDs of the target app's running instances.
    public static func matches(_ process: AudioClientProcess, target: String, appPIDs: Set<Int32>) -> Bool {
        if let id = process.bundleID, matches(bundleID: id, target: target) { return true }
        if appPIDs.contains(process.pid) { return true }
        if let pid = process.responsiblePID, appPIDs.contains(pid) { return true }
        if let pid = process.parentPID, appPIDs.contains(pid) { return true }
        return false
    }
}

/// Decides when an app-scoped tap should give up and record all system audio: when other apps are
/// playing while the meeting app has never played anything since the tap started, its audio is
/// evidently coming from a process that wasn't matched. Once the app has played, later silence is
/// just a quiet meeting (or one that ended) and never triggers a fallback.
public struct AppTapMonitor: Sendable {
    public enum Reason: Equatable, Sendable {
        /// No process of the app is connected to audio at all.
        case appNotFound
        /// The app's processes exist but haven't played anything.
        case appSilent
    }

    public enum Verdict: Equatable, Sendable {
        case keep
        case fallBack(Reason)
    }

    public var grace: TimeInterval
    public private(set) var targetHasPlayed = false
    private var mismatchSince: TimeInterval?

    public init(grace: TimeInterval = 15) {
        self.grace = grace
    }

    public mutating func observe(at time: TimeInterval, matched: Int, targetPlaying: Bool, othersPlaying: Bool) -> Verdict {
        if targetPlaying { targetHasPlayed = true }
        guard !targetHasPlayed, othersPlaying else {
            mismatchSince = nil
            return .keep
        }
        let since = mismatchSince ?? time
        mismatchSince = since
        guard time - since >= grace else { return .keep }
        return .fallBack(matched == 0 ? .appNotFound : .appSilent)
    }
}
