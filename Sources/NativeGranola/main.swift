import Foundation
import GranolaIntelligence
import GranolaMCP

let arguments = CommandLine.arguments

if arguments.contains("--mcp") {
    MCPEntry.main()
}

// --set-secret <xaiAPIKey|notionToken>, value on stdin. Run from the signed bundle so the keychain
// item belongs to the app and reading it later doesn't prompt.
if let index = arguments.firstIndex(of: "--set-secret"), index + 1 < arguments.count {
    guard let key = SecretKey(rawValue: arguments[index + 1]), let value = readLine(), !value.isEmpty else {
        FileHandle.standardError.write(Data("usage: --set-secret <xaiAPIKey|notionToken> < value\n".utf8))
        exit(2)
    }
    do {
        try Secrets.shared.set(value, for: key)
        print("Saved \(key.rawValue) to the keychain")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }
}

if let index = arguments.firstIndex(of: "--selftest") {
    SelfTest.run(Array(arguments[(index + 1)...]))
}

if let index = arguments.firstIndex(of: "--benchmark") {
    XAIClient.defaultModel = Preferences.model
    Benchmark.run(Array(arguments[(index + 1)...]))
}

XAIClient.defaultModel = Preferences.model
NativeGranolaApp.main()
