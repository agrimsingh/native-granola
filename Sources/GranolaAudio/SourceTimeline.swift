import Foundation

/// Places one source's captured buffers on the session timeline (seconds since the meeting started).
/// Buffers are laid end to end by sample count; one that arrives well after the previous run ended
/// (capture restarted after a device change, or the Mac slept) starts a new run at its arrival time.
/// The timeline outlives individual captures, so offsets never reset and gaps stay gaps.
public struct SourceTimeline: Sendable {
    public struct Placement: Equatable, Sendable {
        public var start: TimeInterval
        /// Silence between the previous buffer's end (or the session start) and this buffer.
        public var gap: TimeInterval
    }

    public var gapThreshold: TimeInterval
    public private(set) var end: TimeInterval?

    public init(gapThreshold: TimeInterval = 0.5) {
        self.gapThreshold = gapThreshold
    }

    /// `arrival` is when the buffer was delivered, i.e. roughly when its last sample was captured.
    public mutating func place(duration: TimeInterval, arrivedAt arrival: TimeInterval) -> Placement {
        let observed = max(0, arrival - duration)
        guard let end else {
            self.end = observed + duration
            return Placement(start: observed, gap: observed)
        }
        let start = observed - end > gapThreshold ? observed : end
        self.end = start + duration
        return Placement(start: start, gap: start - end)
    }
}
