import Foundation
import GranolaCore
import Testing
@testable import GranolaIntelligence

@Suite struct NotionClientTests {
    static let schema: JSONValue = [
        "object": "database", "id": "db",
        "properties": [
            "Name": ["id": "title", "type": "title", "title": [:]],
            "Date": ["id": "a", "type": "date", "date": [:]],
            "Attendees": ["id": "b", "type": "rich_text", "rich_text": [:]],
            "Source": ["id": "c", "type": "select", "select": ["options": []]],
            "Duration (min)": ["id": "d", "type": "number", "number": ["format": "number"]],
            "Granola ID": ["id": "e", "type": "rich_text", "rich_text": [:]],
        ],
    ]

    static func client(_ http: MockHTTP) -> NotionClient {
        NotionClient(token: "secret_test", http: http, sleep: { _ in })
    }

    // MARK: Page IDs

    @Test(arguments: [
        ("https://www.notion.so/myteam/Meeting-Notes-0123456789abcdef0123456789ABCDEF", "01234567-89ab-cdef-0123-456789abcdef"),
        ("https://www.notion.so/myteam/Meeting-Notes-0123456789abcdef0123456789abcdef?pvs=4", "01234567-89ab-cdef-0123-456789abcdef"),
        ("https://notion.so/0123456789abcdef0123456789abcdef", "01234567-89ab-cdef-0123-456789abcdef"),
        ("https://www.notion.so/ws/fedcba9876543210fedcba9876543210?v=0123456789abcdef0123456789abcdef", "fedcba98-7654-3210-fedc-ba9876543210"),
        ("https://www.notion.so/ws/Home-11111111111111111111111111111111?p=22222222222222222222222222222222&pm=s", "22222222-2222-2222-2222-222222222222"),
        ("https://acme.notion.site/Cafe-Plans-0123456789abcdef0123456789abcdef#heading", "01234567-89ab-cdef-0123-456789abcdef"),
        ("0123456789abcdef0123456789abcdef", "01234567-89ab-cdef-0123-456789abcdef"),
        ("  01234567-89ab-cdef-0123-456789abcdef \n", "01234567-89ab-cdef-0123-456789abcdef"),
        ("notion.so/x/Page-0123456789abcdef0123456789abcdef/", "01234567-89ab-cdef-0123-456789abcdef"),
    ])
    func pageIDParsing(input: String, expected: String) {
        #expect(NotionClient.pageID(fromURL: input) == expected)
    }

    @Test(arguments: ["", "https://www.notion.so/", "not an id", "0123456789abcdef", "https://notion.so/Page-0123456789abcdef0123456789abcdeg"])
    func pageIDRejectsInvalid(input: String) {
        #expect(NotionClient.pageID(fromURL: input) == nil)
    }

    // MARK: Requests

