import Foundation

/// Converts the Markdown produced by the enhancer (and typed by users) into Notion blocks.
public enum MarkdownToNotion {
    public static func convert(_ markdown: String) -> [NotionBlock] {
        var builder = Builder()
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let language = notionLanguage(String(trimmed.dropFirst(3)))
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                builder.addTopLevel(.code(code.joined(separator: "\n"), language: language))
                continue
            }

            if trimmed.isEmpty {
                builder.blankLine()
                i += 1
                continue
            }

            let indent = indentation(of: line)

            if let item = listItem(trimmed) {
                builder.addListItem(item, indent: indent)
            } else if let h = heading(trimmed) {
                builder.addTopLevel(.heading(h.0, parseInline(h.1)))
            } else if isDivider(trimmed) {
                builder.addTopLevel(.divider)
            } else if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var content = t.dropFirst()
                    if content.hasPrefix(" ") { content = content.dropFirst() }
                    quoteLines.append(String(content))
                    i += 1
                }
                builder.addTopLevel(.quote(parseInline(quoteLines.joined(separator: "\n"))))
                continue
            } else if indent >= 2, builder.canContinueListItem {
                builder.continueListItem(parseInline(trimmed))
            } else {
                builder.addParagraphLine(trimmed)
            }
            i += 1
        }
        return NotionBlock.enforcingLimits(builder.finish())
    }

    // MARK: Line classification

    struct ListItem {
        enum Kind { case bullet, numbered, todo(Bool) }
        var kind: Kind
        var text: String
    }

    static func indentation(of line: String) -> Int {
        var n = 0
        for ch in line {
            if ch == " " { n += 1 } else if ch == "\t" { n += 4 } else { break }
        }
        return n
    }

    static func listItem(_ trimmed: String) -> ListItem? {
        let chars = Array(trimmed)
        guard !chars.isEmpty else { return nil }
        if "-*+".contains(chars[0]), chars.count >= 2, chars[1] == " " {
            let rest = String(chars[2...]).trimmingCharacters(in: .whitespaces)
            if rest.count >= 3, rest.hasPrefix("["), Array(rest)[2] == "]" {
                let mark = Array(rest)[1]
                if mark == " " || mark == "x" || mark == "X" {
                    let text = String(rest.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    return ListItem(kind: .todo(mark != " "), text: text)
                }
            }
            if isDivider(trimmed) { return nil }
            return ListItem(kind: .bullet, text: rest)
        }
        if chars.count == 1, "-*+".contains(chars[0]) { return ListItem(kind: .bullet, text: "") }
        var j = 0
        while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
        if j > 0, j < 10, j + 1 < chars.count, chars[j] == "." || chars[j] == ")", chars[j + 1] == " " {
            return ListItem(kind: .numbered, text: String(chars[(j + 2)...]).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func heading(_ trimmed: String) -> (Int, String)? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (min(hashes, 3), text.trimmingCharacters(in: .whitespaces))
    }

    static func isDivider(_ trimmed: String) -> Bool {
        let compact = trimmed.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static let notionLanguages: Set<String> = [
        "abap", "arduino", "bash", "basic", "c", "clojure", "coffeescript", "c++", "c#", "css", "dart", "diff",
        "docker", "elixir", "elm", "erlang", "flow", "fortran", "f#", "gherkin", "glsl", "go", "graphql", "groovy",
        "haskell", "html", "java", "javascript", "json", "julia", "kotlin", "latex", "less", "lisp", "livescript",
        "lua", "makefile", "markdown", "markup", "matlab", "mermaid", "nix", "objective-c", "ocaml", "pascal",
        "perl", "php", "plain text", "powershell", "prolog", "protobuf", "python", "r", "reason", "ruby", "rust",
        "sass", "scala", "scheme", "scss", "shell", "sql", "swift", "typescript", "vb.net", "verilog", "vhdl",
        "visual basic", "webassembly", "xml", "yaml", "java/c/c++/c#",
    ]

    static func notionLanguage(_ info: String) -> String {
        let lang = info.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map { $0.lowercased() } ?? ""
        let aliases: [String: String] = [
            "js": "javascript", "jsx": "javascript", "ts": "typescript", "tsx": "typescript", "py": "python",
            "sh": "shell", "zsh": "shell", "console": "shell", "yml": "yaml", "objc": "objective-c",
            "objectivec": "objective-c", "cpp": "c++", "cxx": "c++", "cs": "c#", "csharp": "c#", "md": "markdown",
            "rb": "ruby", "kt": "kotlin", "rs": "rust", "golang": "go", "dockerfile": "docker", "text": "plain text",
            "txt": "plain text", "plaintext": "plain text", "ps1": "powershell", "tex": "latex", "proto": "protobuf",
            "make": "makefile", "fsharp": "f#", "htm": "html", "svg": "xml",
        ]
        if let mapped = aliases[lang] { return mapped }
        return notionLanguages.contains(lang) ? lang : "plain text"
    }

    // MARK: Inline parsing

    public static func parseInline(_ text: String) -> [NotionRichText] {
        NotionRichText.merge(parse(Array(text), style: NotionRichText(""), allowLinks: true))
    }

    private static func isSafeLink(_ url: String) -> Bool {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme) && (scheme == "mailto" || u.host != nil)
    }

    private static func find(_ needle: [Character], in chars: [Character], from start: Int) -> Int? {
        guard !needle.isEmpty, chars.count >= needle.count else { return nil }
        var i = start
        while i <= chars.count - needle.count {
            if chars[i] == "\\" { i += 2; continue }
            if Array(chars[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    private static func parse(_ chars: [Character], style: NotionRichText, allowLinks: Bool) -> [NotionRichText] {
        var out: [NotionRichText] = []
        var buffer = ""
        func flush() {
            if !buffer.isEmpty {
                var item = style
                item.content = buffer
                out.append(item)
                buffer = ""
            }
        }
        let n = chars.count
        var i = 0
        while i < n {
            let c = chars[i]
            let next: Character? = i + 1 < n ? chars[i + 1] : nil

            if c == "\\", let next, next.isASCII, next.isPunctuation || next.isSymbol {
                buffer.append(next)
                i += 2
                continue
            }

            if c == "`" {
                var ticks = 1
                while i + ticks < n, chars[i + ticks] == "`" { ticks += 1 }
                let delimiter = Array(repeating: Character("`"), count: ticks)
                if let close = findLiteral(delimiter, in: chars, from: i + ticks) {
                    flush()
                    var item = style
                    var content = String(chars[(i + ticks)..<close])
                    if ticks > 1, content.hasPrefix(" "), content.hasSuffix(" "), content.count >= 2 {
                        content = String(content.dropFirst().dropLast())
                    }
                    item.content = content
                    item.code = true
                    out.append(item)
                    i = close + ticks
                    continue
                }
                buffer.append(contentsOf: String(delimiter))
                i += ticks
                continue
            }

            if (c == "*" || c == "_"), next == c {
                let leftOK = c == "*" || i == 0 || !isWordChar(chars[i - 1])
                if leftOK, i + 2 < n, !chars[i + 2].isWhitespace,
                    let close = find([c, c], in: chars, from: i + 2), close > i + 2, !chars[close - 1].isWhitespace,
                    c == "*" || close + 2 >= n || !isWordChar(chars[close + 2])
                {
                    flush()
                    var inner = style
                    inner.bold = true
                    out += parse(Array(chars[(i + 2)..<close]), style: inner, allowLinks: allowLinks)
                    i = close + 2
                    continue
                }
            }

            if c == "~", next == "~" {
                if i + 2 < n, !chars[i + 2].isWhitespace, let close = find(["~", "~"], in: chars, from: i + 2), close > i + 2 {
                    flush()
                    var inner = style
                    inner.strikethrough = true
                    out += parse(Array(chars[(i + 2)..<close]), style: inner, allowLinks: allowLinks)
                    i = close + 2
                    continue
                }
            }

            if c == "*" || c == "_" {
                let leftOK = c == "*" || i == 0 || !isWordChar(chars[i - 1])
                if leftOK, let next, !next.isWhitespace, next != c,
                    let close = findItalicClose(c, in: chars, from: i + 1)
                {
                    flush()
                    var inner = style
                    inner.italic = true
                    out += parse(Array(chars[(i + 1)..<close]), style: inner, allowLinks: allowLinks)
                    i = close + 1
                    continue
                }
            }

            if allowLinks, c == "[", let closeBracket = findLiteral(["]"], in: chars, from: i + 1),
                closeBracket + 1 < n, chars[closeBracket + 1] == "(",
                let closeParen = findLiteral([")"], in: chars, from: closeBracket + 2)
            {
                let label = Array(chars[(i + 1)..<closeBracket])
                var url = String(chars[(closeBracket + 2)..<closeParen]).trimmingCharacters(in: .whitespaces)
                if let space = url.firstIndex(of: " ") { url = String(url[..<space]) }
                if url.hasPrefix("<"), url.hasSuffix(">") { url = String(url.dropFirst().dropLast()) }
                flush()
                var inner = style
                if isSafeLink(url) { inner.link = url }
                out += parse(label.isEmpty ? Array(url) : label, style: inner, allowLinks: false)
                i = closeParen + 1
                continue
            }

            if allowLinks, c == "<", let close = findLiteral([">"], in: chars, from: i + 1) {
                let candidate = String(chars[(i + 1)..<close])
                if !candidate.contains(" "), isSafeLink(candidate) {
                    flush()
                    var item = style
                    item.content = candidate
                    item.link = candidate
                    out.append(item)
                    i = close + 1
                    continue
                }
            }

            buffer.append(c)
            i += 1
        }
        flush()
        return out
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    private static func findLiteral(_ needle: [Character], in chars: [Character], from start: Int) -> Int? {
        guard chars.count >= needle.count else { return nil }
        var i = start
        while i <= chars.count - needle.count {
            if Array(chars[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    private static func findItalicClose(_ c: Character, in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "`", let close = findLiteral(["`"], in: chars, from: i + 1) { i = close + 1; continue }
            if chars[i] == c {
                if i + 1 < chars.count, chars[i + 1] == c {
                    if let close = find([c, c], in: chars, from: i + 2) { i = close + 2; continue }
                    i += 2
                    continue
                }
                let prevOK = !chars[i - 1].isWhitespace
                let nextOK = c == "*" || i + 1 >= chars.count || !isWordChar(chars[i + 1])
                if prevOK, nextOK, i > start { return i }
            }
            i += 1
        }
        return nil
    }

    // MARK: Tree builder

    private final class Node {
        var block: NotionBlock
        let indent: Int
        var children: [Node] = []
        init(_ block: NotionBlock, indent: Int) {
            self.block = block
            self.indent = indent
        }
        func build() -> NotionBlock {
            var b = block
            b.children = children.map { $0.build() }
            return b
        }
    }

    private struct Builder {
        var roots: [Node] = []
        var listStack: [Node] = []
        var paragraph: [String] = []
        var lastLineWasBlank = false

        var canContinueListItem: Bool { !listStack.isEmpty && !lastLineWasBlank && paragraph.isEmpty }

        mutating func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            roots.append(Node(.paragraph(MarkdownToNotion.parseInline(paragraph.joined(separator: "\n"))), indent: 0))
            paragraph = []
        }

        mutating func blankLine() {
            flushParagraph()
            lastLineWasBlank = true
        }

        mutating func addTopLevel(_ block: NotionBlock) {
            flushParagraph()
            listStack = []
            roots.append(Node(block, indent: 0))
            lastLineWasBlank = false
        }

        mutating func addParagraphLine(_ text: String) {
            listStack = []
            paragraph.append(text)
            lastLineWasBlank = false
        }

        mutating func addListItem(_ item: ListItem, indent: Int) {
            flushParagraph()
            let text = MarkdownToNotion.parseInline(item.text)
            let block: NotionBlock
            switch item.kind {
            case .bullet: block = .bullet(text)
            case .numbered: block = .numbered(text)
            case .todo(let checked): block = .todo(text, checked: checked)
            }
            let node = Node(block, indent: indent)
            while let top = listStack.last, top.indent >= indent { listStack.removeLast() }
            if let parent = listStack.last {
                parent.children.append(node)
            } else {
                roots.append(node)
            }
            listStack.append(node)
            lastLineWasBlank = false
        }

        mutating func continueListItem(_ text: [NotionRichText]) {
            guard let node = listStack.last else { return }
            let joined = node.block.richText + [NotionRichText("\n")] + text
            node.block.richText = NotionRichText.split(NotionRichText.merge(joined))
            lastLineWasBlank = false
        }

        mutating func finish() -> [NotionBlock] {
            flushParagraph()
            return roots.map { $0.build() }
        }
    }
}
