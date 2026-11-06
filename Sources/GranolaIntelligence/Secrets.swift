import Foundation
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

/// Remembers reads, including misses and failures, so the keychain is asked at most once per item per
/// process. macOS can prompt for the login password on every read by a rebuilt binary, and SwiftUI
/// views check for keys on each render.
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

/// API keys: the keychain is authoritative, environment variables are a fallback.
public struct Secrets: Sendable {
    public static let service = "com.nativegranola.secrets"
    public static let shared = Secrets(keychain: CachingKeychain(SystemKeychain()))

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
