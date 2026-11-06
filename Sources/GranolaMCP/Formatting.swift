import Foundation
import GranolaCore

/// A tool failure reported to the model as an `isError` result rather than a protocol error.
struct ToolError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

/// Date/duration display and date-input parsing in a fixed time zone.
final class Formatting {
    let timeZone: TimeZone
    private let calendar: Calendar
    private let display: DateFormatter
    private let dayOnly: DateFormatter
    private let localDateTimes: [DateFormatter]
    private let iso = ISO8601DateFormatter()
    private let isoFractional = ISO8601DateFormatter()

    init(timeZone: TimeZone) {
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar

        func formatter(_ pattern: String) -> DateFormatter {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = calendar
            f.timeZone = timeZone
            f.dateFormat = pattern
            f.isLenient = false
            return f
        }
        display = formatter("EEE yyyy-MM-dd HH:mm zzz")
        dayOnly = formatter("yyyy-MM-dd")
        localDateTimes = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"]
            .map(formatter)
        iso.formatOptions = [.withInternetDateTime]
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    /// e.g. "Sat 2026-11-07 14:30 GMT+8"
    func date(_ date: Date) -> String { display.string(from: date) }

    /// e.g. "45s", "32m", "1h 05m"
    func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
    }

    func duration(of meeting: Meeting) -> String {
        meeting.duration.map(duration) ?? "in progress"
    }

    /// Accepts ISO 8601 datetimes (with zone, or zone-less = local), or YYYY-MM-DD (local day).
    /// For a bare day, `endOfDay` returns the last instant of that day so ranges are inclusive.
    func parseDate(_ text: String, endOfDay: Bool) -> Date? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count == 10, let day = dayOnly.date(from: text) {
            let start = calendar.startOfDay(for: day)
            guard endOfDay else { return start }
            return calendar.date(byAdding: .day, value: 1, to: start).map { $0.addingTimeInterval(-0.001) }
        }
        if let d = isoFractional.date(from: text) ?? iso.date(from: text) { return d }
        for f in localDateTimes {
            if let d = f.date(from: text) { return d }
        }
        return nil
    }

    func attendees(_ attendees: [Attendee]) -> String {
        guard !attendees.isEmpty else { return "none recorded" }
        return attendees.map { a in
            if let name = a.name, let email = a.email { return "\(name) <\(email)>" }
            return a.displayName
        }.joined(separator: ", ")
    }

    func sourceApp(_ bundleID: String) -> String {
        Self.knownApps[bundleID].map { "\($0) (\(bundleID))" } ?? bundleID
    }

    private static let knownApps = [
        "us.zoom.xos": "Zoom",
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.apple.FaceTime": "FaceTime",
        "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.hnc.Discord": "Discord",
        "com.google.Chrome": "Google Chrome",
        "com.apple.Safari": "Safari",
        "company.thebrowser.Browser": "Arc",
        "org.mozilla.firefox": "Firefox",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "Brave",
    ]
}

/// Lenient accessors for tool arguments: models sometimes send numbers as strings and vice versa.
struct Arguments {
    let raw: [String: Any]
    let format: Formatting

    init(_ raw: [String: Any], format: Formatting) {
        self.raw = raw
        self.format = format
    }

    private func value(_ key: String) -> Any? {
        guard let v = raw[key], !(v is NSNull) else { return nil }
        return v
    }

    func string(_ key: String) throws -> String? {
        switch value(key) {
        case nil: return nil
        case let s as String: return s
        case let n as NSNumber where !n.isBool: return n.stringValue
        default: throw ToolError("'\(key)' must be a string.")
        }
    }

    func requiredString(_ key: String) throws -> String {
        let s = try string(key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !s.isEmpty else { throw ToolError("Missing required argument '\(key)'.") }
        return s
    }

    /// Clamped into `range` rather than rejected, so slightly-off model input still works.
    func int(_ key: String, default defaultValue: Int, range: ClosedRange<Int>) throws -> Int {
        let parsed: Int
        switch value(key) {
        case nil:
            return defaultValue
        case let n as NSNumber where !n.isBool && n.doubleValue.isFinite:
            parsed = Int(max(-1e9, min(1e9, n.doubleValue.rounded())))
        case let s as String:
            guard let i = Int(s.trimmingCharacters(in: .whitespaces)) else { throw ToolError("'\(key)' must be an integer.") }
            parsed = i
        default:
            throw ToolError("'\(key)' must be an integer.")
        }
        return min(max(parsed, range.lowerBound), range.upperBound)
    }

    func bool(_ key: String, default defaultValue: Bool) throws -> Bool {
        switch value(key) {
        case nil: return defaultValue
        case let n as NSNumber: return n.boolValue
        case let s as String:
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: throw ToolError("'\(key)' must be a boolean.")
            }
        default: throw ToolError("'\(key)' must be a boolean.")
        }
    }

    func date(_ key: String, endOfDay: Bool) throws -> Date? {
        guard let s = try string(key), !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let d = format.parseDate(s, endOfDay: endOfDay) else {
            throw ToolError("'\(key)' must be an ISO 8601 datetime (e.g. 2026-11-07T14:30:00Z) or a date (YYYY-MM-DD); got \"\(s)\".")
        }
        return d
    }
}

extension NSNumber {
    var isBool: Bool { CFGetTypeID(self) == CFBooleanGetTypeID() }
}
