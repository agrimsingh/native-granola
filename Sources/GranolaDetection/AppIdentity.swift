import Foundation

/// An app currently capturing microphone input, normalized to its user-facing parent app
/// (e.g. Chrome's audio helper process is reported as Google Chrome).
public struct MicApp: Codable, Sendable, Hashable, Identifiable {
    /// Normalized bundle ID (e.g. `com.google.Chrome`), or the executable name for unbundled processes.
    public var bundleID: String
    public var name: String
    /// PID of the parent app if it captures itself, otherwise of the helper process doing the capture.
    public var pid: Int32

    public init(bundleID: String, name: String, pid: Int32 = 0) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
    }

    public var id: String { bundleID }
}

/// Bundle ID normalization, friendly names and prompt wording for known meeting apps and browsers.
public enum AppIdentity {
    public static let friendlyNames: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.apple.FaceTime": "FaceTime",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "desktop.WhatsApp": "WhatsApp",
        "com.hnc.Discord": "Discord",
        "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.skype.skype": "Skype",
        "ru.keepcoder.Telegram": "Telegram",
        "org.telegram.desktop": "Telegram",
        "org.whispersystems.signal-desktop": "Signal",
        "com.amazon.Amazon-Chime": "Amazon Chime",
        "com.google.Chrome": "Google Chrome",
        "com.google.Chrome.beta": "Google Chrome Beta",
        "com.google.Chrome.dev": "Google Chrome Dev",
        "com.google.Chrome.canary": "Google Chrome Canary",
        "org.chromium.Chromium": "Chromium",
        "com.microsoft.edgemac": "Microsoft Edge",
        "company.thebrowser.Browser": "Arc",
        "company.thebrowser.dia": "Dia",
        "com.brave.Browser": "Brave",
        "org.mozilla.firefox": "Firefox",
        "com.apple.Safari": "Safari",
        "com.operasoftware.Opera": "Opera",
        "com.vivaldi.Vivaldi": "Vivaldi",
        "app.zen-browser.zen": "Zen",
    ]

    public static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.brave.Browser", "org.mozilla.firefox", "com.apple.Safari", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi", "app.zen-browser.zen",
    ]

    static let huddleBundleIDs: Set<String> = ["com.tinyspeck.slackmacgap"]

    static let callBundleIDs: Set<String> = [
        "com.apple.FaceTime", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "ru.keepcoder.Telegram", "org.telegram.desktop", "org.whispersystems.signal-desktop",
    ]

    /// Lowercased raw ID -> canonical parent bundle ID, for helpers that don't follow the `.helper` suffix convention.
    private static let aliases: [String: String] = [
        "com.apple.avconferenced": "com.apple.FaceTime",
        "org.mozilla.plugincontainer": "org.mozilla.firefox",
        "com.webex.meetingmanager": "com.cisco.webexmeetingsapp",
    ]

    private static let canonicalByLowercase: [String: String] = Dictionary(
        friendlyNames.keys.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a }
    )

    /// Lowercased bundle ID prefixes of system services that use the mic but aren't meetings
    /// (Siri, dictation, speech recognition, sound recognition, Core Audio itself, Voice Memos, screen recording).
    private static let systemPrefixes: [String] = [
        "com.apple.corespeech", "com.apple.speechrecognitioncore", "com.apple.speech", "com.apple.siri",
        "com.apple.assistant", "com.apple.dictation", "com.apple.accessibility", "com.apple.audio.",
        "com.apple.coreaudiod", "com.apple.voicememos", "com.apple.screencaptureui", "com.apple.controlcenter",
        "com.apple.voicebanking", "com.apple.hearing",
    ]

    /// Lowercased executable names of unbundled system daemons.
    private static let systemProcessNames: Set<String> = [
        "corespeechd", "coreaudiod", "assistantd", "siriactionsd", "heard", "localspeechrecognition",
        "speechrecognitioncore", "dictationim", "voicememod", "audiomxd", "systemsoundserverd",
    ]

    /// Maps a helper/child process bundle ID to its user-facing parent app's bundle ID.
    public static func normalizedBundleID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if let alias = aliases[lower] { return alias }
        if let canonical = canonicalByLowercase[lower] { return canonical }
        if lower.hasPrefix("com.apple.webkit.") { return "com.apple.Safari" }
        if lower.hasPrefix("us.zoom.") { return "us.zoom.xos" }
        if let range = trimmed.range(of: #"\.helper(\..*)?$"#, options: [.regularExpression, .caseInsensitive]) {
            return normalizedBundleID(String(trimmed[..<range.lowerBound]))
        }
        return trimmed
    }

    public static func friendlyName(forBundleID bundleID: String) -> String? {
        friendlyNames[normalizedBundleID(bundleID)]
    }

    /// True for system services that capture the mic but aren't meetings. Matches raw (un-normalized) IDs and names.
    public static func isSystemService(_ bundleIDOrName: String) -> Bool {
        let lower = bundleIDOrName.lowercased()
        if systemProcessNames.contains(lower) { return true }
        // FaceTime's capture daemon counts as FaceTime, not as a system service.
        if aliases[lower] != nil { return false }
        return systemPrefixes.contains { lower.hasPrefix($0) }
    }

    public static func isBrowser(_ bundleID: String) -> Bool {
        browserBundleIDs.contains(normalizedBundleID(bundleID))
    }

    /// Dedicated meeting/call apps (not browsers).
    public static func isKnownMeetingApp(_ bundleID: String) -> Bool {
        let id = normalizedBundleID(bundleID)
        return friendlyNames[id] != nil && !browserBundleIDs.contains(id)
    }

    /// "Huddle detected" for Slack, "Call detected" for FaceTime/WhatsApp-style calling apps, else "Meeting detected".
    public static func promptTitle(forBundleID bundleID: String) -> String {
        let noun = meetingNoun(forBundleID: bundleID)
        return noun.prefix(1).uppercased() + noun.dropFirst() + " detected"
    }

    /// "huddle", "call" or "meeting".
    public static func meetingNoun(forBundleID bundleID: String) -> String {
        let id = normalizedBundleID(bundleID)
        if huddleBundleIDs.contains(id) { return "huddle" }
        if callBundleIDs.contains(id) { return "call" }
        return "meeting"
    }
}
