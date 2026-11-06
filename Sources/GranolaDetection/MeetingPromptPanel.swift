import AppKit
import SwiftUI

/// Granola-style floating prompt in the top-right corner. Never activates the app or takes focus.
/// Only one prompt is visible at a time; showing a new one replaces the old one.
@MainActor
public enum MeetingPromptPanel {
    public static var autoDismissAfter: TimeInterval = 45

    public private(set) static var currentSuggestion: MeetingSuggestion?
    public static var isVisible: Bool { panel?.isVisible ?? false }

    private static var panel: PromptPanelWindow?
    private static var generation = 0
    private static var dismissTask: Task<Void, Never>?
    private static var isHovering = false

    /// `onTakeNotes` fires for "Take notes" and "Join & take notes" (after opening the join link).
    /// `onDismiss` fires when the user closes the prompt or it times out — not on `dismiss()` or replacement.
    public static func show(
        _ suggestion: MeetingSuggestion,
        onTakeNotes: @escaping (MeetingSuggestion) -> Void,
        onDismiss: @escaping (MeetingSuggestion) -> Void = { _ in }
    ) {
        close(animated: false)
        generation += 1
        let token = generation
        currentSuggestion = suggestion
        isHovering = false

        func act(_ body: @escaping () -> Void) -> () -> Void {
            { guard token == generation else { return }; close(animated: true); body() }
        }
        let joinURL = suggestion.conferenceURL
        let card = PromptCardView(
            suggestion: suggestion,
            onTakeNotes: act { onTakeNotes(suggestion) },
            onJoin: joinURL.map { url in act { NSWorkspace.shared.open(url); onTakeNotes(suggestion) } },
            onClose: act { onDismiss(suggestion) },
            onHover: { hovering in if token == generation { isHovering = hovering } }
        )

        let hosting = FirstMouseHostingView(rootView: card)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = PromptPanelWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        let target = topRightFrame(for: size)
        window.setFrame(target.offsetBy(dx: 24, dy: 0), display: false)
        window.alphaValue = 0
        window.orderFrontRegardless()
        panel = window
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(target, display: true)
            window.animator().alphaValue = 1
        }

        scheduleAutoDismiss(token: token, after: autoDismissAfter, onDismiss: { onDismiss(suggestion) })
    }

    /// Hides the current prompt without calling its callbacks.
    public static func dismiss() {
        close(animated: true)
    }

    private static func scheduleAutoDismiss(token: Int, after delay: TimeInterval, onDismiss: @escaping () -> Void) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, token == generation else { return }
            if isHovering {
                scheduleAutoDismiss(token: token, after: 5, onDismiss: onDismiss)
                return
            }
            close(animated: true)
            onDismiss()
        }
    }

    private static func close(animated: Bool) {
        dismissTask?.cancel()
        dismissTask = nil
        currentSuggestion = nil
        guard let window = panel else { return }
        panel = nil
        guard animated else {
            window.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
        })
    }

    private static func topRightFrame(for size: NSSize) -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // The card view carries its own transparent margin for the shadow.
        return NSRect(x: visible.maxX - size.width, y: visible.maxY - size.height, width: size.width, height: size.height)
    }
}

final class PromptPanelWindow: NSPanel {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets clicks land on buttons even though the panel is never key and the app isn't active.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct PromptCardView: View {
    let suggestion: MeetingSuggestion
    let onTakeNotes: () -> Void
    let onJoin: (() -> Void)?
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                SourceIcon(bundleID: suggestion.micApp?.bundleID)
                    .frame(width: 14, height: 14)
                Text(sourceLabel)
                    .lineLimit(1)
                Text("·")
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(PromptTimeLabel.text(for: suggestion, now: context.date))
                        .foregroundStyle(PromptPalette.accentInk)
                        .lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PromptPalette.inkSecondary)
                .help("Dismiss")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(PromptPalette.inkSecondary)

            Text(suggestion.title)
                .font(.system(size: 19, weight: .regular, design: .serif))
                .tracking(-0.2)
                .foregroundStyle(PromptPalette.ink)
                .lineLimit(2)
                .padding(.top, 8)
            if !suggestion.subtitle.isEmpty {
                Text(suggestion.subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(PromptPalette.inkSecondary)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
            HStack(spacing: 8) {
                if let onJoin {
                    Button("Join & take notes", action: onJoin).buttonStyle(PromptButtonStyle(primary: true))
                    Button("Take notes", action: onTakeNotes).buttonStyle(PromptButtonStyle(primary: false))
                } else {
                    Button("Take notes", action: onTakeNotes).buttonStyle(PromptButtonStyle(primary: true))
                }
            }
            .padding(.top, 14)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(width: 320, alignment: .leading)
        .background(PromptPalette.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(PromptPalette.hairline)
        )
        .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
        .padding(16)
        .onHover(perform: onHover)
    }

    private var sourceLabel: String {
        switch suggestion.kind {
        case .calendar(let event): event.calendarTitle ?? "Calendar"
        case .adHoc(let app, _): app.name
        }
    }
}

/// The app's paper-and-olive palette, repeated here because this module can't see the app's theme.
private enum PromptPalette {
    static let paper = adaptive(0xFCFCF8, 0x272725)
    static let ink = adaptive(0x292929, 0xECECE6)
    static let inkSecondary = adaptive(0x6B6B67, 0xA3A39E)
    static let accentInk = adaptive(0x5B6F00, 0xB2C455)
    static let accentFill = adaptive(0x5B6F00, 0x6B8212)
    static let accentFillPressed = adaptive(0x4C5616, 0x7A9418)
    static let softFill = adaptive(0x625A22, 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.08)
    static let softFillPressed = adaptive(0x56512E, 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.13)
    static let hairline = adaptive(0x47432A, 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.1)
    static let onAccent = adaptive(0xFCFCF8, 0xFCFCF8)

    private static func adaptive(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        func color(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark, darkAlpha) : color(light, lightAlpha)
        })
    }
}

/// Pill buttons drawn by hand: the panel is never key, so system prominent buttons render inactive.
private struct PromptButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(primary ? PromptPalette.onAccent : PromptPalette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                primary ? (configuration.isPressed ? PromptPalette.accentFillPressed : PromptPalette.accentFill)
                        : (configuration.isPressed ? PromptPalette.softFillPressed : PromptPalette.softFill),
                in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private struct SourceIcon: View {
    let bundleID: String?

    var body: some View {
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: bundleID == nil ? "calendar" : "mic.fill")
                .foregroundStyle(.secondary)
        }
    }
}

enum PromptTimeLabel {
    static func text(for suggestion: MeetingSuggestion, now: Date) -> String {
        if case .calendar(let event) = suggestion.kind {
            return relative(start: event.start, now: now)
        }
        return relative(start: suggestion.detectedAt, now: now, startedWord: "Detected")
    }

    /// "Starts in 1 min", "Starting now", "Started 3 min ago" (or "Detected ..." for ad-hoc prompts).
    static func relative(start: Date, now: Date, startedWord: String = "Started") -> String {
        let seconds = start.timeIntervalSince(now)
        let minutes = Int((abs(seconds) / 60).rounded())
        if seconds > 30 { return "Starts in \(max(minutes, 1)) min" }
        if minutes < 1 { return startedWord == "Started" ? "Starting now" : "\(startedWord) just now" }
        return "\(startedWord) \(minutes) min ago"
    }
}
