import FluidAudio
import Foundation

/// The on-device models used after a meeting. All of them download from Hugging Face on first use into
/// `~/Library/Application Support/FluidAudio/Models` and are compiled by Core ML.
public enum ParakeetModel: String, Sendable, CaseIterable, Codable {
    /// Parakeet TDT 0.6B v3: 25 European languages.
    case v3
    /// Parakeet TDT 0.6B v2: English only.
    case v2

    var version: AsrModelVersion { self == .v3 ? .v3 : .v2 }

    public var displayName: String { self == .v3 ? "Parakeet v3 (multilingual)" : "Parakeet v2 (English)" }

    /// ISO 639-1 codes the model was trained on.
    public var languageCodes: Set<String> {
        switch self {
        case .v2: ["en"]
        case .v3: ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt",
                   "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]
        }
    }

    /// Re-transcribing speech in any other language would replace a good live transcript with gibberish.
    public func supports(_ locale: Locale) -> Bool {
        locale.language.languageCode.map { languageCodes.contains($0.identifier) } ?? false
    }

    public var cacheDirectory: URL { AsrModels.defaultCacheDirectory(for: version) }

    public var isDownloaded: Bool { AsrModels.modelsExist(at: cacheDirectory, version: version) }

    /// `progress` gets the completed fraction, 0...1.
    public func download(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await AsrModels.download(version: version, progressHandler: progress.map { p in { p($0.fractionCompleted) } })
    }
}

public enum DiarizerModel {
    public static var cacheDirectory: URL {
        OfflineDiarizerModels.defaultModelsDirectory().appendingPathComponent(Repo.diarizer.folderName)
    }

    public static var isDownloaded: Bool {
        ModelNames.OfflineDiarizer.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent($0).path)
        }
    }

    public static func download(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        _ = try await OfflineDiarizerModels.load(progressHandler: progress.map { p in { p($0.fractionCompleted) } })
    }
}

extension URL {
    /// Total size of the files under this directory, in bytes.
    public var allocatedSize: Int64 {
        guard let e = FileManager.default.enumerator(at: self, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}
