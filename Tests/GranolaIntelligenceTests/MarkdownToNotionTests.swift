import Foundation
import Testing
@testable import GranolaIntelligence

@Suite struct MarkdownToNotionTests {
    func types(_ blocks: [NotionBlock]) -> [String] { blocks.map(\.type) }

    @Test func headings() {
        let blocks = MarkdownToNotion.convert("# One\n## Two\n### Three\n#### Four ##\n#notaheading")
        #expect(types(blocks) == ["heading_1", "heading_2", "heading_3", "heading_3", "paragraph"])
        #expect(blocks.map(\.plainText) == ["One", "Two", "Three", "Four", "#notaheading"])
    }

    @Test func bulletsNumbersAndTodos() {
        let md = """
            - first
            * second
            + third
            1. one
            2) two
            - [ ] Dana: send proposal
            - [x] done thing
            * [X] also done
            """
        let blocks = MarkdownToNotion.convert(md)
        #expect(types(blocks) == [
            "bulleted_list_item", "bulleted_list_item", "bulleted_list_item",
            "numbered_list_item", "numbered_list_item", "to_do", "to_do", "to_do",
        ])
        #expect(blocks[0].plainText == "first")
        #expect(blocks[4].plainText == "two")
        #expect(blocks[5].plainText == "Dana: send proposal")
        #expect(blocks[5].extra["checked"] == false)
        #expect(blocks[6].extra["checked"] == true)
        #expect(blocks[7].extra["checked"] == true)
    }

    @Test func nestedBullets() {
        let md = """
            - parent
              - child a
              - child b
                - grandchild
            - sibling
            \t- tab child
            """
        let blocks = MarkdownToNotion.convert(md)
        #expect(types(blocks) == ["bulleted_list_item", "bulleted_list_item"])
        #expect(blocks[0].children.map(\.plainText) == ["child a", "child b"])
        #expect(blocks[0].children[1].children.map(\.plainText) == ["grandchild"])
        #expect(blocks[1].children.map(\.plainText) == ["tab child"])
        let json = blocks[0].fullJSON
        #expect(json["bulleted_list_item"]?["children"]?.arrayValue?.count == 2)
    }

    @Test func listContinuationLineAndLooseLists() {
        let blocks = MarkdownToNotion.convert("- item\n  continued here\n\n- next")
        #expect(types(blocks) == ["bulleted_list_item", "bulleted_list_item"])
        #expect(blocks[0].plainText == "item\ncontinued here")
    }

    @Test func quotesDividersAndParagraphs() {
        let md = """
            > quoted line one
            > line two

            ---
            First paragraph line
            second line

            Another paragraph
            ***
            """
        let blocks = MarkdownToNotion.convert(md)
        #expect(types(blocks) == ["quote", "divider", "paragraph", "paragraph", "divider"])
        #expect(blocks[0].plainText == "quoted line one\nline two")
        #expect(blocks[2].plainText == "First paragraph line\nsecond line")
        let divider = blocks[1].json()
        #expect(divider["divider"] == [:])
        #expect(divider["type"] == "divider")
    }

    @Test func fencedCode() {
        let md = "```swift\nlet x = 1\n  indented\n```\n```\nplain\n```\n~~~js\nconsole.log(1)\n~~~\n```klingon\nqapla\n```"
        let blocks = MarkdownToNotion.convert(md)
        #expect(types(blocks) == ["code", "code", "code", "code"])
        #expect(blocks[0].plainText == "let x = 1\n  indented")
        #expect(blocks[0].extra["language"] == "swift")
        #expect(blocks[1].extra["language"] == "plain text")
        #expect(blocks[2].extra["language"] == "javascript")
        #expect(blocks[3].extra["language"] == "plain text")
        #expect(blocks[0].richText.allSatisfy { !$0.bold && !$0.code })
    }

    @Test func codeContentIsNotParsedAsMarkdown() {
        let blocks = MarkdownToNotion.convert("```\n# not heading\n- not bullet **x**\n```")
        #expect(blocks.count == 1)
        #expect(blocks[0].plainText == "# not heading\n- not bullet **x**")
    }

    @Test func inlineFormatting() {
        let rt = MarkdownToNotion.parseInline("Plain **bold** and *italic* and _also italic_ and `code` and ~~gone~~.")
        #expect(rt.map(\.content) == ["Plain ", "bold", " and ", "italic", " and ", "also italic", " and ", "code", " and ", "gone", "."])
        #expect(rt[1].bold && !rt[1].italic)
        #expect(rt[3].italic && !rt[3].bold)
        #expect(rt[5].italic)
        #expect(rt[7].code)
        #expect(rt[9].strikethrough)
        #expect(!rt[0].bold && !rt[0].italic && !rt[0].code)
    }

    @Test func nestedInlineAndLinks() throws {
        let rt = MarkdownToNotion.parseInline("See **[the doc](https://example.com/a?b=1)** or [*plan*](https://x.io) and [bad](/relative)")
        try #require(rt.map(\.content) == ["See ", "the doc", " or ", "plan", " and bad"])
        #expect(rt[1].bold && rt[1].link == "https://example.com/a?b=1")
        #expect(rt[3].italic && rt[3].link == "https://x.io")
        #expect(rt[4].link == nil)
        let json = rt[1].json
        #expect(json["text"]?["link"]?["url"] == "https://example.com/a?b=1")
        #expect(json["annotations"]?["bold"] == true)
        #expect(rt[0].json["annotations"] == nil)
    }

    @Test func underscoresInWordsAndUnmatchedMarkers() {
        #expect(MarkdownToNotion.parseInline("snake_case_name stays").map(\.content) == ["snake_case_name stays"])
        #expect(MarkdownToNotion.parseInline("2 * 3 * 4").map(\.content) == ["2 * 3 * 4"])
        #expect(MarkdownToNotion.parseInline("a **unclosed").map(\.content) == ["a **unclosed"])
        #expect(MarkdownToNotion.parseInline("price \\*not italic\\*").map(\.content) == ["price *not italic*"])
        let code = MarkdownToNotion.parseInline("use `**raw**` here")
        #expect(code.map(\.content) == ["use ", "**raw**", " here"])
        #expect(code[1].code && !code[1].bold)
    }

    @Test func autolink() {
        let rt = MarkdownToNotion.parseInline("go to <https://granola.ai> now")
        #expect(rt.map(\.content) == ["go to ", "https://granola.ai", " now"])
        #expect(rt[1].link == "https://granola.ai")
    }

    @Test func formattingInsideListItemsAndHeadings() {
        let blocks = MarkdownToNotion.convert("### **Pricing** update\n- [ ] **Dana**: send `v2` deck")
        #expect(blocks[0].richText.first?.bold == true)
        #expect(blocks[1].type == "to_do")
        #expect(blocks[1].richText.map(\.content) == ["Dana", ": send ", "v2", " deck"])
    }

    @Test func longTextIsSplitAt2000() {
        let long = String(repeating: "abcdefghij", count: 450)
        let blocks = MarkdownToNotion.convert(long)
        #expect(blocks.count == 1)
        #expect(blocks[0].richText.map { $0.content.utf16.count } == [2000, 2000, 500])
        #expect(blocks[0].plainText == long)
    }

    @Test func splitRespectsUTF16AndGraphemes() {
        let emoji = String(repeating: "👍🏽", count: 700)
        let pieces = NotionRichText.split([NotionRichText(emoji, bold: true)])
        #expect(pieces.allSatisfy { $0.content.utf16.count <= 2000 && $0.bold })
        #expect(pieces.map(\.content).joined() == emoji)
        #expect(pieces.count == 2)
    }

    @Test func moreThan100RichTextItemsSplitsBlock() {
        let md = (0..<150).map { "**b\($0)** p" }.joined(separator: " ")
        let blocks = MarkdownToNotion.convert(md)
        #expect(blocks.count == 3)
        #expect(blocks.allSatisfy { $0.type == "paragraph" && $0.richText.count <= 100 })
        #expect(blocks.map(\.plainText).joined() == MarkdownToNotion.parseInline(md).map(\.content).joined())
    }

    @Test func realisticEnhancedNotes() {
        let md = """
            ### Summary
            - Acme wants **SSO by Q3**; budget ~$40k

            ### Decisions
            - Decided to offer the *Enterprise* tier

            ### Action Items
            - [ ] Agrim: send proposal by Friday
            - [ ] Dana Lee: confirm security review
            """
        let blocks = MarkdownToNotion.convert(md)
        #expect(types(blocks) == ["heading_3", "bulleted_list_item", "heading_3", "bulleted_list_item", "heading_3", "to_do", "to_do"])
        let json = blocks[5].json()
        #expect(json["object"] == "block")
        #expect(json["to_do"]?["checked"] == false)
        #expect(json["to_do"]?["rich_text"]?[0]?["text"]?["content"] == "Agrim: send proposal by Friday")
    }

    @Test func emptyInput() {
        #expect(MarkdownToNotion.convert("").isEmpty)
        #expect(MarkdownToNotion.convert("\n\n  \n").isEmpty)
    }
}
