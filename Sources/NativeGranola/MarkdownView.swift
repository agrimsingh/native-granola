import SwiftUI

/// Renders the subset of markdown the notes use: headings, bullets (nested), to-dos, numbered
/// lists, quotes and paragraphs, with inline bold/italic/code/links.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    enum Block {
        case heading(Int, String)
        case bullet(Int, String)
        case todo(Int, Bool, String)
        case numbered(Int, String, String)
        case quote(String)
        case paragraph(String)
        case divider
    }

    static func blocks(_ text: String) -> [Block] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line == "---" || line == "***" { return .divider }
            if let m = line.firstMatch(of: #/^(#{1,6})\s+(.*)$/#) { return .heading(m.1.count, String(m.2)) }
            if let m = line.firstMatch(of: #/^[-*]\s+\[( |x|X)\]\s+(.*)$/#) { return .todo(indent, m.1 != " ", String(m.2)) }
            if let m = line.firstMatch(of: #/^[-*•]\s+(.*)$/#) { return .bullet(indent, String(m.1)) }
            if let m = line.firstMatch(of: #/^(\d+)[.)]\s+(.*)$/#) { return .numbered(indent, String(m.1), String(m.2)) }
            if let m = line.firstMatch(of: #/^>\s?(.*)$/#) { return .quote(String(m.1)) }
            return .paragraph(line)
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text)
                .font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 8)
        case let .bullet(indent, text):
            row(indent: indent, marker: Text("•").foregroundStyle(.secondary), text: text)
        case let .todo(indent, done, text):
            row(indent: indent, marker: Image(systemName: done ? "checkmark.square.fill" : "square").foregroundStyle(.secondary), text: text)
        case let .numbered(indent, number, text):
            row(indent: indent, marker: Text("\(number).").foregroundStyle(.secondary).monospacedDigit(), text: text)
        case let .quote(text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 3)
                inline(text).foregroundStyle(.secondary)
            }
        case let .paragraph(text):
            inline(text)
        case .divider:
            Divider().padding(.vertical, 4)
        }
    }

    private func row(indent: Int, marker: some View, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker.frame(minWidth: 14, alignment: .trailing)
            inline(text)
        }
        .padding(.leading, CGFloat(indent) * 18)
    }
}
