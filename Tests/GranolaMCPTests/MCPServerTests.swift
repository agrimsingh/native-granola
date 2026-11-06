import Foundation
import GranolaCore
import Testing
@testable import GranolaMCP

private let utc = TimeZone(identifier: "UTC")!
/// 2026-11-07 12:00:00 UTC
private let noon = Date(timeIntervalSince1970: 1_794_052_800)

private func makeServer(_ store: Store, now: Date = noon) -> MCPServer {
    MCPServer(store: store, timeZone: utc, now: { now })
}

private func json(_ line: String?) throws -> [String: Any] {
    let line = try #require(line)
    #expect(!line.contains("\n"))
    return try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
}

private func request(_ server: MCPServer, _ method: String, _ params: [String: Any]? = nil, id: Any = 1) throws -> [String: Any] {
    var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
    if let params { message["params"] = params }
    let line = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
    return try json(server.handle(line))
}

private func callTool(_ server: MCPServer, _ name: String, _ arguments: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
    let response = try request(server, "tools/call", ["name": name, "arguments": arguments])
    let result = try #require(response["result"] as? [String: Any], "no result in \(response)")
    let content = try #require(result["content"] as? [[String: Any]])
    #expect(content.count == 1)
    #expect(content[0]["type"] as? String == "text")
    return (try #require(content[0]["text"] as? String), result["isError"] as? Bool ?? false)
}

private func errorCode(_ response: [String: Any]) -> Int? {
    (response["error"] as? [String: Any])?["code"] as? Int
}

/// Two finished meetings and nothing in progress.
private func seededStore() throws -> (Store, past: Meeting, recent: Meeting) {
    let store = try Store.inMemory()
    let past = Meeting(
        id: "m-past", title: "Pricing review",
        startedAt: noon.addingTimeInterval(-3 * 86400), endedAt: noon.addingTimeInterval(-3 * 86400 + 1800),
        attendees: [Attendee(name: "Sam", email: "sam@x.com")], sourceApp: "us.zoom.xos",
        rawNotes: "discuss enterprise tier", enhancedNotes: "## Summary\nAgreed on **enterprise** pricing.",
        notionPageURL: "https://notion.so/pricing")
    let recent = Meeting(
        id: "m-recent", title: "Weekly sync",
        startedAt: noon.addingTimeInterval(-7200), endedAt: noon.addingTimeInterval(-7200 + 3900),
        attendees: [Attendee(email: "lee@x.com")])
    try store.upsertMeeting(past)
    try store.upsertMeeting(recent)
    try store.upsertSegment(TranscriptSegment(meetingID: past.id, source: .microphone, text: "Hello everyone", startOffset: 1, endOffset: 2))
    try store.upsertSegment(TranscriptSegment(meetingID: past.id, source: .system, text: "Let's talk about the roadmap", startOffset: 65, endOffset: 68))
    return (store, past, recent)
}

@Suite struct ProtocolTests {
    @Test func initializeNegotiatesVersion() throws {
        let server = makeServer(try Store.inMemory())
        for version in MCPServer.supportedProtocolVersions {
            let r = try request(server, "initialize", ["protocolVersion": version, "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]])
            #expect((r["result"] as? [String: Any])?["protocolVersion"] as? String == version)
        }
        let unknown = try request(server, "initialize", ["protocolVersion": "1999-01-01"])
        #expect((unknown["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
        let noParams = try request(server, "initialize")
        let result = try #require(noParams["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect(noParams["jsonrpc"] as? String == "2.0")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "native-granola")
        #expect((result["serverInfo"] as? [String: Any])?["version"] as? String == "0.1.0")
        let tools = (result["capabilities"] as? [String: Any])?["tools"] as? [String: Any]
        #expect(tools?["listChanged"] as? Bool == false)
        #expect((result["instructions"] as? String)?.contains("search_meetings") == true)
    }

    @Test func echoesStringAndNumericIDs() throws {
        let server = makeServer(try Store.inMemory())
        #expect(try request(server, "ping", id: "abc-1")["id"] as? String == "abc-1")
        let numeric = try #require(server.handle(#"{"jsonrpc":"2.0","id":42,"method":"ping"}"#))
        #expect(numeric == #"{"id":42,"jsonrpc":"2.0","result":{}}"#)
    }

    @Test func notificationsProduceNoOutput() throws {
        let server = makeServer(try Store.inMemory())
        #expect(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(server.handle(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#) == nil)
        #expect(server.handle(#"{"jsonrpc":"2.0","method":"something/unknown"}"#) == nil)
        #expect(server.handle(#"{"jsonrpc":"2.0","id":5,"result":{}}"#) == nil)
    }

    @Test func parseError() throws {
        let server = makeServer(try Store.inMemory())
        let r = try json(server.handle("{not json"))
        #expect(errorCode(r) == -32700)
        #expect(r["id"] is NSNull)
    }

    @Test func invalidRequests() throws {
        let server = makeServer(try Store.inMemory())
        #expect(errorCode(try json(server.handle(#""hello""#))) == -32600)
        #expect(errorCode(try json(server.handle(#"{"jsonrpc":"2.0","id":1}"#))) == -32600)
    }

    @Test func unknownMethod() throws {
        let server = makeServer(try Store.inMemory())
        let r = try request(server, "resources/list", id: 9)
        #expect(errorCode(r) == -32601)
        #expect(r["id"] as? Int == 9)
    }

    @Test func badParams() throws {
        let server = makeServer(try Store.inMemory())
        #expect(errorCode(try json(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":[1]}"#))) == -32602)
        #expect(errorCode(try request(server, "tools/call", [:])) == -32602)
        #expect(errorCode(try request(server, "tools/call", ["name": "list_meetings", "arguments": "x"])) == -32602)
        // Null arguments are fine.
        let r = try json(server.handle(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_meetings","arguments":null}}"#))
        #expect(r["result"] != nil)
    }

    @Test func unknownTool() throws {
        let server = makeServer(try Store.inMemory())
        let r = try request(server, "tools/call", ["name": "delete_everything", "arguments": [:]])
        #expect(errorCode(r) == -32602)
    }

    @Test func batch() throws {
        let server = makeServer(try Store.inMemory())
        let line = try #require(server.handle(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"nope"}]"#))
        let responses = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [[String: Any]])
        #expect(responses.count == 2)
        #expect(errorCode(responses[1]) == -32601)
        #expect(server.handle(#"[{"jsonrpc":"2.0","method":"notifications/initialized"}]"#) == nil)
    }

    @Test func toolsListShape() throws {
        let server = makeServer(try Store.inMemory())
        let result = try #require(try request(server, "tools/list")["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        #expect(names == ["list_meetings", "get_meeting", "get_transcript", "search_meetings", "get_current_meeting"])
        for tool in tools {
            #expect(((tool["description"] as? String)?.count ?? 0) > 50)
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            let properties = try #require(schema["properties"] as? [String: Any])
            for name in schema["required"] as? [String] ?? [] { #expect(properties[name] != nil) }
            #expect((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
        }
        let getMeeting = try #require(tools.first { $0["name"] as? String == "get_meeting" })
        #expect((getMeeting["inputSchema"] as? [String: Any])?["required"] as? [String] == ["meeting_id"])
    }
}

@Suite struct ToolTests {
    @Test func listMeetings() throws {
        let (store, _, _) = try seededStore()
        let server = makeServer(store)
        let r = try callTool(server, "list_meetings")
        #expect(!r.isError)
        let text = r.text
        let recent = try #require(text.range(of: "Weekly sync")), past = try #require(text.range(of: "Pricing review"))
        #expect(recent.lowerBound < past.lowerBound)
        #expect(text.contains("`m-recent`"))
        #expect(text.contains("start: Sat 2026-11-07 10:00 GMT"))
        #expect(text.contains("1h 05m"))
        #expect(text.contains("30m"))
        #expect(text.contains("Sam <sam@x.com>"))
        #expect(text.contains("lee@x.com"))
        #expect(text.contains("enhanced notes: yes"))
        #expect(text.contains("enhanced notes: no"))

        let since = try callTool(server, "list_meetings", ["since": "2026-11-06"])
        #expect(since.text.contains("Weekly sync") && !since.text.contains("Pricing review"))
        let until = try callTool(server, "list_meetings", ["until": "2026-11-04"])
        #expect(until.text.contains("Pricing review") && !until.text.contains("Weekly sync"))
        let iso = try callTool(server, "list_meetings", ["since": "2026-11-07T09:00:00Z", "limit": "5"])
        #expect(iso.text.contains("Weekly sync") && !iso.text.contains("Pricing review"))
        let limited = try callTool(server, "list_meetings", ["limit": 1])
        #expect(limited.text.contains("Weekly sync") && !limited.text.contains("Pricing review"))

        let bad = try callTool(server, "list_meetings", ["since": "last tuesday"])
        #expect(bad.isError)
        #expect(bad.text.contains("since"))
    }

    @Test func listMeetingsEmpty() throws {
        let r = try callTool(makeServer(try Store.inMemory()), "list_meetings")
        #expect(!r.isError)
        #expect(r.text.contains("No meetings found"))
    }

    @Test func getMeeting() throws {
        let (store, past, _) = try seededStore()
        let server = makeServer(store)
        let r = try callTool(server, "get_meeting", ["meeting_id": past.id])
        #expect(!r.isError)
        #expect(r.text.hasPrefix("# Pricing review"))
        #expect(r.text.contains("Agreed on **enterprise** pricing."))
        #expect(r.text.contains("discuss enterprise tier"))
        #expect(r.text.contains("https://notion.so/pricing"))
        #expect(r.text.contains("Zoom (us.zoom.xos)"))
        #expect(r.text.contains("Sam <sam@x.com>"))
        #expect(r.text.contains("2 transcript segments"))
        #expect(!r.text.contains("Hello everyone"))

        let full = try callTool(server, "get_meeting", ["meeting_id": past.id, "include_transcript": true])
        #expect(full.text.contains("[00:01] Me: Hello everyone\n[01:05] Them: Let's talk about the roadmap"))
    }

    @Test func unknownMeetingID() throws {
        let server = makeServer(try seededStore().0)
        for tool in ["get_meeting", "get_transcript"] {
            let r = try callTool(server, tool, ["meeting_id": "nope"])
            #expect(r.isError)
            #expect(r.text.contains("nope"))
        }
        let missing = try callTool(server, "get_meeting")
        #expect(missing.isError)
        #expect(missing.text.contains("meeting_id"))
    }

    @Test func getTranscript() throws {
        let (store, past, recent) = try seededStore()
        let server = makeServer(store)
        let r = try callTool(server, "get_transcript", ["meeting_id": past.id])
        #expect(!r.isError)
        #expect(r.text.contains("\"Me\" = the user (microphone)"))
        #expect(r.text.contains("[00:01] Me: Hello everyone\n[01:05] Them: Let's talk about the roadmap"))
        #expect(!r.text.contains("truncated"))

        let empty = try callTool(server, "get_transcript", ["meeting_id": recent.id])
        #expect(!empty.isError)
        #expect(empty.text.contains("No transcript"))
    }

    @Test func getTranscriptTruncates() throws {
        let store = try Store.inMemory()
        let m = Meeting(id: "long", title: "Long", startedAt: noon, endedAt: noon.addingTimeInterval(3600))
        try store.upsertMeeting(m)
        for i in 0..<200 {
            try store.upsertSegment(TranscriptSegment(meetingID: m.id, source: i % 2 == 0 ? .microphone : .system,
                                                      text: "sentence number \(i) " + String(repeating: "x", count: 40),
                                                      startOffset: Double(i * 10), endOffset: Double(i * 10 + 5)))
        }
        let r = try callTool(makeServer(store), "get_transcript", ["meeting_id": m.id, "max_chars": 2000])
        #expect(r.text.contains("sentence number 0 "))
        #expect(!r.text.contains("sentence number 199 "))
        #expect(r.text.contains("[Transcript truncated"))
        #expect(r.text.count < 3000)
    }

    @Test func searchMeetings() throws {
        let (store, past, _) = try seededStore()
        let server = makeServer(store)
        let r = try callTool(server, "search_meetings", ["query": "roadmap"])
        #expect(!r.isError)
        #expect(r.text.contains("## Pricing review"))
        #expect(r.text.contains("`\(past.id)`"))
        #expect(r.text.contains("transcript [01:05]"))
        #expect(r.text.contains("**roadmap**"))

        let notes = try callTool(server, "search_meetings", ["query": "enterprise"])
        #expect(notes.text.contains("1 meeting"))

        let none = try callTool(server, "search_meetings", ["query": "zebra"])
        #expect(!none.isError)
        #expect(none.text.contains("No meetings matched"))

        #expect(try callTool(server, "search_meetings", ["query": "  "]).isError)
    }

    @Test func currentMeeting() throws {
        let (store, _, _) = try seededStore()
        let server = makeServer(store)
        let none = try callTool(server, "get_current_meeting")
        #expect(!none.isError)
        #expect(none.text.contains("No meeting is in progress"))

        let live = Meeting(id: "live", title: "Customer call", startedAt: noon.addingTimeInterval(-1500),
                           attendees: [Attendee(name: "Ana")], sourceApp: "com.microsoft.teams2", rawNotes: "ask about renewal")
        try store.upsertMeeting(live)
        try store.upsertSegment(TranscriptSegment(meetingID: live.id, source: .microphone, text: "early chatter", startOffset: 10, endOffset: 12))
        try store.upsertSegment(TranscriptSegment(meetingID: live.id, source: .system, text: "renewal is due in March", startOffset: 1200, endOffset: 1205))
        try store.upsertSegment(TranscriptSegment(meetingID: live.id, source: .microphone, text: "great, thanks", startOffset: 1450, endOffset: 1452))

        let r = try callTool(server, "get_current_meeting", ["last_minutes": 10])
        #expect(!r.isError)
        #expect(r.text.contains("# In progress: Customer call"))
        #expect(r.text.contains("25m ago"))
        #expect(r.text.contains("ask about renewal"))
        #expect(r.text.contains("Microsoft Teams"))
        #expect(r.text.contains("[20:00] Them: renewal is due in March\n[24:10] Me: great, thanks"))
        #expect(!r.text.contains("early chatter"))

        let all = try callTool(server, "get_current_meeting", ["last_minutes": 60])
        #expect(all.text.contains("early chatter"))
    }
}

@Suite struct StdioTests {
    @Test func runLoopRespondsAndExitsOnEOF() throws {
        let (store, past, _) = try seededStore()
        let server = makeServer(store)
        let input = Pipe(), output = Pipe()
        let lines = [
            #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"cursor","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            "",
            #"{"jsonrpc":"2.0","id":"t","method":"tools/list"}"# + "\r",
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_transcript","arguments":{"meeting_id":"\#(past.id)"}}}"#,
        ]
        // Final message deliberately has no trailing newline.
        input.fileHandleForWriting.write(Data(lines.joined(separator: "\n").utf8))
        try input.fileHandleForWriting.close()

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            server.run(input: input.fileHandleForReading, output: output.fileHandleForWriting)
            try? output.fileHandleForWriting.close()
            done.signal()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        #expect(done.wait(timeout: .now() + 10) == .success)

        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasSuffix("\n"))
        let responses = try text.split(separator: "\n").map { try json(String($0)) }
        #expect(responses.count == 3)
        #expect(responses[0]["id"] as? Int == 0)
        #expect((responses[0]["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-03-26")
        #expect(responses[1]["id"] as? String == "t")
        #expect(((responses[1]["result"] as? [String: Any])?["tools"] as? [Any])?.count == 5)
        let content = (responses[2]["result"] as? [String: Any])?["content"] as? [[String: Any]]
        #expect((content?.first?["text"] as? String)?.contains("Them: Let's talk about the roadmap") == true)
    }
}
