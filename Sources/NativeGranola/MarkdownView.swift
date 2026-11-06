import SwiftUI

/// Renders the subset of markdown the notes use: headings, bullets (nested), to-dos, numbered
/// lists, quotes and paragraphs, with inline bold/italic/code/links.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(Self.blocks(markdown).enumerated()), id: \.offset) { index, block in
                view(for: block, isFirst: index == 0)
            }
        }
        .font(.system(size: 14))
        .lineSpacing(4.5)
        .foregroundStyle(Theme.ink)
        .tint(Theme.accentInk)
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
    private func view(for block: Block, isFirst: Bool) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text)
                .font(Theme.serif(level <= 1 ? 23 : level == 2 ? 20 : 18))
                .tracking(-0.2)
                .lineSpacing(0)
                .padding(.top, isFirst ? 0 : 20)
                .padding(.bottom, 1)
        case let .bullet(indent, text):
            row(indent: indent,
                marker: Circle().fill(Theme.inkTertiary).frame(width: 4.5, height: 4.5)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 2.5 },
                text: text)
        case let .todo(indent, done, text):
            row(indent: indent,
                marker: Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(done ? Theme.accentInk : Theme.inkTertiary),
                text: text)
        case let .numbered(indent, number, text):
            row(indent: indent, marker: Text("\(number).").foregroundStyle(Theme.inkSecondary).monospacedDigit(), text: text)
        case let .quote(text):
            inline(text)
                .foregroundStyle(Theme.inkSecondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 1) }
        case let .paragraph(text):
            inline(text)
        case .divider:
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 10)
        }
    }

    private func row(indent: Int, marker: some View, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            marker.frame(width: 14, alignment: .center)
            inline(text)
        }
        .padding(.leading, CGFloat(indent) * 24)
    }
}
