import Foundation

/// Detects microphone segments that are just the speakers being picked up by the mic. Acoustic
/// echo cancellation catches most of this; this is the text-level backstop.
public enum EchoFilter {
    public static func isEcho(mic: TranscriptSegment, system: TranscriptSegment,
                              timeTolerance: TimeInterval = 4, threshold: Double = 0.6) -> Bool {
        guard mic.source == .microphone, system.source == .system else { return false }
        let overlaps = mic.startOffset <= system.endOffset + timeTolerance
            && system.startOffset <= mic.endOffset + timeTolerance
        guard overlaps else { return false }
        let a = tokens(mic.text), b = tokens(system.text)
        guard a.count >= 3, !b.isEmpty else { return false }
        let shared = a.intersection(b).count
        return Double(shared) / Double(min(a.count, b.count)) >= threshold
    }

    static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }
}
