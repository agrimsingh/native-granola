import Foundation
import GranolaCore

/// A JSON-RPC 2.0 error that is returned to the client as a protocol-level error.
struct RPCError: Error {
    var code: Int
    var message: String

    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}

/// MCP server over the stdio transport: newline-delimited JSON-RPC 2.0 messages on stdin/stdout.
/// Synchronous; one request is handled at a time.
public final class MCPServer {
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    public static let serverName = "native-granola"
    public static let serverVersion = "0.1.0"

    static let instructions = """
        NativeGranola gives access to the user's locally recorded meetings: their own typed notes, \
        AI-enhanced notes and timestamped transcripts. Use list_meetings to browse recent meetings or a \
        date range, search_meetings to find meetings by topic, person or keyword, get_meeting for one \
        meeting's notes (optionally with transcript), get_transcript for a full transcript, and \
        get_current_meeting for the meeting happening right now. Meeting IDs come from list_meetings or \
        search_meetings. In transcripts "Me" is the user (microphone) and "Them" is the other \
        participants (system audio).
        """

    private let tools: MeetingTools

    /// - Parameters:
    ///   - timeZone: Zone used to display dates and to interpret date-only / zone-less inputs.
    ///   - now: Clock, injectable for tests.
    public init(store: Store, timeZone: TimeZone = .current, now: @escaping () -> Date = Date.init) {
        tools = MeetingTools(store: store, format: Formatting(timeZone: timeZone), now: now)
    }

    // MARK: Message handling

