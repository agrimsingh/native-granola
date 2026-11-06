import Foundation
import Testing
@testable import GranolaIntelligence

@Suite struct XAIClientTests {
    static let okCompletion: JSONValue = [
        "id": "x", "object": "chat.completion",
        "choices": [["index": 0, "message": ["role": "assistant", "content": "Hello there"], "finish_reason": "stop"]],
    ]

    @Test func completeBuildsRequestAndParsesContent() async throws {
        let http = MockHTTP { _, _ in .json(Self.okCompletion) }
        let client = XAIClient(apiKey: "xai-test", model: "grok-test", http: http)
        let result = try await client.complete(messages: [.system("sys"), .user("hi")], temperature: 0.3)
        #expect(result == "Hello there")

        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://api.x.ai/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer xai-test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try bodyJSON(request)
        #expect(body["model"] == "grok-test")
        #expect(body["temperature"]?.doubleValue == 0.3)
        #expect(body["stream"] == nil)
        #expect(body["messages"]?[0]?["role"] == "system")
        #expect(body["messages"]?[0]?["content"] == "sys")
        #expect(body["messages"]?[1]?["role"] == "user")
        #expect(body["messages"]?[1]?["content"] == "hi")
    }

    @Test func perCallModelOverridesAndTemperatureOmitted() async throws {
        let http = MockHTTP { _, _ in .json(Self.okCompletion) }
        let client = XAIClient(apiKey: "k", model: "grok-a", http: http)
        _ = try await client.complete(messages: [.user("hi")], model: "grok-b")
        let body = try bodyJSON(try #require(http.requests.first))
        #expect(body["model"] == "grok-b")
        #expect(body["temperature"] == nil)
    }

    @Test func defaultModelIsConfigurable() {
        #expect(XAIClient.fallbackModel == "grok-4")
        let previous = XAIClient.defaultModel
        XAIClient.defaultModel = "grok-custom"
        defer { XAIClient.defaultModel = previous }
        #expect(XAIClient(apiKey: "k").model == "grok-custom")
        #expect(XAIClient(apiKey: "k", model: "explicit").model == "explicit")
    }

    @Test func customBaseURL() async throws {
        let http = MockHTTP { _, _ in .json(Self.okCompletion) }
        let client = XAIClient(apiKey: "k", model: "m", baseURL: URL(string: "http://localhost:9/v1")!, http: http)
        _ = try await client.complete(messages: [.user("x")])
        #expect(http.requests.first?.url?.absoluteString == "http://localhost:9/v1/chat/completions")
    }

    @Test func openAIStyleErrorIsMapped() async throws {
        let http = MockHTTP { _, _ in
            .json(["error": ["message": "Incorrect API key provided", "type": "invalid_request_error"]], status: 401)
        }
        let client = XAIClient(apiKey: "bad", model: "m", http: http)
        await #expect(throws: XAIError.http(status: 401, message: "Incorrect API key provided")) {
            try await client.complete(messages: [.user("x")])
        }
    }

