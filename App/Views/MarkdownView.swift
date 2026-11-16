import SwiftUI
import UIKit

/// Lightweight Markdown renderer for model replies: paragraphs, headings, lists, quotes and code blocks.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let content):
            Text(inline(content))
                .lineSpacing(3)
        case .heading(let level, let content):
            Text(inline(content))
                .font(level <= 1 ? .title2.bold() : (level == 2 ? .title3.bold() : .headline))
                .padding(.top, 4)
        case .bullet(let marker, let content, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(inline(content))
                    .lineSpacing(3)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .quote(let content):
            Text(inline(content))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3)
                }
        case .code(let language, let content):
            CodeBlockView(language: language, code: content)
        case .divider:
            Divider().padding(.vertical, 2)
        }
    }

    private func inline(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }
}

enum MarkdownBlock {
    case paragraph(String)
    case heading(Int, String)
    case bullet(String, String, Int)
    case quote(String)
    case code(String, String)
    case divider

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let language = codeLanguage {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language, codeLines.joined(separator: "\n")))
                    codeLines = []
                    codeLanguage = nil
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                let rest = trimmed.dropFirst(level)
                if level <= 6, rest.hasPrefix(" ") {
                    flushParagraph()
                    blocks.append(.heading(level, rest.trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.divider)
                continue
            }
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }

            let indent = line.prefix { $0 == " " }.count / 2
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph()
                blocks.append(.bullet("•", String(trimmed.dropFirst(2)), indent))
                continue
            }
            let digits = trimmed.prefix { $0.isNumber }
            if !digits.isEmpty, digits.count <= 3 {
                let rest = trimmed.dropFirst(digits.count)
                if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                    flushParagraph()
                    blocks.append(.bullet("\(digits).", String(rest.dropFirst(2)), indent))
                    continue
                }
            }

            paragraph.append(trimmed)
        }

        flushParagraph()
        if let language = codeLanguage {
            // Code block still being written by the model.
            blocks.append(.code(language, codeLines.joined(separator: "\n")))
        }
        return blocks
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "код" : language)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Скопировано" : "Копировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.06))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
