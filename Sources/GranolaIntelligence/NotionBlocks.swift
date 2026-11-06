import Foundation

/// One Notion rich_text item of type "text".
public struct NotionRichText: Sendable, Hashable {
    public static let maxContentLength = 2000

    public var content: String
    public var link: String?
    public var bold: Bool
    public var italic: Bool
    public var code: Bool
    public var strikethrough: Bool

    public init(
        _ content: String, link: String? = nil,
        bold: Bool = false, italic: Bool = false, code: Bool = false, strikethrough: Bool = false
    ) {
        self.content = content
        self.link = link
        self.bold = bold
        self.italic = italic
        self.code = code
        self.strikethrough = strikethrough
    }

    func sameStyle(as other: NotionRichText) -> Bool {
        link == other.link && bold == other.bold && italic == other.italic && code == other.code
            && strikethrough == other.strikethrough
    }

    public var json: JSONValue {
        var text: [String: JSONValue] = ["content": .string(content)]
        if let link { text["link"] = ["url": .string(link)] }
        var obj: [String: JSONValue] = ["type": "text", "text": .object(text)]
        if bold || italic || code || strikethrough {
            obj["annotations"] = [
                "bold": .bool(bold), "italic": .bool(italic), "code": .bool(code),
                "strikethrough": .bool(strikethrough), "underline": false, "color": "default",
            ]
        }
        return .object(obj)
    }

    /// Splits items so each content is at most `limit` UTF-16 units (Notion counts JS string length),
    /// never breaking a Character apart.
    public static func split(_ items: [NotionRichText], limit: Int = maxContentLength) -> [NotionRichText] {
        var out: [NotionRichText] = []
        for item in items {
            if item.content.utf16.count <= limit {
                out.append(item)
                continue
            }
            var current = ""
            var currentLength = 0
            for ch in item.content {
                let len = ch.utf16.count
                if currentLength + len > limit, !current.isEmpty {
                    var piece = item
                    piece.content = current
                    out.append(piece)
                    current = ""
                    currentLength = 0
                }
                current.append(ch)
                currentLength += len
            }
            if !current.isEmpty {
                var piece = item
                piece.content = current
                out.append(piece)
            }
        }
        return out
    }

    /// Merges adjacent items with identical styling.
    static func merge(_ items: [NotionRichText]) -> [NotionRichText] {
        var out: [NotionRichText] = []
        for item in items where !item.content.isEmpty {
            if let last = out.last, last.sameStyle(as: item) {
                out[out.count - 1].content += item.content
            } else {
                out.append(item)
            }
        }
        return out
    }
}

/// A Notion block (subset used by the exporter), with nested children.
public struct NotionBlock: Sendable, Hashable {
    public static let maxRichTextItems = 100

    public var type: String
    public var richText: [NotionRichText]
    /// Extra type-specific fields, e.g. `checked` for to_do or `language` for code.
    public var extra: [String: JSONValue]
    public var children: [NotionBlock]

    public init(type: String, richText: [NotionRichText] = [], extra: [String: JSONValue] = [:], children: [NotionBlock] = []) {
        self.type = type
        self.richText = NotionRichText.split(richText)
        self.extra = extra
        self.children = children
    }

    public var plainText: String { richText.map(\.content).joined() }

    var hasRichText: Bool { type != "divider" }

    public static func paragraph(_ text: [NotionRichText]) -> NotionBlock { .init(type: "paragraph", richText: text) }
    public static func paragraph(_ text: String) -> NotionBlock { .paragraph([NotionRichText(text)]) }
    public static func heading(_ level: Int, _ text: [NotionRichText]) -> NotionBlock {
        .init(type: "heading_\(min(max(level, 1), 3))", richText: text)
    }
    public static func heading(_ level: Int, _ text: String) -> NotionBlock { .heading(level, [NotionRichText(text)]) }
    public static func bullet(_ text: [NotionRichText], children: [NotionBlock] = []) -> NotionBlock {
        .init(type: "bulleted_list_item", richText: text, children: children)
    }
    public static func numbered(_ text: [NotionRichText], children: [NotionBlock] = []) -> NotionBlock {
        .init(type: "numbered_list_item", richText: text, children: children)
    }
    public static func todo(_ text: [NotionRichText], checked: Bool, children: [NotionBlock] = []) -> NotionBlock {
        .init(type: "to_do", richText: text, extra: ["checked": .bool(checked)], children: children)
    }
    public static func quote(_ text: [NotionRichText]) -> NotionBlock { .init(type: "quote", richText: text) }
    public static func code(_ text: String, language: String) -> NotionBlock {
        .init(type: "code", richText: [NotionRichText(text)], extra: ["language": .string(language)])
    }
    public static var divider: NotionBlock { .init(type: "divider") }
    public static func toggle(_ text: [NotionRichText], children: [NotionBlock]) -> NotionBlock {
        .init(type: "toggle", richText: text, children: children)
    }

    /// Block JSON. `children` overrides which children are inlined (nil = none).
    public func json(children inline: [NotionBlock]? = nil) -> JSONValue {
        var body = extra
        if hasRichText { body["rich_text"] = .array(richText.map(\.json)) }
        if let inline, !inline.isEmpty { body["children"] = .array(inline.map { $0.json(children: nil) }) }
        return ["object": "block", "type": .string(type), type: .object(body)]
    }

    /// JSON including all descendants (for inspection/tests; real requests go through the exporter's batching).
    public var fullJSON: JSONValue {
        var body = extra
        if hasRichText { body["rich_text"] = .array(richText.map(\.json)) }
        if !children.isEmpty { body["children"] = .array(children.map(\.fullJSON)) }
        return ["object": "block", "type": .string(type), type: .object(body)]
    }

    /// Splits blocks whose rich_text exceeds Notion's 100-item limit into consecutive blocks of the same type
    /// (children stay with the last piece), recursively.
    public static func enforcingLimits(_ blocks: [NotionBlock]) -> [NotionBlock] {
        blocks.flatMap { block -> [NotionBlock] in
            var block = block
            block.children = enforcingLimits(block.children)
            guard block.richText.count > maxRichTextItems else { return [block] }
            var pieces: [NotionBlock] = []
            var start = 0
            while start < block.richText.count {
                let end = min(start + maxRichTextItems, block.richText.count)
                var piece = block
                piece.richText = Array(block.richText[start..<end])
                piece.children = []
                pieces.append(piece)
                start = end
            }
            pieces[pieces.count - 1].children = block.children
            return pieces
        }
    }
}
