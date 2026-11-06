import Foundation
import GranolaCore
import Security

public enum SecretKey: String, CaseIterable, Sendable {
    case xaiAPIKey
    case notionToken

    public var environmentVariable: String {
        switch self {
        case .xaiAPIKey: return "XAI_API_KEY"
        case .notionToken: return "NOTION_TOKEN"
        }
    }
}

public protocol KeychainStore: Sendable {
    func read(service: String, account: String) throws -> String?
    func write(_ value: String, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

public struct KeychainError: Error, LocalizedError, Equatable {
    public let status: OSStatus

    public init(status: OSStatus) { self.status = status }

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
        return "Keychain error \(status): \(message)"
    }
}

/// Generic-password items in the user's login keychain.
public struct SystemKeychain: KeychainStore {
    public init() {}

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read(service: String, account: String) throws -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(service: service, account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "NativeGranola: \(account)"
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// Secrets in a JSON file only the current user can read. Used instead of the login keychain because
/// macOS ties a keychain item to the code hash of a self-signed app, so every rebuild asks for the
/// login password again.
public final class FileSecretStore: KeychainStore, @unchecked Sendable {
    public static var defaultURL: URL {
        Store.defaultURL.deletingLastPathComponent().appendingPathComponent("secrets.json")
    }

    private let url: URL
    private let lock = NSLock()

    public init(url: URL = FileSecretStore.defaultURL) { self.url = url }

    private func key(_ service: String, _ account: String) -> String { "\(service)/\(account)" }

    private func load() throws -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func save(_ items: [String: String]) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = url.path + ".tmp"
        guard fm.createFile(atPath: tmp, contents: try JSONEncoder().encode(items), attributes: [.posixPermissions: 0o600]),
              rename(tmp, url.path) == 0
        else { throw CocoaError(.fileWriteUnknown) }
    }

    public func read(service: String, account: String) throws -> String? {
        try lock.withLock { try load()[key(service, account)] }
    }

    public func write(_ value: String, service: String, account: String) throws {
        try lock.withLock {
            var items = try load()
            items[key(service, account)] = value
            try save(items)
        }
    }

    public func delete(service: String, account: String) throws {
        try lock.withLock {
            var items = try load()
            guard items.removeValue(forKey: key(service, account)) != nil else { return }
            try save(items)
        }
    }
}

/// Reads from `primary`, moving an item over from `legacy` the first time it's missing there.
public struct MigratingSecretStore: KeychainStore {
    public let primary: any KeychainStore
    public let legacy: any KeychainStore

    public init(primary: any KeychainStore, legacy: any KeychainStore) {
        self.primary = primary
        self.legacy = legacy
    }

    public func read(service: String, account: String) throws -> String? {
        if let value = try primary.read(service: service, account: account) { return value }
        guard let value = try? legacy.read(service: service, account: account) else { return nil }
        try primary.write(value, service: service, account: account)
        try? legacy.delete(service: service, account: account)
        return value
    }

    public func write(_ value: String, service: String, account: String) throws {
        try primary.write(value, service: service, account: account)
        try? legacy.delete(service: service, account: account)
    }

    public func delete(service: String, account: String) throws {
        try primary.delete(service: service, account: account)
        try? legacy.delete(service: service, account: account)
    }
}

/// Process-local keychain stand-in (tests, previews).
public final class InMemoryKeychain: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    public init(_ initial: [String: String] = [:]) { items = initial }

    private func key(_ service: String, _ account: String) -> String { "\(service)/\(account)" }

    public func read(service: String, account: String) throws -> String? {
        lock.withLock { items[key(service, account)] }
    }

    public func write(_ value: String, service: String, account: String) throws {
        lock.withLock { items[key(service, account)] = value }
    }

    public func delete(service: String, account: String) throws {
        lock.withLock { items[key(service, account)] = nil }
    }
}

/// Remembers reads, including misses and failures, so the store is asked at most once per item per
/// process. SwiftUI views check for keys on each render.
public final class CachingKeychain: KeychainStore, @unchecked Sendable {
    private let base: any KeychainStore
    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    public init(_ base: any KeychainStore) { self.base = base }

    public func read(service: String, account: String) throws -> String? {
        let key = "\(service)/\(account)"
        if let cached = lock.withLock({ cache[key] }) { return cached }
        let value = try? base.read(service: service, account: account)
        lock.withLock { cache[key] = .some(value) }
        return value
    }

    public func write(_ value: String, service: String, account: String) throws {
        try base.write(value, service: service, account: account)
        lock.withLock { cache["\(service)/\(account)"] = .some(value) }
    }

    public func delete(service: String, account: String) throws {
        try base.delete(service: service, account: account)
        lock.withLock { cache["\(service)/\(account)"] = .some(nil) }
    }
}

/// API keys: the saved value is authoritative, environment variables are a fallback.
public struct Secrets: Sendable {
    public static let service = "com.nativegranola.secrets"
    public static let shared = Secrets(
        keychain: CachingKeychain(MigratingSecretStore(primary: FileSecretStore(), legacy: SystemKeychain())))

    public enum Source: String, Sendable { case keychain, environment }

    public let keychain: any KeychainStore
    public let environment: [String: String]

    public init(
        keychain: any KeychainStore = SystemKeychain(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.keychain = keychain
        self.environment = environment
    }

    public func get(_ key: SecretKey) -> String? {
        lookup(key)?.value
    }

    /// Where the current value comes from, or nil if unset.
    public func source(of key: SecretKey) -> Source? {
        lookup(key)?.source
    }

    /// Stores `value` (trimmed). An empty value deletes the keychain entry.
    public func set(_ value: String, for key: SecretKey) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete(key)
        } else {
            try keychain.write(trimmed, service: Self.service, account: key.rawValue)
        }
    }

    public func delete(_ key: SecretKey) throws {
        try keychain.delete(service: Self.service, account: key.rawValue)
    }

    private func lookup(_ key: SecretKey) -> (value: String, source: Source)? {
        if let stored = (try? keychain.read(service: Self.service, account: key.rawValue))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty
        {
            return (stored, .keychain)
        }
        if let env = environment[key.environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return (env, .environment)
        }
        return nil
    }
}