    @Test func xaiStyleAndRawErrorsAreMapped() {
        let xai = XAIError.from(status: 400, body: Data(#"{"code":"Client specified an invalid argument","error":"Model not found: grok-9"}"#.utf8))
        #expect(xai == .http(status: 400, message: "Model not found: grok-9"))
        let raw = XAIError.from(status: 502, body: Data("Bad Gateway".utf8))
        #expect(raw == .http(status: 502, message: "Bad Gateway"))
        let empty = XAIError.from(status: 500, body: Data())
        if case .http(500, let message) = empty { #expect(!message.isEmpty) } else { Issue.record("wrong case") }
        #expect(XAIError.http(status: 401, message: "nope").errorDescription?.contains("401") == true)
    }

    @Test func missingKeyThrowsWithoutRequest() async {
        let http = MockHTTP { _, _ in .json(Self.okCompletion) }
        let client = XAIClient(apiKey: " ", model: "m", http: http)
        await #expect(throws: XAIError.missingAPIKey) { try await client.complete(messages: [.user("x")]) }
        #expect(http.requests.isEmpty)
    }

    @Test func malformedResponseThrows() async {
        let http = MockHTTP { _, _ in .json(["choices": []]) }
        let client = XAIClient(apiKey: "k", model: "m", http: http)
        await #expect(throws: XAIError.emptyResponse) { try await client.complete(messages: [.user("x")]) }
        let http2 = MockHTTP { _, _ in .text("not json") }
        let client2 = XAIClient(apiKey: "k", model: "m", http: http2)
        await #expect(throws: XAIError.self) { try await client2.complete(messages: [.user("x")]) }
    }

    static let sseBody = """
        data: {"id":"1","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}

        data: {"id":"1","choices":[{"index":0,"delta":{"content":"Hel"}}]}

        : keep-alive comment

        data: {"id":"1","choices":[{"index":0,"delta":{"content":"lo — wörld ✅"}}]}

        data: {"id":"1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        data: {"id":"1","choices":[{"index":0,"delta":{"content":"IGNORED"}}]}


        """

    @Test(arguments: [1, 2, 3, 7, 64, 100_000])
    func streamParsesSplitChunks(chunkSize: Int) async throws {
        let http = MockHTTP { _, _ in MockReply(chunks: sseChunks(Self.sseBody, size: chunkSize)) }
        let client = XAIClient(apiKey: "k", model: "grok-s", http: http)
        var pieces: [String] = []
        for try await piece in client.stream(messages: [.user("hi")], temperature: 0.5) { pieces.append(piece) }
        #expect(pieces.joined() == "Hello — wörld ✅")
        #expect(pieces.count == 2)

        let request = try #require(http.requests.first)
        let body = try bodyJSON(request)
        #expect(body["stream"] == true)
        #expect(body["model"] == "grok-s")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    }

    @Test func streamHandlesCRLFAndMissingDone() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"b\"}}]}"
        let http = MockHTTP { _, _ in MockReply(chunks: sseChunks(body, size: 5)) }
        let client = XAIClient(apiKey: "k", model: "m", http: http)
        var out = ""
        for try await piece in client.stream(messages: [.user("x")]) { out += piece }
        #expect(out == "ab")
    }

    @Test func streamHTTPErrorIsMapped() async {
        let http = MockHTTP { _, _ in .json(["error": ["message": "Rate limit exceeded"]], status: 429) }
        let client = XAIClient(apiKey: "k", model: "m", http: http)
        await #expect(throws: XAIError.http(status: 429, message: "Rate limit exceeded")) {
            for try await _ in client.stream(messages: [.user("x")]) {}
        }
    }

    @Test func streamInBandErrorThrows() async {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}\n\ndata: {\"error\":{\"message\":\"overloaded\",\"code\":503}}\n\n"
        let http = MockHTTP { _, _ in MockReply(chunks: [Data(body.utf8)]) }
        let client = XAIClient(apiKey: "k", model: "m", http: http)
        await #expect(throws: XAIError.http(status: 503, message: "overloaded")) {
            for try await _ in client.stream(messages: [.user("x")]) {}
        }
    }

    @Test func listModels() async throws {
        let http = MockHTTP { _, _ in
            .json(["object": "list", "data": [["id": "grok-4", "object": "model"], ["id": "grok-3-mini", "object": "model"]]])
        }
        let client = XAIClient(apiKey: "k", model: "m", http: http)
        #expect(try await client.listModels() == ["grok-3-mini", "grok-4"])
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.x.ai/v1/models")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }
}

@Suite struct SSEParserTests {
    @Test func multiLineDataAndComments() {
        var parser = SSEParser()
        var events = parser.feed(Data(": hi\nevent: message\ndata: line1\ndata: line2\n\n".utf8))
        #expect(events == ["line1\nline2"])
        events = parser.feed(Data("data:nospace\n\n".utf8))
        #expect(events == ["nospace"])
    }

    @Test func splitInsideMultibyteCharacter() {
        let bytes = Array("data: héllo\n\n".utf8)
        var parser = SSEParser()
        var events: [String] = []
        for b in bytes { events += parser.feed(Data([b])) }
        #expect(events == ["héllo"])
    }

    @Test func finishFlushesTrailingEvent() {
        var parser = SSEParser()
        #expect(parser.feed(Data("data: [DO".utf8)).isEmpty)
        #expect(parser.feed(Data("NE]".utf8)).isEmpty)
        #expect(parser.finish() == ["[DONE]"])
        #expect(parser.finish().isEmpty)
    }
}
