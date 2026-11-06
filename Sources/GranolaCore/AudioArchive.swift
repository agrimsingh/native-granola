import Foundation

/// Where a meeting's recorded audio lives while it's kept for post-meeting processing
/// (re-transcription, speaker separation). One file per source, 16 kHz mono Float32 CAF:
/// `~/Library/Application Support/NativeGranola/Audio/<meeting id>/<microphone|system>.caf`
public enum AudioArchive {
    public static let sampleRate: Double = 16_000

    public static var root: URL {
        Store.defaultURL.deletingLastPathComponent().appendingPathComponent("Audio", isDirectory: true)
    }

    public static func directory(meetingID: String, root: URL = AudioArchive.root) -> URL {
        root.appendingPathComponent(meetingID, isDirectory: true)
    }

    public static func url(meetingID: String, source: TranscriptSource, root: URL = AudioArchive.root) -> URL {
        directory(meetingID: meetingID, root: root).appendingPathComponent("\(source.rawValue).caf")
    }

    public static func hasAudio(meetingID: String, root: URL = AudioArchive.root) -> Bool {
        TranscriptSource.allCases.contains {
            FileManager.default.fileExists(atPath: url(meetingID: meetingID, source: $0, root: root).path)
        }
    }

    public static func delete(meetingID: String, root: URL = AudioArchive.root) {
        try? FileManager.default.removeItem(at: directory(meetingID: meetingID, root: root))
    }
}
