import Foundation
import RemoteAIKit
import RemoteAITestKit

/// Attaching a file to a message is still an explicit act: the reader picked
/// it, and every byte that moves is the result of that pick. These tests pin
/// where the bytes land, what they are called, and what the composer is
/// allowed to send while they are still moving.
public enum ComposerAttachmentsSuite {

    static func conversation(
        kind: ConversationKind, projectPath: String?, workingPath: String? = nil
    ) -> ConversationSummary {
        ConversationSummary(
            id: "c1",
            provider: .claude,
            kind: kind,
            title: "t",
            projectId: projectPath == nil ? nil : "p1",
            projectPath: projectPath,
            updatedAt: Date(timeIntervalSince1970: 0),
            status: .idle,
            writeState: nil,
            writeBlockCode: nil,
            source: nil,
            workingPath: workingPath
        )
    }

    static let day = Date(timeIntervalSince1970: 1_757_400_000)  // 2025-09-09 UTC
    static let utc = TimeZone(identifier: "UTC")!

    @MainActor
    static func staged(
        client: MockAgentClient = MockAgentClient(),
        directory: String = "/Users/dev/work/api"
    ) -> ComposerAttachments {
        let transfers = TransferCoordinator(client: client)
        transfers.isOnline = true
        return ComposerAttachments(transfers: transfers, directory: { directory })
    }

    public static let suite = TestSuite(
        name: "ComposerAttachmentsSuite",
        cases: [
            TestCase("a project conversation keeps its attachments with the project") {
                // The reader is talking about that checkout, and the CLI is
                // already running there.
                try expectEqual(
                    AttachmentInbox.directory(
                        for: conversation(kind: .project, projectPath: "/Users/dev/api"),
                        macHome: "/Users/dev", on: day, timeZone: utc
                    ),
                    "/Users/dev/api/.remoteai/uploads"
                )
            },

            TestCase("a worktree takes the attachments, not the project above it") {
                try expectEqual(
                    AttachmentInbox.directory(
                        for: conversation(
                            kind: .project, projectPath: "/Users/dev/api",
                            workingPath: "/Users/dev/api-worktree"
                        ),
                        macHome: "/Users/dev", on: day, timeZone: utc
                    ),
                    "/Users/dev/api-worktree/.remoteai/uploads"
                )
            },

            TestCase("a chat that belongs to no project uses the dated inbox") {
                // Nothing to pollute, so nothing is written into a checkout.
                try expectEqual(
                    AttachmentInbox.directory(
                        for: conversation(kind: .daily, projectPath: nil),
                        macHome: "/Users/dev", on: day, timeZone: utc
                    ),
                    "/Users/dev/Library/Application Support/RemoteAI/uploads/2025-09-09"
                )
            },

            TestCase("a HEIC photo is re-encoded, because the CLI cannot read one") {
                try expectEqual(AttachmentInbox.jpegName(for: "IMG_0042.HEIC"), "IMG_0042.jpeg")
                try expectEqual(AttachmentInbox.jpegName(for: "shot.heif"), "shot.jpeg")
                try expectNil(
                    AttachmentInbox.jpegName(for: "diagram.png"),
                    "a PNG is already readable and must go over byte for byte"
                )
                try expectNil(AttachmentInbox.jpegName(for: "notes.txt"))
            },

            TestCase("re-encoding answers with actual JPEG bytes") {
                let jpeg = try expectNotNil(AttachmentInbox.jpegData(from: onePixelPNG()))
                try expectEqual(
                    Array(jpeg.prefix(3)), [0xFF, 0xD8, 0xFF],
                    "the re-encoded bytes are not a JPEG"
                )
            },

            TestCase("the first attachment of the day creates its own inbox") {
                // A dated inbox does not exist until something is put in it,
                // and the agent creates the parent directories on the way.
                // A client that refuses the upload until the reader makes the
                // folder by hand would be unusable.
                let attachments = await staged(directory: "/Users/dev/work/api/.remoteai/uploads")
                await attachments.attach(name: "notes.txt", data: Data("hello".utf8))

                let item = try expectNotNil(await attachments.items.first)
                try expectEqual(
                    item.state, .ready("/Users/dev/work/api/.remoteai/uploads/notes.txt")
                )
            },

            TestCase("an attached file reports the path the Mac actually wrote") {
                let attachments = await staged()
                await attachments.attach(name: "notes.txt", data: Data("hello".utf8))

                let item = try expectNotNil(await attachments.items.first)
                try expectEqual(item.state, .ready("/Users/dev/work/api/notes.txt"))
                try expectEqual(await attachments.readyPaths, ["/Users/dev/work/api/notes.txt"])
            },

            TestCase("a duplicate name never stops to ask which file to keep") {
                // The conflict sheet belongs to the file browser. A composer
                // that blocks on IMG_0001.jpg being attached twice is broken.
                let client = MockAgentClient()
                let attachments = await staged(client: client)
                await attachments.attach(name: "IMG_0001.jpg", data: Data("a".utf8))

                try expectEqual(
                    await client.lastCreatedTransferRequest?.conflictPolicy, .keepBoth
                )
            },

            TestCase("a file too large to carry is refused before any byte moves") {
                let client = MockAgentClient()
                let attachments = await staged(client: client)
                let oversized = Data(count: ComposerAttachments.byteLimit + 1)

                await attachments.attach(name: "movie.mov", data: oversized)

                let item = try expectNotNil(await attachments.items.first)
                try expectEqual(item.state, .failed("File is larger than 50 MB."))
                try expectEqual(
                    await client.transferRequestCount, 0,
                    "an oversized file must not reach the transfer endpoints"
                )
            },

            TestCase("a message waits for its attachments") {
                let attachments = await staged()
                try expectEqual(await attachments.isSettled, true)
                await attachments.attach(name: "a.txt", data: Data("a".utf8))
                try expectEqual(
                    await attachments.isSettled, true,
                    "an upload that finished must not hold the send button"
                )
            },

            TestCase("clearing after a send leaves nothing attached to the next one") {
                let attachments = await staged()
                await attachments.attach(name: "a.txt", data: Data("a".utf8))
                await attachments.clear()

                try expectEqual(await attachments.items.isEmpty, true)
                try expectEqual(await attachments.readyPaths, [])
            },
        ]
    )

    /// A one-pixel PNG, so the re-encoder is fed a real image without a
    /// fixture file. HEIC is the case that triggers re-encoding, but any
    /// decodable image proves the encoder produces JPEG.
    static func onePixelPNG() -> Data {
        Data(
            base64Encoded: """
                iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGOor68HAAL+\
                AX66JXAlAAAAAElFTkSuQmCC
                """
        )!
    }
}
