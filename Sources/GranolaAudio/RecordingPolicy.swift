import Foundation
import GranolaCore

public enum RecordingPolicy {
    /// Past this, a meeting interrupted by sleep is treated as over rather than resumed.
    public static let maxResumableSleep: TimeInterval = 15 * 60

    public static func shouldResume(afterSleeping duration: TimeInterval, sourceAppRunning: Bool) -> Bool {
        duration <= maxResumableSleep && sourceAppRunning
    }

    /// When a meeting that was never ended (the app crashed or was killed) should be marked as ended.
    public static func recoveredEnd(of meeting: Meeting, segments: [TranscriptSegment]) -> Date {
        meeting.startedAt.addingTimeInterval(max(0, segments.map(\.endOffset).max() ?? 0))
    }
}

extension AudioArchive {
    /// Deletes meeting audio folders whose newest file is more than `days` old, except `keeping`.
    /// Returns the meeting IDs whose audio was deleted.
    @discardableResult
    public static func prune(olderThanDays days: Int, root: URL = AudioArchive.root, now: Date = Date(),
                             keeping: Set<String> = []) -> [String] {
        guard days > 0 else { return [] }
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var deleted: [String] = []
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let meetingID = folder.lastPathComponent
            guard !keeping.contains(meetingID) else { continue }
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let newest = (files + [folder])
                .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                .max() ?? .distantPast
            if newest < cutoff, (try? fm.removeItem(at: folder)) != nil { deleted.append(meetingID) }
        }
        return deleted
    }
}
