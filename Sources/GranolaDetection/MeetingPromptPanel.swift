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

    private static let accent = Color(red: 0.42, green: 0.66, blue: 0.33)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AccentBar(dashed: !suggestion.isCalendar, color: Self.accent)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    SourceIcon(bundleID: suggestion.micApp?.bundleID)
                        .frame(width: 16, height: 16)
                    Text(sourceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
                }
                Text(suggestion.title)
                    .font(.headline)
                    .lineLimit(2)
                if !suggestion.subtitle.isEmpty {
                    Text(suggestion.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(PromptTimeLabel.text(for: suggestion, now: context.date))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 8) {
                    Button("Take notes", action: onTakeNotes)
                        .buttonStyle(.borderedProminent)
                        .tint(Self.accent)
                    if let onJoin {
                        Button("Join & take notes", action: onJoin)
                            .buttonStyle(.bordered)
                    }
                }
                .controlSize(.regular)
                .padding(.top, 6)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
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

private struct AccentBar: View {
    let dashed: Bool
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            if dashed {
                Path { path in
                    path.move(to: CGPoint(x: geometry.size.width / 2, y: geometry.size.width / 2))
                    path.addLine(to: CGPoint(x: geometry.size.width / 2, y: geometry.size.height - geometry.size.width / 2))
                }
                .stroke(color, style: StrokeStyle(lineWidth: geometry.size.width, lineCap: .round, dash: [5, 5]))
            } else {
                Capsule().fill(color)
            }
        }
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
