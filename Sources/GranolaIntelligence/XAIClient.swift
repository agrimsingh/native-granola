import Foundation

public struct ChatMessage: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }

    public var role: Role
    public var content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String) -> ChatMessage { .init(role: .system, content: content) }
    public static func user(_ content: String) -> ChatMessage { .init(role: .user, content: content) }
    public static func assistant(_ content: String) -> ChatMessage { .init(role: .assistant, content: content) }
}

public enum XAIError: Error, LocalizedError, Equatable {
    case missingAPIKey
    /// Non-2xx response; `message` is the server's error message when one could be parsed.
    case http(status: Int, message: String)
    case invalidResponse(String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No xAI API key configured. Add one in Settings or set XAI_API_KEY."
        case .http(let status, let message):
            let hint: String
            switch status {
            case 401, 403: hint = " (check your xAI API key)"
            case 404: hint = " (unknown model or endpoint)"
            case 429: hint = " (rate limited or out of credits)"
            default: hint = ""
            }
            return "xAI API error \(status)\(hint): \(message)"
        case .invalidResponse(let detail):
            return "Unexpected response from xAI: \(detail)"
        case .emptyResponse:
            return "xAI returned an empty response."
        }
    }

    /// Extracts a human-readable message from OpenAI-style (`{"error":{"message":…}}`) or
    /// xAI-style (`{"code":…,"error":"…"}`) error bodies, falling back to the raw body.
    static func from(status: Int, body: Data) -> XAIError {
        var message: String?
        if let json = try? JSONValue.decode(body) {
            message = json["error"]?["message"]?.stringValue
                ?? json["error"]?.stringValue
                ?? json["message"]?.stringValue
                ?? json["detail"]?.stringValue
        }
        if message == nil || message!.isEmpty {
            let raw = String(decoding: body.prefix(1000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            message = raw.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : raw
        }
        return .http(status: status, message: message!)
    }
}

/// Client for xAI's OpenAI-compatible chat API.
public struct XAIClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.x.ai/v1")!
    public static let fallbackModel = "grok-4"

    private static let defaultModelStorage = LockedValue(fallbackModel)

    /// Process-wide default model used by newly created clients. The app can change this from settings.
    public static var defaultModel: String {
        get { defaultModelStorage.value }
        set { defaultModelStorage.value = newValue }
    }

    public var apiKey: String
    public var baseURL: URL
    /// Model used when a call doesn't specify one.
    public var model: String
    public var http: any HTTPClient
    public var timeout: TimeInterval

    public init(
        apiKey: String,
        model: String? = nil,
        baseURL: URL = XAIClient.defaultBaseURL,
        http: any HTTPClient = URLSessionHTTPClient(),
        timeout: TimeInterval = 600
    ) {
        self.apiKey = apiKey
        self.model = model ?? XAIClient.defaultModel
        self.baseURL = baseURL
        self.http = http
        self.timeout = timeout
    }

    /// Builds a client from the stored `xaiAPIKey`; throws `XAIError.missingAPIKey` if unset.
    public init(secrets: Secrets, model: String? = nil, http: any HTTPClient = URLSessionHTTPClient()) throws {
        guard let key = secrets.get(.xaiAPIKey) else { throw XAIError.missingAPIKey }
        self.init(apiKey: key, model: model, http: http)
    }

    // MARK: Requests

    struct ChatRequestBody: Encodable {
        var model: String
        var messages: [ChatMessage]
        var temperature: Double?
        var stream: Bool?
    }

    func makeChatRequest(messages: [ChatMessage], model: String?, temperature: Double?, stream: Bool) throws -> URLRequest {
        let body = ChatRequestBody(
            model: model ?? self.model,
            messages: messages,
            temperature: temperature,
            stream: stream ? true : nil
        )
        var request = makeRequest(path: "chat/completions", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    func makeRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func checkKey() throws {
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw XAIError.missingAPIKey }
    }

    // MARK: API

    public func complete(messages: [ChatMessage], model: String? = nil, temperature: Double? = nil) async throws -> String {
        try checkKey()
        let request = try makeChatRequest(messages: messages, model: model, temperature: temperature, stream: false)
        let (data, response) = try await http.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw XAIError.from(status: response.statusCode, body: data)
        }
        let json: JSONValue
        do { json = try JSONValue.decode(data) } catch {
            throw XAIError.invalidResponse("body is not JSON")
        }
        guard let content = json["choices"]?[0]?["message"]?["content"]?.stringValue else {
            if json["choices"]?.arrayValue?.isEmpty == true { throw XAIError.emptyResponse }
            throw XAIError.invalidResponse("missing choices[0].message.content")
        }
        return content
    }

    /// Streams content deltas as they arrive. Cancelling the consuming task cancels the request.
    public func stream(messages: [ChatMessage], model: String? = nil, temperature: Double? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try checkKey()
                    let request = try makeChatRequest(messages: messages, model: model, temperature: temperature, stream: true)
                    let (response, body) = try await http.stream(for: request)
                    guard (200..<300).contains(response.statusCode) else {
                        throw XAIError.from(status: response.statusCode, body: try await body.collect())
                    }
                    var parser = SSEParser()
                    var done = false
                    outer: for try await chunk in body {
                        for event in parser.feed(chunk) {
                            if try Self.handle(event: event, continuation: continuation) { done = true; break outer }
                        }
                    }
                    if !done {
                        for event in parser.finish() {
                            if try Self.handle(event: event, continuation: continuation) { break }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Returns true when the stream is finished (`[DONE]`).
    static func handle(event: String, continuation: AsyncThrowingStream<String, Error>.Continuation) throws -> Bool {
        let payload = event.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" { return true }
        if payload.isEmpty { return false }
        guard let json = try? JSONValue.decode(Data(payload.utf8)) else { return false }
        if json["error"] != nil {
            let status = json["error"]?["code"]?.doubleValue.map(Int.init) ?? json["status"]?.doubleValue.map(Int.init) ?? 500
            throw XAIError.from(status: status, body: Data(payload.utf8))
        }
        if let delta = json["choices"]?[0]?["delta"]?["content"]?.stringValue, !delta.isEmpty {
            continuation.yield(delta)
        }
        return false
    }

    /// Model IDs available to this API key, sorted.
    public func listModels() async throws -> [String] {
        try checkKey()
        var request = makeRequest(path: "models", method: "GET")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw XAIError.from(status: response.statusCode, body: data)
        }
        guard let items = (try? JSONValue.decode(data))?["data"]?.arrayValue else {
            throw XAIError.invalidResponse("missing data[]")
        }
        return items.compactMap { $0["id"]?.stringValue }.sorted()
    }
}

final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) { _value = value }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
