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
        .lineSpacing(3)
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
                .font(level <= 1 ? .system(size: 20, weight: .bold)
                      : level == 2 ? .system(size: 16, weight: .semibold)
                      : .system(size: 14, weight: .semibold))
                .padding(.top, isFirst ? 0 : (level <= 2 ? 16 : 8))
                .padding(.bottom, 1)
        case let .bullet(indent, text):
            row(indent: indent, marker: Circle().fill(.tertiary).frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1.5 }, text: text)
        case let .todo(indent, done, text):
            row(indent: indent,
                marker: Image(systemName: done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(done ? Theme.accent : .secondary),
                text: text)
        case let .numbered(indent, number, text):
            row(indent: indent, marker: Text("\(number).").foregroundStyle(.secondary).monospacedDigit(), text: text)
        case let .quote(text):
            HStack(spacing: 10) {
                Capsule().fill(Theme.accent.opacity(0.6)).frame(width: 3)
                inline(text).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case let .paragraph(text):
            inline(text)
        case .divider:
            Divider().padding(.vertical, 6)
        }
    }

    private func row(indent: Int, marker: some View, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            marker.frame(minWidth: 14, alignment: .center)
            inline(text)
        }
        .padding(.leading, CGFloat(indent) * 22 + 2)
    }
}