    @Test func createDatabaseBody() async throws {
        let http = MockHTTP { _, _ in .json(["object": "database", "id": "new-db-id"]) }
        let id = try await Self.client(http).createMeetingsDatabase(
            parentPageID: "https://www.notion.so/Home-0123456789abcdef0123456789abcdef", title: "Granola Meetings")
        #expect(id == "new-db-id")
        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == "https://api.notion.com/v1/databases")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret_test")
        #expect(request.value(forHTTPHeaderField: "Notion-Version") == "2022-06-28")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try bodyJSON(request)
        #expect(body["parent"]?["page_id"] == "01234567-89ab-cdef-0123-456789abcdef")
        #expect(body["parent"]?["type"] == "page_id")
        #expect(body["title"]?[0]?["text"]?["content"] == "Granola Meetings")
        let props = try #require(body["properties"]?.objectValue)
        #expect(Set(props.keys) == ["Name", "Date", "Attendees", "Source", "Duration (min)", "Granola ID"])
        #expect(props["Name"]?["title"] == [:])
        #expect(props["Date"]?["date"] == [:])
        #expect(props["Attendees"]?["rich_text"] == [:])
        #expect(props["Source"]?["select"] != nil)
        #expect(props["Duration (min)"]?["number"]?["format"] == "number")
        #expect(props["Granola ID"]?["rich_text"] == [:])
    }

    @Test func createDatabaseRejectsBadParent() async {
        let http = MockHTTP { _, _ in .json([:]) }
        await #expect(throws: NotionError.invalidPageID("nope")) {
            try await Self.client(http).createMeetingsDatabase(parentPageID: "nope")
        }
        #expect(http.requests.isEmpty)
    }

    @Test func findDatabase() async throws {
        let http = MockHTTP { _, _ in
            .json(["results": [
                ["object": "database", "id": "archived", "archived": true, "title": [["plain_text": "Meetings"]]],
                ["object": "database", "id": "other", "title": [["plain_text": "Meetings Archive"]]],
                ["object": "database", "id": "match", "title": [["plain_text": "Meet"], ["plain_text": "ings"]]],
            ]])
        }
        let id = try await Self.client(http).findDatabase(title: "meetings")
        #expect(id == "match")
        let request = try #require(http.requests.first)
        #expect(request.url?.path == "/v1/search")
        let body = try bodyJSON(request)
        #expect(body["query"] == "meetings")
        #expect(body["filter"]?["value"] == "database")
        #expect(body["filter"]?["property"] == "object")

        let none = MockHTTP { _, _ in .json(["results": []]) }
        #expect(try await Self.client(none).findDatabase(title: "x") == nil)
    }

    @Test func errorMappingAndRetryAfter() async throws {
        let attempts = MockHTTP { _, index in
            index < 2 ? .json(["object": "error", "status": 429, "code": "rate_limited", "message": "slow down"], status: 429, headers: ["Retry-After": "2"])
                : .json(["name": "Granola Bot"])
        }
        let delays = DelayRecorder()
        let client = NotionClient(token: "t", http: attempts, sleep: { await delays.add($0) })
        #expect(try await client.me() == "Granola Bot")
        #expect(attempts.requests.count == 3)
        #expect(await delays.values == [2, 2])

        let notFound = MockHTTP { _, _ in
            .json(["object": "error", "status": 404, "code": "object_not_found", "message": "Could not find database"], status: 404)
        }
        await #expect(throws: NotionError.http(status: 404, code: "object_not_found", message: "Could not find database")) {
            try await Self.client(notFound).me()
        }

        let alwaysLimited = MockHTTP { _, _ in .json(["code": "rate_limited", "message": "no"], status: 429) }
        let limited = NotionClient(token: "t", http: alwaysLimited, maxRetries: 2, sleep: { _ in })
        await #expect(throws: NotionError.self) { try await limited.me() }
        #expect(alwaysLimited.requests.count == 3)
    }

    // MARK: Export

    static func meeting(enhanced: String?, raw: String = "") -> Meeting {
        Meeting(
            id: "meeting-123",
            title: "Acme renewal",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_000_000 + 45 * 60),
            attendees: [Attendee(name: "Dana Lee", email: "dana@acme.com"), Attendee(email: "ops@acme.com")],
            sourceApp: "us.zoom.xos",
            rawNotes: raw,
            enhancedNotes: enhanced
        )
    }

    /// Routes: GET database → schema; POST pages → page; PATCH children → results echoing block types.
    static func exportMock() -> MockHTTP {
        MockHTTP { request, index in
            let path = request.url!.path
            switch (request.httpMethod!, path) {
            case ("GET", _) where path.hasPrefix("/v1/databases/"):
                return .json(schema)
            case ("POST", "/v1/pages"):
                return .json(["object": "page", "id": "page-1", "url": "https://www.notion.so/Acme-renewal-page1"])
            case ("PATCH", _) where path.hasSuffix("/children"):
                let children = try bodyJSON(request)["children"]?.arrayValue ?? []
                let results: [JSONValue] = children.enumerated().map { i, child in
                    ["object": "block", "id": .string("blk-\(index)-\(i)"), "type": child["type"] ?? "paragraph"]
                }
                return .json(["object": "list", "results": .array(results)])
            default:
                return .json(["message": .string("unexpected \(path)")], status: 400)
            }
        }
    }

    @Test func exportSmallMeetingProperties() async throws {
        let http = Self.exportMock()
        let segments = [
            TranscriptSegment(meetingID: "meeting-123", source: .microphone, text: "Hi Dana.", startOffset: 1, endOffset: 2),
            TranscriptSegment(meetingID: "meeting-123", source: .microphone, text: "Thanks for joining.", startOffset: 3, endOffset: 4),
            TranscriptSegment(meetingID: "meeting-123", source: .system, text: "Happy to.", startOffset: 5, endOffset: 6),
        ]
        let url = try await Self.client(http).exportMeeting(
            Self.meeting(enhanced: "### Summary\n- SSO needed", raw: "sso?"), segments: segments,
            databaseID: "0123456789abcdef0123456789abcdef")
        #expect(url.absoluteString == "https://www.notion.so/Acme-renewal-page1")

        let requests = http.requests
        #expect(requests.map { "\($0.httpMethod!) \($0.url!.path)" } == [
            "GET /v1/databases/01234567-89ab-cdef-0123-456789abcdef",
            "POST /v1/pages",
        ])
        let page = try bodyJSON(requests[1])
        #expect(page["parent"]?["database_id"] == "01234567-89ab-cdef-0123-456789abcdef")
        let props = try #require(page["properties"])
        #expect(props["Name"]?["title"]?[0]?["text"]?["content"] == "Acme renewal")
        #expect(props["Date"]?["date"]?["start"] == "2026-05-28T20:26:40Z")
        #expect(props["Date"]?["date"]?["end"] == "2026-05-28T21:11:40Z")
        #expect(props["Attendees"]?["rich_text"]?[0]?["text"]?["content"] == "Dana Lee, ops@acme.com")
        #expect(props["Source"]?["select"]?["name"] == "Zoom")
        #expect(props["Duration (min)"]?["number"]?.doubleValue == 45)
        #expect(props["Granola ID"]?["rich_text"]?[0]?["text"]?["content"] == "meeting-123")

        let initial = try #require(page["children"]?.arrayValue)
        try #require(initial.map { $0["type"]?.stringValue ?? "" } == ["heading_3", "bulleted_list_item", "divider", "heading_2", "paragraph", "toggle"])
        #expect(initial[3]["heading_2"]?["rich_text"]?[0]?["text"]?["content"] == "My notes")

        let toggle = initial[5]
        #expect(toggle["type"] == "toggle")
        #expect(toggle["toggle"]?["rich_text"]?[0]?["text"]?["content"] == "Transcript")
        let paragraphs = try #require(toggle["toggle"]?["children"]?.arrayValue)
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0]["paragraph"]?["rich_text"]?[0]?["text"]?["content"] == "[00:01] Me: ")
        #expect(paragraphs[0]["paragraph"]?["rich_text"]?[1]?["text"]?["content"] == "Hi Dana. Thanks for joining.")
        #expect(paragraphs[1]["paragraph"]?["rich_text"]?[0]?["text"]?["content"] == "[00:05] Them: ")
    }

    @Test func exportOnlyIncludesPropertiesInSchema() {
        let props = NotionClient.pageProperties(meeting: Self.meeting(enhanced: nil), schema: ["Title": "title", "Date": "date", "Source": "rich_text"])
        #expect(Set(props.keys) == ["Title", "Date"])
    }

    @Test func exportBatchesLargePages() async throws {
        let http = Self.exportMock()
        let enhanced = (0..<250).map { "- point \($0)" }.joined(separator: "\n")
        var segments: [TranscriptSegment] = []
        for i in 0..<250 {
            segments.append(TranscriptSegment(meetingID: "m", source: i % 2 == 0 ? .microphone : .system,
                                              text: "line \(i)", startOffset: Double(i), endOffset: Double(i)))
        }
        _ = try await Self.client(http).exportMeeting(Self.meeting(enhanced: enhanced), segments: segments, databaseID: "0123456789abcdef0123456789abcdef")

        let requests = http.requests
        let summary = requests.map { "\($0.httpMethod!) \($0.url!.path)" }
        #expect(summary == [
            "GET /v1/databases/01234567-89ab-cdef-0123-456789abcdef",
            "POST /v1/pages",                          // bullets 0..<100
            "PATCH /v1/blocks/page-1/children",        // bullets 100..<200
            "PATCH /v1/blocks/page-1/children",        // bullets 200..<250 + toggle(100 inline)
            "PATCH /v1/blocks/blk-3-50/children",      // transcript 100..<200
            "PATCH /v1/blocks/blk-3-50/children",      // transcript 200..<250
        ])
        var counts: [Int] = []
        for r in requests.dropFirst() {
            let body = try bodyJSON(r)
            let children = body["children"]?.arrayValue ?? []
            #expect(children.count <= 100)
            counts.append(children.count)
        }
        #expect(counts == [100, 100, 51, 100, 50])
        let lastBatch = try bodyJSON(requests[3])["children"]?.arrayValue ?? []
        #expect(lastBatch.last?["toggle"]?["children"]?.arrayValue?.count == 100)
        let firstTranscriptBatch = try bodyJSON(requests[4])["children"]?.arrayValue ?? []
        #expect(firstTranscriptBatch.first?["paragraph"]?["rich_text"]?[0]?["text"]?["content"] == "[01:40] Me: ")
    }

    @Test func exportDefersDeepNesting() async throws {
        let http = Self.exportMock()
        let enhanced = "- a\n  - b\n    - c"
        _ = try await Self.client(http).exportMeeting(Self.meeting(enhanced: enhanced), segments: [], databaseID: "0123456789abcdef0123456789abcdef")
        let requests = http.requests
        #expect(requests.map { "\($0.httpMethod!) \($0.url!.path)" } == [
            "GET /v1/databases/01234567-89ab-cdef-0123-456789abcdef",
            "POST /v1/pages",
            "PATCH /v1/blocks/page-1/children",
            "PATCH /v1/blocks/blk-2-0/children",
        ])
        let page = try bodyJSON(requests[1])
        #expect(page["children"] == nil)
        let top = try bodyJSON(requests[2])["children"]?.arrayValue ?? []
        #expect(top.count == 1 && top[0]["bulleted_list_item"]?["children"] == nil)
        let second = try bodyJSON(requests[3])["children"]?.arrayValue ?? []
        #expect(second[0]["bulleted_list_item"]?["rich_text"]?[0]?["text"]?["content"] == "b")
        #expect(second[0]["bulleted_list_item"]?["children"]?[0]?["bulleted_list_item"]?["rich_text"]?[0]?["text"]?["content"] == "c")
    }

    @Test func exportFailureArchivesPartialPage() async throws {
        let http = MockHTTP { request, _ in
            switch request.httpMethod! {
            case "GET": return .json(Self.schema)
            case "POST": return .json(["id": "page-9", "url": "https://www.notion.so/p9"])
            default:
                if request.url!.path.hasSuffix("/children") {
                    return .json(["code": "validation_error", "message": "bad block"], status: 400)
                }
                return .json(["id": "page-9", "archived": true])
            }
        }
        let segments = (0..<150).map {
            TranscriptSegment(meetingID: "m", source: $0 % 2 == 0 ? .system : .microphone, text: "hi", startOffset: Double($0), endOffset: Double($0))
        }
        await #expect(throws: NotionError.http(status: 400, code: "validation_error", message: "bad block")) {
            try await Self.client(http).exportMeeting(Self.meeting(enhanced: nil), segments: segments, databaseID: "0123456789abcdef0123456789abcdef")
        }
        let last = try #require(http.requests.last)
        #expect(last.httpMethod == "PATCH" && last.url!.path == "/v1/pages/page-9")
        #expect(try bodyJSON(last)["archived"] == true)
    }

    @Test func longTranscriptTextSplitInto2000CharItems() {
        let text = String(repeating: "word ", count: 1000)
        let blocks = NotionClient.transcriptBlocks([TranscriptSegment(meetingID: "m", source: .system, text: text, startOffset: 0, endOffset: 1)])
        #expect(blocks.count == 1)
        let lengths = blocks[0].richText.map { $0.content.utf16.count }
        #expect(lengths.allSatisfy { $0 <= 2000 })
        #expect(lengths.count == 4)
    }

    @Test func transcriptParagraphsAreCapped() {
        let segments = (0..<100).map {
            TranscriptSegment(meetingID: "m", source: .system, text: String(repeating: "x", count: 200), startOffset: Double($0), endOffset: Double($0))
        }
        let blocks = NotionClient.transcriptBlocks(segments)
        #expect(blocks.count > 1)
        #expect(blocks.allSatisfy { $0.plainText.count <= NotionClient.maxTranscriptParagraphLength + 20 })
    }

    @Test func batchingRespectsByteBudget() {
        let big = NotionBlock.paragraph(String(repeating: "y", count: 1900))
        let many = Array(repeating: big, count: 5).flatMap { _ in Array(repeating: big, count: 60) }
        let prepared = many.map(NotionClient.prepare)
        let batches = NotionClient.batches(prepared)
        #expect(batches.allSatisfy { $0.count <= 100 && $0.reduce(0) { $0 + $1.bytes } <= NotionClient.maxRequestBytes })
        #expect(batches.map(\.count).reduce(0, +) == 300)
    }
}

actor DelayRecorder {
    var values: [Double] = []
    func add(_ v: Double) { values.append(v) }
}
