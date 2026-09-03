import Foundation
import RemoteAIKit
import RemoteAITestKit

public enum TranscriptRendererSuite {
    public static let suite = TestSuite(
        name: "TranscriptRendererSuite",
        cases: [
            TestCase("prose keeps bold inline code list and link markdown") {
                let markdown = "**Bold** and `code` with [docs](https://example.com)\n\n- one\n- two"
                let blocks = TranscriptParser.blocks(from: markdown)

                try expectEqual(blocks, [.prose(markdown)])
                let attributed = try TranscriptParser.attributedProse(markdown)
                try expectEqual(
                    String(attributed.characters),
                    "Bold and code with docs\n\n- one\n- two"
                )
                try expectTrue(attributed.runs.contains { $0.link != nil })
                try expectTrue(
                    attributed.runs.contains {
                        $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                    }
                )
                try expectTrue(
                    attributed.runs.contains {
                        $0.inlinePresentationIntent?.contains(.code) == true
                    }
                )
            },

            TestCase("quote lines become a secondary quote block") {
                let blocks = TranscriptParser.blocks(from: "> first\n> second")
                try expectEqual(blocks, [.quote("first\nsecond")])
            },

            TestCase("closed fenced code exposes language and exact copy text") {
                let blocks = TranscriptParser.blocks(
                    from: "Before\n```swift\nlet value = 1\nprint(value)\n```\nAfter"
                )
                try expectEqual(
                    blocks,
                    [
                        .prose("Before"),
                        .code(
                            FencedCodeBlock(
                                language: "swift",
                                text: "let value = 1\nprint(value)"
                            )
                        ),
                        .prose("After"),
                    ]
                )
                guard case let .code(code) = blocks[1] else {
                    throw ExpectationFailure(
                        message: "expected code block", file: #filePath, line: #line
                    )
                }
                try expectEqual(code.copyText, "let value = 1\nprint(value)")
            },

            TestCase("multiple fenced code blocks remain independent") {
                let blocks = TranscriptParser.blocks(
                    from: "```sh\necho one\n```\nBetween\n```\necho two\n```"
                )
                try expectEqual(blocks.count, 3)
                guard case let .code(first) = blocks[0],
                      case let .code(second) = blocks[2]
                else {
                    throw ExpectationFailure(
                        message: "expected two code blocks", file: #filePath, line: #line
                    )
                }
                try expectEqual(first.language, "sh")
                try expectNil(second.language)
                try expectEqual(first.copyText, "echo one")
                try expectEqual(second.copyText, "echo two")
            },

            TestCase("an unclosed streaming fence remains prose") {
                let markdown = "Answer so far\n```swift\nlet unfinished = true"
                try expectEqual(TranscriptParser.blocks(from: markdown), [.prose(markdown)])
            },
        ]
    )
}
