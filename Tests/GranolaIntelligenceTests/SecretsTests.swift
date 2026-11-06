import Foundation
import Testing
@testable import GranolaIntelligence

@Suite struct SecretsTests {
    @Test func keychainTakesPrecedenceOverEnvironment() throws {
        let keychain = InMemoryKeychain()
        let secrets = Secrets(keychain: keychain, environment: ["XAI_API_KEY": "env-key"])
        #expect(secrets.get(.xaiAPIKey) == "env-key")
        #expect(secrets.source(of: .xaiAPIKey) == .environment)

        try secrets.set("  kc-key\n", for: .xaiAPIKey)
        #expect(secrets.get(.xaiAPIKey) == "kc-key")
        #expect(secrets.source(of: .xaiAPIKey) == .keychain)
        #expect(try keychain.read(service: "com.nativegranola.secrets", account: "xaiAPIKey") == "kc-key")

        try secrets.delete(.xaiAPIKey)
        #expect(secrets.get(.xaiAPIKey) == "env-key")
    }

    @Test func missingAndEmptyValues() throws {
        let secrets = Secrets(keychain: InMemoryKeychain(), environment: ["NOTION_TOKEN": "   "])
        #expect(secrets.get(.notionToken) == nil)
        #expect(secrets.source(of: .notionToken) == nil)
        try secrets.set("secret_abc", for: .notionToken)
        #expect(secrets.get(.notionToken) == "secret_abc")
        try secrets.set("", for: .notionToken)
        #expect(secrets.get(.notionToken) == nil)
    }

    @Test func keysAreIndependentAndEnvNamesCorrect() throws {
        #expect(SecretKey.xaiAPIKey.environmentVariable == "XAI_API_KEY")
        #expect(SecretKey.notionToken.environmentVariable == "NOTION_TOKEN")
        let secrets = Secrets(keychain: InMemoryKeychain(), environment: [:])
        try secrets.set("a", for: .xaiAPIKey)
        #expect(secrets.get(.notionToken) == nil)
    }

    @Test func clientsRequireKeys() throws {
        let empty = Secrets(keychain: InMemoryKeychain(), environment: [:])
        #expect(throws: XAIError.missingAPIKey) { try XAIClient(secrets: empty) }
        #expect(throws: NotionError.missingToken) { try NotionClient(secrets: empty) }
        let full = Secrets(keychain: InMemoryKeychain(), environment: ["XAI_API_KEY": "k", "NOTION_TOKEN": "t"])
        #expect(try XAIClient(secrets: full).apiKey == "k")
        #expect(try NotionClient(secrets: full).token == "t")
    }

    @Test func cachingKeychainReadsEachItemOnce() throws {
        final class Counting: KeychainStore, @unchecked Sendable {
            let inner = InMemoryKeychain(["com.nativegranola.secrets/xaiAPIKey": "k"])
            var reads = 0
            func read(service: String, account: String) throws -> String? {
                reads += 1
                return try inner.read(service: service, account: account)
            }
            func write(_ value: String, service: String, account: String) throws {
                try inner.write(value, service: service, account: account)
            }
            func delete(service: String, account: String) throws { try inner.delete(service: service, account: account) }
        }
        let counting = Counting()
        let secrets = Secrets(keychain: CachingKeychain(counting), environment: [:])
        for _ in 0..<5 {
            #expect(secrets.get(.xaiAPIKey) == "k")
            #expect(secrets.get(.notionToken) == nil)
        }
        #expect(counting.reads == 2)
        try secrets.set("t", for: .notionToken)
        #expect(secrets.get(.notionToken) == "t")
        try secrets.delete(.xaiAPIKey)
        #expect(secrets.get(.xaiAPIKey) == nil)
        #expect(counting.reads == 2)
    }
}
