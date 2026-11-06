import AppKit
import GranolaCore
import SwiftUI

/// Granola-style "oats" palette: warm paper surfaces, warm-tinted neutrals, an olive accent.
/// Every token adapts to dark mode.
enum Theme {
    static let canvas = adaptive(0xF7F7F2, 0x1D1C19)
    static let raised = adaptive(0xFFFFFF, 0x2A2925)
    static let sunken = adaptive(0xF1F1EA, 0x181714)
    static let sidebar = adaptive(0xEEEDE5, 0x25241F)

    static let ink = adaptive(0x292929, 0xEDECE6)
    static let inkSecondary = adaptive(0x65645F, 0xA3A29B)
    static let inkTertiary = adaptive(0x8F8F8A, 0x85857F)

    static let accentInk = adaptive(0x5B6F00, 0xB2C455)
    static let accentFill = adaptive(0x5B6F00, 0x5E7210)
    static let accentFillHover = adaptive(0x4C5616, 0x6B8212)
    static let accentGround = adaptive(0xEEF2D8, 0x2A3016)
    static let selection = adaptive(0x5E5A3C, 0xFFFFFF, lightAlpha: 0.13, darkAlpha: 0.10)
    static let match = adaptive(0x8FA51F, 0xB2C455, lightAlpha: 0.26, darkAlpha: 0.30)
    static let segmentSelected = adaptive(0xFFFFFF, 0x3A3934)
    static let onAccent = Color(hex: 0xFCFCF8)

    static let danger = adaptive(0xD9532F, 0xE0613F)
    static let dangerHover = adaptive(0xBD4A30, 0xC9553A)

    static let softFill = adaptive(0x625A22, 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.07)
    static let softFillHover = adaptive(0x56512E, 0xFFFFFF, lightAlpha: 0.13, darkAlpha: 0.12)
    static let hairline = adaptive(0x47432A, 0xFFFFFF, lightAlpha: 0.16, darkAlpha: 0.09)
    static let liveBars = Color(hex: 0x74BD00)

    static let readableWidth: CGFloat = 660
    static let pagePadding: CGFloat = 44

    /// Display face: hierarchy comes from size, never weight.
    static func serif(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .serif)
    }

    private static func adaptive(_ light: UInt32, _ dark: UInt32,
                                 lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

extension View {
    /// Centers content in a column of comfortable reading width.
    func readableColumn(padding: CGFloat = Theme.pagePadding) -> some View {
        frame(minWidth: 0, maxWidth: Theme.readableWidth, alignment: .leading)
            .padding(.horizontal, padding)
            .frame(minWidth: 0, maxWidth: .infinity)
    }
}

/// Full-pill buttons in the Granola style.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case accent, soft, danger }
    var kind: Kind = .soft
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, kind: kind, compact: compact)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let kind: Kind
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let active = hovering || configuration.isPressed
            configuration.label
                .font(.system(size: compact ? 12 : 13, weight: .medium))
                .labelStyle(PillLabelStyle())
                .foregroundStyle(kind == .soft ? Theme.ink : Theme.onAccent)
                .padding(.horizontal, compact ? 10 : 14)
                .padding(.vertical, compact ? 4 : 7)
                .background(background(active: active), in: Capsule())
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.15), value: active)
                .onHover { hovering = $0 }
        }

        private func background(active: Bool) -> Color {
            switch kind {
            case .accent: active ? Theme.accentFillHover : Theme.accentFill
            case .soft: active ? Theme.softFillHover : Theme.softFill
            case .danger: active ? Theme.dangerHover : Theme.danger
            }
        }
    }
}

private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Small capsule of read-only metadata under a meeting title.
struct MetaPill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.softFill, in: Capsule())
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 18

    private static let palette: [UInt32] = [0x7A8F2A, 0xC0793F, 0x5E8299, 0x8E6A8C, 0xB0604F, 0x8A7D55]

    var body: some View {
        Circle()
            .fill(Color(hex: Self.palette[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.palette.count]))
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
            }
    }

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" })
        return words.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
    }
}

struct AvatarStack: View {
    let attendees: [Attendee]
    var size: CGFloat = 16
    var limit = 3

    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(Array(attendees.prefix(limit).enumerated()), id: \.offset) { _, attendee in
                Avatar(name: attendee.displayName, size: size)
                    .padding(1)
                    .background(Theme.canvas, in: Circle())
            }
        }
    }
}

/// Granola's audio bars. With a level they dance; without one they rest as a static glyph.
struct DancingBars: View {
    var level: Float?
    var height: CGFloat = 14

    private static let rest: [CGFloat] = [0.4, 0.75, 1, 0.6, 0.35]

    var body: some View {
        if let level {
            let normalized = CGFloat(min(1, sqrt(Double(max(0, level))) * 2.5))
            TimelineView(.periodic(from: .now, by: 0.08)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                bars(color: Theme.liveBars) { index in
                    let wobble = 0.55 + 0.45 * abs(sin(t * (3.1 + Double(index) * 1.7)))
                    return 0.18 + 0.82 * normalized * wobble
                }
            }
            .animation(.easeOut(duration: 0.08), value: normalized)
        } else {
            bars(color: .foreground.secondary) { Self.rest[$0] }
        }
    }

    private func bars(color: some ShapeStyle, fraction: @escaping (Int) -> CGFloat) -> some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Self.rest.indices, id: \.self) { index in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5, height: max(2.5, height * fraction(index)))
            }
        }
        .frame(height: height)
    }
}

struct RecordingDot: View {
    var body: some View {
        Circle()
            .fill(Theme.danger)
            .frame(width: 7, height: 7)
            .phaseAnimator([1.0, 0.6]) { dot, opacity in dot.opacity(opacity) } animation: { _ in .easeInOut(duration: 0.9) }
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

enum People {
    /// "Priya, Marcus" or "Priya, Marcus +3".
    static func short(_ attendees: [Attendee]) -> String {
        let names = attendees.map { $0.name?.split(separator: " ").first.map(String.init) ?? $0.displayName }
        let shown = names.prefix(2).joined(separator: ", ")
        return names.count > 2 ? "\(shown) +\(names.count - 2)" : shown
    }
}

/// Row background that lights up on hover, for plain buttons in the menu bar popover.
struct HoverHighlight: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hovering ? Theme.softFill : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}
