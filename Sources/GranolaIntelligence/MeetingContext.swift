import Foundation
import GranolaCore

/// Shared formatting for meeting metadata in prompts and exports.
public enum MeetingContext {
    /// Friendly name for the bundle ID of the app that hosted the meeting.
    public static func appName(bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let known: [String: String] = [
            "us.zoom.xos": "Zoom",
            "com.microsoft.teams": "Microsoft Teams",
            "com.microsoft.teams2": "Microsoft Teams",
            "com.tinyspeck.slackmacgap": "Slack",
            "com.apple.FaceTime": "FaceTime",
            "com.cisco.webexmeetingsapp": "Webex",
            "Cisco-Systems.Spark": "Webex",
            "com.hnc.Discord": "Discord",
            "net.whatsapp.WhatsApp": "WhatsApp",
            "com.google.Chrome": "Google Chrome",
            "com.apple.Safari": "Safari",
            "company.thebrowser.Browser": "Arc",
            "org.mozilla.firefox": "Firefox",
            "com.microsoft.edgemac": "Microsoft Edge",
            "com.brave.Browser": "Brave",
            "com.around.Around": "Around",
            "com.loom.desktop": "Loom",
        ]
        if let name = known[bundleID] { return name }
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    static func longDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a zzz"
        return f.string(from: date)
    }

    static func shortDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: date)
    }

    static func attendeeList(_ attendees: [Attendee]) -> String {
        attendees.map { a in
            if let name = a.name, !name.isEmpty, let email = a.email, !email.isEmpty { return "\(name) <\(email)>" }
            return a.displayName
        }.joined(separator: ", ")
    }

    static func durationMinutes(_ meeting: Meeting) -> Int? {
        meeting.duration.map { max(0, Int(($0 / 60).rounded())) }
    }

    /// Context lines (title, date, duration, attendees, app) for prompts.
    static func describe(_ meeting: Meeting, userName: String?, timeZone: TimeZone = .current) -> String {
        var lines = ["Title: \(meeting.title.isEmpty ? "(untitled)" : meeting.title)"]
        lines.append("Date: \(longDate(meeting.startedAt, timeZone: timeZone))")
        if let minutes = durationMinutes(meeting) { lines.append("Duration: \(minutes) minutes") }
        if !meeting.attendees.isEmpty { lines.append("Attendees: \(attendeeList(meeting.attendees))") }
        if let app = appName(bundleID: meeting.sourceApp) { lines.append("App: \(app)") }
        if let userName, !userName.isEmpty { lines.append("The user (\"Me\" in the transcript): \(userName)") }
        return lines.joined(separator: "\n")
    }

    /// Keeps text under `limit` characters by preserving the head and tail and replacing the middle with a marker.
    static func truncateMiddle(_ text: String, limit: Int, noun: String = "transcript") -> String {
        let count = text.count
        guard count > limit, limit > 0 else { return text }
        let headCount = limit / 2
        let tailCount = limit - headCount
        var head = text.prefix(headCount)
        var tail = text.suffix(tailCount)
        if let nl = head.lastIndex(of: "\n"), head.distance(from: nl, to: head.endIndex) < 2000 {
            head = head[..<nl]
        }
        if let nl = tail.firstIndex(of: "\n"), tail.distance(from: tail.startIndex, to: nl) < 2000 {
            tail = tail[tail.index(after: nl)...]
        }
        let omitted = count - head.count - tail.count
        return "\(head)\n\n[… \(noun) truncated: \(omitted) characters omitted from the middle …]\n\n\(tail)"
    }

    static func stripCodeFence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("```"), s.hasSuffix("```"), s.count >= 6 else { return s }
        s = String(s.dropLast(3))
        if let nl = s.firstIndex(of: "\n") {
            s = String(s[s.index(after: nl)...])
        } else {
            s = String(s.dropFirst(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
