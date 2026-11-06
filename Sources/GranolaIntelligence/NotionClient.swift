import Foundation
import GranolaCore

public enum NotionError: Error, LocalizedError, Equatable {
    case missingToken
    case invalidPageID(String)
    /// Non-2xx response with Notion's error `code` (e.g. "object_not_found") and message.
    case http(status: Int, code: String?, message: String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "No Notion integration token configured. Add one in Settings or set NOTION_TOKEN."
        case .invalidPageID(let input):
            return "Couldn't find a Notion page ID in \"\(input)\"."
        case .http(let status, let code, let message):
            var hint = ""
            if status == 401 { hint = " Check your Notion integration token." }
            if status == 404 || code == "object_not_found" {
                hint = " Make sure the page or database is shared with your integration (••• → Connections)."
            }
            return "Notion API error \(status)\(code.map { " (\($0))" } ?? ""): \(message)\(hint)"
        case .invalidResponse(let detail):
            return "Unexpected response from Notion: \(detail)"
        }
    }

    static func from(status: Int, body: Data) -> NotionError {
        let json = try? JSONValue.decode(body)
        let message = json?["message"]?.stringValue
            ?? String(decoding: body.prefix(1000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .http(
            status: status, code: json?["code"]?.stringValue,
            message: message.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : message
        )
    }
}

/// Minimal Notion REST client for exporting meetings to a database.
public struct NotionClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.notion.com/v1")!
    public static let apiVersion = "2022-06-28"
    public static let maxChildrenPerRequest = 100
    /// Notion allows 1000 block elements and 500KB per request; stay under both.
    static let maxBlockElementsPerRequest = 900
    static let maxRequestBytes = 400_000
    static let maxTranscriptParagraphLength = 3000

    public static let propertyNames = (
        name: "Name", date: "Date", attendees: "Attendees", source: "Source",
        duration: "Duration (min)", granolaID: "Granola ID"
    )

    public var token: String
    public var baseURL: URL
    public var http: any HTTPClient
    /// Retries for 429 (rate limited) and 409 (save conflict) responses.
    public var maxRetries: Int
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        token: String,
        baseURL: URL = NotionClient.defaultBaseURL,
        http: any HTTPClient = URLSessionHTTPClient(),
        maxRetries: Int = 3,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.token = token
        self.baseURL = baseURL
        self.http = http
        self.maxRetries = maxRetries
        self.sleep = sleep
    }

    /// Builds a client from the stored `notionToken`; throws `NotionError.missingToken` if unset.
    public init(secrets: Secrets, http: any HTTPClient = URLSessionHTTPClient()) throws {
        guard let token = secrets.get(.notionToken) else { throw NotionError.missingToken }
        self.init(token: token, http: http)
    }

    // MARK: Page IDs

    /// Extracts the 32-hex page/database ID from a Notion URL (including `?p=` peek links) or a raw ID,
    /// formatted as a lowercase dashed UUID.
    public static func pageID(fromURL input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        var query = ""
        if let q = s.firstIndex(of: "?") {
            query = String(s[s.index(after: q)...])
            s = String(s[..<q])
        }
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "p", let id = trailingHexID(String(kv[1])) { return id }
        }
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        for segment in s.split(separator: "/").reversed() {
            if let id = trailingHexID(String(segment)) { return id }
        }
        return nil
    }

    static func trailingHexID(_ segment: String) -> String? {
        let compact = segment.filter { $0 != "-" }.lowercased()
        guard compact.count >= 32 else { return nil }
        let tail = compact.suffix(32)
        guard tail.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        let c = Array(tail)
        return [c[0..<8], c[8..<12], c[12..<16], c[16..<20], c[20..<32]].map { String($0) }.joined(separator: "-")
    }

    // MARK: HTTP

    func makeRequest(method: String, path: String, body: JSONValue?) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try body.encoded()
        }
        return request
    }

    @discardableResult
    func send(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw NotionError.missingToken }
        let request = try makeRequest(method: method, path: path, body: body)
        var attempt = 0
        while true {
            let (data, response) = try await http.data(for: request)
            if (200..<300).contains(response.statusCode) {
                guard let json = try? JSONValue.decode(data) else { throw NotionError.invalidResponse("body is not JSON") }
                return json
            }
            if (response.statusCode == 429 || response.statusCode == 409), attempt < maxRetries {
                let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                let delay = min(retryAfter ?? pow(2, Double(attempt)), 60)
                try await sleep(delay)
                attempt += 1
                continue
            }
            throw NotionError.from(status: response.statusCode, body: data)
        }
    }

    // MARK: API

    /// Validates the token; returns the integration's bot name.
    public func me() async throws -> String {
        let json = try await send("GET", "users/me")
        return json["name"]?.stringValue ?? "Notion integration"
    }

    static func meetingsDatabaseBody(parentPageID: String, title: String) -> JSONValue {
        let p = propertyNames
        return [
            "parent": ["type": "page_id", "page_id": .string(parentPageID)],
            "title": .array(NotionRichText.split([NotionRichText(title)]).map(\.json)),
            "is_inline": false,
            "properties": [
                p.name: ["title": [:]],
                p.date: ["date": [:]],
                p.attendees: ["rich_text": [:]],
                p.source: ["select": ["options": []]],
                p.duration: ["number": ["format": "number"]],
                p.granolaID: ["rich_text": [:]],
            ],
        ]
    }

    /// Creates the meetings database under a page (URL or ID). Returns the database ID.
    public func createMeetingsDatabase(parentPageID: String, title: String = "Meetings") async throws -> String {
        guard let parent = Self.pageID(fromURL: parentPageID) else { throw NotionError.invalidPageID(parentPageID) }
        let json = try await send("POST", "databases", body: Self.meetingsDatabaseBody(parentPageID: parent, title: title))
        guard let id = json["id"]?.stringValue else { throw NotionError.invalidResponse("missing database id") }
        return id
    }

    /// Finds a database shared with the integration whose title matches (case-insensitive).
    public func findDatabase(title: String) async throws -> String? {
        let body: JSONValue = [
            "query": .string(title),
            "filter": ["value": "database", "property": "object"],
            "page_size": 100,
        ]
        let json = try await send("POST", "search", body: body)
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for result in json["results"]?.arrayValue ?? [] {
            if result["archived"]?.boolValue == true || result["in_trash"]?.boolValue == true { continue }
            let name = (result["title"]?.arrayValue ?? [])
                .compactMap { $0["plain_text"]?.stringValue ?? $0["text"]?["content"]?.stringValue }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if name == wanted, let id = result["id"]?.stringValue { return id }
        }
        return nil
    }

    /// Moves a page to the trash (e.g. before re-exporting a meeting).
    public func archivePage(id: String) async throws {
        guard let pageID = Self.pageID(fromURL: id) else { throw NotionError.invalidPageID(id) }
        try await send("PATCH", "pages/\(pageID)", body: ["archived": true])
    }

    /// Property name → type for a database.
    func databaseSchema(id: String) async throws -> [String: String] {
        let json = try await send("GET", "databases/\(id)")
        var schema: [String: String] = [:]
        for (name, value) in json["properties"]?.objectValue ?? [:] {
            if let type = value["type"]?.stringValue { schema[name] = type }
        }
        return schema
    }

    /// Creates a page in the database with the meeting's properties, enhanced notes, raw notes and a
    /// transcript toggle. Returns the page URL.
    public func exportMeeting(_ meeting: Meeting, segments: [TranscriptSegment], databaseID: String) async throws -> URL {
        guard let dbID = Self.pageID(fromURL: databaseID) else { throw NotionError.invalidPageID(databaseID) }
        let schema = try await databaseSchema(id: dbID)
        let properties = Self.pageProperties(meeting: meeting, schema: schema)
        let prepared = Self.pageBlocks(meeting: meeting, segments: segments).map(Self.prepare)

        var initial: [PreparedBlock] = []
        var elements = 0, bytes = 0
        for block in prepared {
            guard block.deferred.isEmpty, initial.count < Self.maxChildrenPerRequest,
                elements + block.elements <= Self.maxBlockElementsPerRequest,
                bytes + block.bytes <= Self.maxRequestBytes
            else { break }
            initial.append(block)
            elements += block.elements
            bytes += block.bytes
        }

        var body: [String: JSONValue] = [
            "parent": ["type": "database_id", "database_id": .string(dbID)],
            "properties": .object(properties),
        ]
        if !initial.isEmpty { body["children"] = .array(initial.map(\.json)) }
        let page = try await send("POST", "pages", body: .object(body))
        guard let pageID = page["id"]?.stringValue else { throw NotionError.invalidResponse("missing page id") }

        do {
            try await append(Array(prepared.dropFirst(initial.count)), to: pageID)
        } catch {
            _ = try? await send("PATCH", "pages/\(pageID)", body: ["archived": true])
            throw error
        }

        if let url = page["url"]?.stringValue.flatMap(URL.init(string:)) { return url }
        return URL(string: "https://www.notion.so/\(pageID.replacingOccurrences(of: "-", with: ""))")!
    }

    func append(_ blocks: [PreparedBlock], to parentID: String) async throws {
        for batch in Self.batches(blocks) {
            let response = try await send("PATCH", "blocks/\(parentID)/children", body: ["children": .array(batch.map(\.json))])
            guard batch.contains(where: { !$0.deferred.isEmpty }) else { continue }
            let results = response["results"]?.arrayValue ?? []
            guard results.count >= batch.count else {
                throw NotionError.invalidResponse("append returned \(results.count) blocks, expected \(batch.count)")
            }
            let created = Array(results.suffix(batch.count))
            for (k, block) in batch.enumerated() where !block.deferred.isEmpty {
                guard let id = created[k]["id"]?.stringValue, created[k]["type"]?.stringValue == block.type else {
                    throw NotionError.invalidResponse("couldn't identify appended \(block.type) block")
                }
                try await append(block.deferred.map(Self.prepare), to: id)
            }
        }
    }

    // MARK: Payload construction

    static func pageProperties(meeting: Meeting, schema: [String: String]) -> [String: JSONValue] {
        let p = propertyNames
        var props: [String: JSONValue] = [:]
        let titleName = schema.first { $0.value == "title" }?.key ?? p.name
        let title = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        props[titleName] = ["title": .array(NotionRichText.split([NotionRichText(title.isEmpty ? "Untitled meeting" : title)]).map(\.json))]

        func has(_ name: String, _ type: String) -> Bool { schema[name] == type }

        if has(p.date, "date") {
            let f = ISO8601DateFormatter()
            var date: [String: JSONValue] = ["start": .string(f.string(from: meeting.startedAt))]
            if let end = meeting.endedAt, end > meeting.startedAt { date["end"] = .string(f.string(from: end)) }
            props[p.date] = ["date": .object(date)]
        }
        if has(p.attendees, "rich_text"), !meeting.attendees.isEmpty {
            let names = meeting.attendees.map(\.displayName).joined(separator: ", ")
            props[p.attendees] = ["rich_text": .array(NotionRichText.split([NotionRichText(names)]).prefix(100).map(\.json))]
        }
        if has(p.source, "select"), let app = MeetingContext.appName(bundleID: meeting.sourceApp) {
            let option = String(app.replacingOccurrences(of: ",", with: " ").prefix(100))
            props[p.source] = ["select": ["name": .string(option)]]
        }
        if has(p.duration, "number"), let minutes = MeetingContext.durationMinutes(meeting) {
            props[p.duration] = ["number": .number(Double(minutes))]
        }
        if has(p.granolaID, "rich_text") {
            props[p.granolaID] = ["rich_text": [NotionRichText(meeting.id).json]]
        }
        return props
    }

    static func pageBlocks(meeting: Meeting, segments: [TranscriptSegment]) -> [NotionBlock] {
        var blocks: [NotionBlock] = []
        let enhanced = meeting.enhancedNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = meeting.rawNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !enhanced.isEmpty { blocks += MarkdownToNotion.convert(enhanced) }
        if !raw.isEmpty {
            if !blocks.isEmpty { blocks.append(.divider) }
            blocks.append(.heading(2, "My notes"))
            blocks += MarkdownToNotion.convert(raw)
        }
        let transcript = transcriptBlocks(segments)
        if !transcript.isEmpty {
            blocks.append(.toggle([NotionRichText("Transcript", bold: true)], children: transcript))
        }
        return blocks
    }

    /// One paragraph per run of consecutive same-speaker segments: "**[mm:ss] Me:** text".
    static func transcriptBlocks(_ segments: [TranscriptSegment]) -> [NotionBlock] {
        var blocks: [NotionBlock] = []
        var current: (label: String, text: String)?
        var currentSource: TranscriptSource?
        func flush() {
            if let c = current {
                blocks.append(.paragraph([NotionRichText(c.label, bold: true), NotionRichText(c.text)]))
            }
            current = nil
        }
        for segment in segments.sorted(by: { $0.startOffset < $1.startOffset }) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var c = current, currentSource == segment.source, c.text.count + text.count < maxTranscriptParagraphLength {
                c.text += " " + text
                current = c
            } else {
                flush()
                current = ("[\(Transcript.timestamp(segment.startOffset))] \(segment.source.speakerLabel): ", text)
                currentSource = segment.source
            }
        }
        flush()
        return NotionBlock.enforcingLimits(blocks)
    }

    // MARK: Batching

    /// A top-level block ready to send: JSON with whatever children can be inlined, plus children that must
    /// be appended afterwards (Notion allows two nesting levels and 100 children per array per request).
    struct PreparedBlock {
        var type: String
        var json: JSONValue
        var deferred: [NotionBlock]
        var elements: Int
        var bytes: Int
    }

    static func byteCount(_ json: JSONValue) -> Int { (try? json.encoded().count) ?? 0 }

    static func prepare(_ block: NotionBlock) -> PreparedBlock {
        var inline: [NotionBlock] = []
        var deferred: [NotionBlock] = []
        if !block.children.isEmpty {
            if block.children.allSatisfy({ $0.children.isEmpty }) {
                var inlineBytes = 0
                for (i, child) in block.children.enumerated() {
                    let size = byteCount(child.json())
                    if inline.count >= maxChildrenPerRequest || inlineBytes + size > maxRequestBytes / 2 {
                        deferred = Array(block.children[i...])
                        break
                    }
                    inline.append(child)
                    inlineBytes += size
                }
            } else {
                deferred = block.children
            }
        }
        let json = block.json(children: inline)
        return PreparedBlock(type: block.type, json: json, deferred: deferred, elements: 1 + inline.count, bytes: byteCount(json))
    }

    static func batches(_ blocks: [PreparedBlock]) -> [[PreparedBlock]] {
        var result: [[PreparedBlock]] = []
        var current: [PreparedBlock] = []
        var elements = 0, bytes = 0
        for block in blocks {
            if !current.isEmpty,
                current.count >= maxChildrenPerRequest
                    || elements + block.elements > maxBlockElementsPerRequest
                    || bytes + block.bytes > maxRequestBytes
            {
                result.append(current)
                current = []
                elements = 0
                bytes = 0
            }
            current.append(block)
            elements += block.elements
            bytes += block.bytes
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
