import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public struct FencedCodeBlock: Sendable, Hashable {
    public let language: String?
    public let text: String

    public var copyText: String { text }

    public init(language: String?, text: String) {
        self.language = language
        self.text = text
    }
}

public enum TranscriptBlock: Sendable, Hashable {
    case prose(String)
    case quote(String)
    case code(FencedCodeBlock)
}

public enum TranscriptParser {
    public static func blocks(from markdown: String) -> [TranscriptBlock] {
        guard !markdown.isEmpty else { return [] }
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [TranscriptBlock] = []
        var proseStart = 0
        var index = 0

        while index < lines.count {
            guard let language = openingFence(in: lines[index]),
                  let closing = closingFence(after: index, in: lines)
            else {
                index += 1
                continue
            }

            appendProse(Array(lines[proseStart..<index]), to: &result)
            let code = lines[(index + 1)..<closing].joined(separator: "\n")
            result.append(.code(FencedCodeBlock(language: language, text: code)))
            index = closing + 1
            proseStart = index
        }

        appendProse(Array(lines[proseStart...]), to: &result)
        return result
    }

    public static func attributedProse(_ markdown: String) throws -> AttributedString {
        try AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }

    private static func openingFence(in line: String) -> String?? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else { return nil }
        let suffix = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        return .some(suffix.isEmpty ? nil : suffix)
    }

    private static func closingFence(after opening: Int, in lines: [String]) -> Int? {
        guard opening + 1 < lines.count else { return nil }
        return ((opening + 1)..<lines.count).first { index in
            lines[index].trimmingCharacters(in: .whitespaces) == "```"
        }
    }

    private static func appendProse(_ lines: [String], to result: inout [TranscriptBlock]) {
        guard !lines.isEmpty else { return }
        var current: [String] = []
        var currentIsQuote: Bool?

        func flush() {
            guard !current.isEmpty, let isQuote = currentIsQuote else { return }
            let text = current.joined(separator: "\n")
            guard !text.isEmpty else {
                current.removeAll()
                currentIsQuote = nil
                return
            }
            result.append(isQuote ? .quote(text) : .prose(text))
            current.removeAll()
            currentIsQuote = nil
        }

        for line in lines {
            let quote = quoteText(from: line)
            let isQuote = quote != nil
            if let currentIsQuote, currentIsQuote != isQuote, !line.isEmpty {
                flush()
            }
            if currentIsQuote == nil { currentIsQuote = isQuote }
            current.append(quote ?? line)
        }
        flush()
    }

    private static func quoteText(from line: String) -> String? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard trimmed.first == ">" else { return nil }
        var content = trimmed.dropFirst()
        if content.first == " " { content = content.dropFirst() }
        return String(content)
    }
}

@MainActor
public struct TranscriptRenderer: View {
    private let markdown: String

    public init(markdown: String) {
        self.markdown = markdown
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(TranscriptParser.blocks(from: markdown).enumerated()), id: \.offset) {
                index, block in
                switch block {
                case let .prose(text):
                    Text(attributed(text))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("transcript-prose-\(index)")
                case let .quote(text):
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.5))
                            .frame(width: 3)
                        Text(attributed(text))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .accessibilityIdentifier("transcript-quote-\(index)")
                case let .code(code):
                    FencedCodeBlockView(code: code, index: index)
                }
            }
        }
    }

    private func attributed(_ text: String) -> AttributedString {
        (try? TranscriptParser.attributedProse(text)) ?? AttributedString(text)
    }
}

@MainActor
private struct FencedCodeBlockView: View {
    let code: FencedCodeBlock
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(code.language ?? "Code")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("code-language-\(index)")
                Spacer()
                Button {
                    copy(code.copyText)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("copy-code-\(index)")
            }
            ScrollView(.horizontal) {
                Text(verbatim: code.text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // Keep the language label and the copy button addressable instead of
        // letting the block's identifier overwrite theirs.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("code-block-\(index)")
    }

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