    /// Handles one incoming line (a JSON-RPC message or batch). Returns the response line without a
    /// trailing newline, or nil when nothing should be sent (notifications, client responses).
    public func handle(_ line: String) -> String? {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed])
        } catch {
            return encode(Self.errorResponse(id: NSNull(), code: RPCError.parseError, message: "Parse error"))
        }
        if let batch = json as? [Any] {
            guard !batch.isEmpty else {
                return encode(Self.errorResponse(id: NSNull(), code: RPCError.invalidRequest, message: "Invalid Request: empty batch"))
            }
            let responses = batch.compactMap(handleMessage)
            return responses.isEmpty ? nil : encode(responses)
        }
        return handleMessage(json).map(encode)
    }

    private func handleMessage(_ json: Any) -> [String: Any]? {
        guard let message = json as? [String: Any] else {
            return Self.errorResponse(id: NSNull(), code: RPCError.invalidRequest, message: "Invalid Request: expected an object")
        }
        let id = message["id"]
        if let id, !(id is String || id is NSNumber || id is NSNull) {
            return Self.errorResponse(id: NSNull(), code: RPCError.invalidRequest, message: "Invalid Request: bad id")
        }
        guard let method = message["method"] as? String else {
            // A response to a server-initiated request; we never send any, so ignore it.
            if message["result"] != nil || message["error"] != nil { return nil }
            return Self.errorResponse(id: id ?? NSNull(), code: RPCError.invalidRequest, message: "Invalid Request: missing method")
        }
        guard let id else { return nil } // notification
        do {
            let result = try dispatch(method: method, params: message["params"])
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let error as RPCError {
            return Self.errorResponse(id: id, code: error.code, message: error.message)
        } catch {
            return Self.errorResponse(id: id, code: RPCError.internalError, message: "Internal error: \(error)")
        }
    }

    private func dispatch(method: String, params: Any?) throws -> [String: Any] {
        switch method {
        case "initialize":
            let params = try Self.object(params)
            let requested = params["protocolVersion"] as? String
            let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
                ?? Self.supportedProtocolVersions[0]
            return [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": Self.serverName, "version": Self.serverVersion],
                "instructions": Self.instructions,
            ]
        case "ping":
            return [:]
        case "tools/list":
            _ = try Self.object(params)
            return ["tools": MeetingTools.definitions]
        case "tools/call":
            let params = try Self.object(params)
            guard let name = params["name"] as? String else {
                throw RPCError(code: RPCError.invalidParams, message: "Invalid params: 'name' must be a string")
            }
            guard MeetingTools.names.contains(name) else {
                throw RPCError(code: RPCError.invalidParams, message: "Unknown tool: \(name)")
            }
            let arguments: [String: Any]
            switch params["arguments"] {
            case nil, is NSNull: arguments = [:]
            case let dict as [String: Any]: arguments = dict
            default: throw RPCError(code: RPCError.invalidParams, message: "Invalid params: 'arguments' must be an object")
            }
            return tools.call(name: name, arguments: Arguments(arguments, format: tools.format))
        default:
            if method.hasPrefix("notifications/") { return [:] }
            throw RPCError(code: RPCError.methodNotFound, message: "Method not found: \(method)")
        }
    }

    private static func object(_ params: Any?) throws -> [String: Any] {
        switch params {
        case nil, is NSNull: return [:]
        case let dict as [String: Any]: return dict
        default: throw RPCError(code: RPCError.invalidParams, message: "Invalid params: expected an object")
        }
    }

    private static func errorResponse(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func encode(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return #"{"error":{"code":-32603,"message":"Internal error: unencodable response"},"id":null,"jsonrpc":"2.0"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Transport

    /// Serves stdin/stdout until stdin reaches EOF.
    public func runStdio() {
        run(input: .standardInput, output: .standardOutput)
    }

    /// Reads newline-delimited messages from `input` until EOF, writing each response followed by a
    /// newline to `output`. Uses unbuffered POSIX I/O, so every response is flushed immediately.
    /// Returns early if `output` is closed by the peer.
    public func run(input: FileHandle, output: FileHandle) {
        let inFD = input.fileDescriptor, outFD = output.fileDescriptor
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)

        func process(_ lineData: Data) -> Bool {
            var lineData = lineData
            if lineData.last == UInt8(ascii: "\r") { lineData.removeLast() }
            let response: String?
            if let line = String(data: lineData, encoding: .utf8) {
                guard !line.allSatisfy(\.isWhitespace) else { return true }
                response = handle(line)
            } else {
                response = encode(Self.errorResponse(id: NSNull(), code: RPCError.parseError, message: "Parse error: invalid UTF-8"))
            }
            guard let response else { return true }
            return Self.writeAll(Data((response + "\n").utf8), to: outFD)
        }

        while true {
            let n = chunk.withUnsafeMutableBytes { read(inFD, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                stderrLog("stdin read failed: \(String(cString: strerror(errno)))")
                break
            }
            if n == 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard process(Data(line)) else { return }
            }
        }
        if !buffer.isEmpty { _ = process(buffer) }
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    stderrLog("stdout write failed: \(String(cString: strerror(errno)))")
                    return false
                }
                offset += n
            }
            return true
        }
    }
}

/// Logs to stderr; stdout is reserved for protocol messages.
func stderrLog(_ message: String) {
    FileHandle.standardError.write(Data("[native-granola mcp] \(message)\n".utf8))
}

public enum MCPEntry {
    /// Entry point for `NativeGranola --mcp`. Opens the app's database (or `$NATIVE_GRANOLA_DB` if
    /// set), serves MCP over stdio, and exits 0 when stdin closes.
    public static func main() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let url = ProcessInfo.processInfo.environment["NATIVE_GRANOLA_DB"].map { URL(fileURLWithPath: $0) }
            ?? Store.defaultURL
        let store: Store
        do {
            store = try openStore(url)
        } catch {
            stderrLog("could not open database at \(url.path): \(error)")
            exit(1)
        }
        stderrLog("serving \(url.path)")
        MCPServer(store: store).runStdio()
        exit(0)
    }

    private static func openStore(_ url: URL) throws -> Store {
        do {
            return try Store(url: url)
        } catch {
            stderrLog("read-write open failed (\(error)); retrying read-only")
            return try Store(url: url, readOnly: true)
        }
    }
}
