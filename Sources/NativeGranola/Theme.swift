import AppKit
import GranolaCore
import SwiftUI

enum Theme {
    /// Matches the meeting prompt's accent in `GranolaDetection`.
    static let accent = Color(red: 0.42, green: 0.66, blue: 0.33)
    static let readableWidth: CGFloat = 720
    static let pagePadding: CGFloat = 36
}

extension View {
    /// Centers content in a column of comfortable reading width.
    func readableColumn() -> some View {
        frame(maxWidth: Theme.readableWidth, alignment: .leading)
            .padding(.horizontal, Theme.pagePadding)
            .frame(maxWidth: .infinity)
    }

    func sectionLabel() -> some View {
        font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }
}

/// A capsule of secondary metadata: date, duration, attendees, source app.
struct MetaChip<Leading: View>: View {
    let text: String
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 5) {
            leading
            Text(text).lineLimit(1)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

extension MetaChip where Leading == Image {
    init(_ text: String, systemImage: String) {
        self.text = text
        self.leading = Image(systemName: systemImage)
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 18

    private static let palette: [Color] = [
        Color(red: 0.42, green: 0.66, blue: 0.33), .orange, .teal, .indigo, .pink, .brown, .purple, .cyan,
    ]

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" })
        return words.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
    }

    /// Deterministic across launches, unlike `hashValue`.
    private var color: Color {
        Self.palette[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.palette.count]
    }
}

struct AvatarStack: View {
    let attendees: [Attendee]
    var size: CGFloat = 18
    var limit = 3

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(attendees.prefix(limit).enumerated()), id: \.offset) { _, attendee in
                Avatar(name: attendee.displayName, size: size)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            }
        }
    }
}

/// A few bars that bounce with an input level, like a voice memo.
struct LiveBars: View {
    let level: Float
    var color: Color = Theme.accent
    var height: CGFloat = 14

    private static let shape: [CGFloat] = [0.55, 1, 0.7, 0.85]

    var body: some View {
        let normalized = CGFloat(min(1, sqrt(Double(max(0, level))) * 2.5))
        HStack(spacing: 2) {
            ForEach(Self.shape.indices, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: max(3, height * normalized * Self.shape[index]))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.12), value: normalized)
    }
}

struct RecordingDot: View {
    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(.red)
            .symbolEffect(.pulse)
    }
}

struct ElapsedTime: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Transcript.timestamp(context.date.timeIntervalSince(since)))
                .monospacedDigit()
        }
    }
}

enum AppInfo {
    static func icon(bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
            NSWorkspace.shared.icon(forFile: $0.path)
        }
    }

    static func name(bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
        }
    }
}

/// The leading glyph for a meeting: the call app's icon, or a calendar/note symbol.
struct MeetingGlyph: View {
    let meeting: Meeting
    var size: CGFloat = 26

    var body: some View {
        if let bundleID = meeting.sourceApp, let icon = AppInfo.icon(bundleID: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Theme.accent.opacity(0.16))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: meeting.calendarEventID != nil ? "calendar" : "note.text")
                        .font(.system(size: size * 0.46, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
        }
    }
}

/// Row background that lights up on hover, for plain buttons in the menu bar popover.
struct HoverHighlight: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}
