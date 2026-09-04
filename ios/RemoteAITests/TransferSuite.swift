import Foundation
import RemoteAIKit
import RemoteAITestKit

/// Everything here exists to prove one rule: bytes move only because the user
/// pressed something. There is no watcher, timer or lifecycle hook that can
/// reach these entry points.
public enum TransferSuite {

    @MainActor
    static func makeCoordinator(
        client: MockAgentClient = MockAgentClient(), online: Bool = true
    ) -> TransferCoordinator {
        let coordinator = TransferCoordinator(client: client)
        coordinator.isOnline = online
        return coordinator
    }

    static func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("remoteai-tests", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    public static let suite = TestSuite(
        name: "TransferSuite",
        cases: [
            TestCase("a coordinator that is merely alive transfers nothing") {
                let client = MockAgentClient()
                let coordinator = await makeCoordinator(client: client)
                for _ in 0..<50 { await Task.yield() }

                try expectEqual(await coordinator.transfers.count, 0)
                try expectEqual(
                    await client.transferRequestCount, 0,
                    "an idle app must never contact the transfer endpoints"
                )
            },

            TestCase("an explicit upload sends every chunk and reports a checksum") {
                let client = MockAgentClient()
                let coordinator = await makeCoordinator(client: client)
                let payload = Data("hello mac".utf8)

                await coordinator.startUpload(
                    name: "notes.txt", data: payload, to: "/Users/dev/work/api"
                )

                let transfer = try expectNotNil(await coordinator.transfers.first)
                try expectEqual(transfer.status, .completed)
                try expectEqual(transfer.destinationPath, "/Users/dev/work/api/notes.txt")
                try expectEqual(transfer.progress.fraction, 1.0)
                try expectEqual(transfer.sha256, TransferCoordinator.checksum(payload))
                try expectEqual(
                    await client.lastCreatedTransferRequest?.expectedSha256,
                    TransferCoordinator.checksum(payload),
                    "the digest must reach create before any chunk is sent"
                )
            },

            TestCase("an uploaded file becomes visible in the destination directory") {
                let client = MockAgentClient()
                let coordinator = await makeCoordinator(client: client)
                await coordinator.startUpload(
                    name: "notes.txt", data: Data("hi".utf8), to: "/Users/dev/work/api"
                )
                let listing = try await client.listFiles(
                    path: "/Users/dev/work/api", showHidden: false
                )
                try expectTrue(listing.entries.contains { $0.name == "notes.txt" })
            },

            TestCase("a same-name upload pauses for a decision and sends no bytes") {
                let client = MockAgentClient()
                let coordinator = await makeCoordinator(client: client)
                let before = try await client.listFiles(
                    path: "/Users/dev/work/api", showHidden: false
                )

                await coordinator.startUpload(
                    name: "README.md", data: Data("overwrite me".utf8), to: "/Users/dev/work/api"
                )

                let pending = try expectNotNil(await coordinator.pendingConflict)
                try expectEqual(pending.conflict.existingPath, "/Users/dev/work/api/README.md")
                try expectEqual(await coordinator.transfers.first?.status, .awaitingDecision)

                let after = try await client.listFiles(
                    path: "/Users/dev/work/api", showHidden: false
                )
                try expectEqual(after.entries, before.entries, "nothing may change yet")
                try expectEqual(
                    await client.transferRequestCount, 1, "only the create call was made"
                )
            },

            TestCase("keep_both completes the upload to a new name") {
                let client = MockAgentClient()
                let coordinator = await makeCoordinator(client: client)
                await coordinator.startUpload(
                    name: "README.md", data: Data("second copy".utf8), to: "/Users/dev/work/api"
                )
                await coordinator.resolvePendingConflict(.keepBoth)

                let transfer = try expectNotNil(await coordinator.transfers.first)
                try expectEqual(transfer.status, .completed)
                try expectFalse(transfer.destinationPath == "/Users/dev/work/api/README.md")
                try expectNil(await coordinator.pendingConflict)

                let listing = try await client.listFiles(
                    path: "/Users/dev/work/api", showHidden: false
                )
                try expectTrue(
                    listing.entries.contains { $0.path == "/Users/dev/work/api/README.md" },
                    "the original must survive keep_both"
                )
            },

            TestCase("overwrite completes the upload to the original path") {
                let coordinator = await makeCoordinator()
                await coordinator.startUpload(
                    name: "README.md", data: Data("replacement".utf8), to: "/Users/dev/work/api"
                )
                await coordinator.resolvePendingConflict(.overwrite)

                let transfer = try expectNotNil(await coordinator.transfers.first)
                try expectEqual(transfer.status, .completed)
                try expectEqual(transfer.destinationPath, "/Users/dev/work/api/README.md")
            },

            TestCase("discarding a conflict leaves the destination untouched") {
                let client = MockAgentClient()
                let coordinator = await makeCoordinator(client: client)
                let before = try await client.listFiles(
                    path: "/Users/dev/work/api", showHidden: false
                )
                await coordinator.startUpload(
                    name: "README.md", data: Data("nope".utf8), to: "/Users/dev/work/api"
                )
                await coordinator.discardPendingConflict()

                try expectNil(await coordinator.pendingConflict)
                try expectEqual(await coordinator.transfers.first?.status, .cancelled)
                let after = try await client.listFiles(
                    path: "/Users/dev/work/api", showHidden: false
                )
                try expectEqual(after.entries, before.entries)
            },

            TestCase("an upload is refused while the Mac is offline") {
                let client = MockAgentClient()
                let coordinator = await makeCoordinator(client: client, online: false)
                await coordinator.startUpload(
                    name: "notes.txt", data: Data("hi".utf8), to: "/Users/dev/work/api"
                )
                try expectEqual(await coordinator.transfers.first?.status, .failed("offline"))
                try expectEqual(await client.transferRequestCount, 0)
            },

            TestCase("an explicit download writes the file and reports a checksum") {
                let coordinator = await makeCoordinator()
                let destination = tempURL("README.md")
                defer { try? FileManager.default.removeItem(at: destination) }

                await coordinator.startDownload(
                    FileEntry(
                        path: "/Users/dev/work/api/README.md", name: "README.md",
                        kind: .file, size: 25
                    ),
                    to: destination
                )

                let transfer = try expectNotNil(await coordinator.transfers.first)
                try expectEqual(transfer.status, .completed)
                let written = try expectNotNil(try? Data(contentsOf: destination))
                try expectTrue(written.count > 0)
                try expectEqual(transfer.sha256, TransferCoordinator.checksum(written))
            },

            TestCase("downloading an existing Mac file is not a conflict") {
                let coordinator = await makeCoordinator()
                let destination = tempURL("README.md")
                defer { try? FileManager.default.removeItem(at: destination) }

                await coordinator.startDownload(
                    FileEntry(
                        path: "/Users/dev/work/api/README.md", name: "README.md",
                        kind: .file, size: 25
                    ),
                    to: destination
                )
                try expectNil(
                    await coordinator.pendingConflict,
                    "conflict handling applies to uploads onto the Mac only"
                )
            },

            TestCase("an incomplete download never replaces the phone destination") {
                let coordinator = await makeCoordinator()
                let destination = tempURL("incomplete.bin")
                defer { try? FileManager.default.removeItem(at: destination) }

                await coordinator.startDownload(
                    FileEntry(
                        path: "/Users/dev/work/api/README.md", name: "README.md",
                        kind: .file, size: 9_999
                    ),
                    to: destination
                )

                guard case .failed = await coordinator.transfers.first?.status else {
                    throw ExpectationFailure(
                        message: "short download should fail", file: #filePath, line: #line
                    )
                }
                try expectFalse(FileManager.default.fileExists(atPath: destination.path))
            },

            TestCase("cancelling a running transfer stops it and reports cancelled") {
                let client = MockAgentClient()
                let coordinator = await makeCoordinator(client: client)
                await coordinator.startUpload(
                    name: "README.md", data: Data("x".utf8), to: "/Users/dev/work/api"
                )
                let id = try expectNotNil(await coordinator.transfers.first?.id)
                await coordinator.cancel(id)

                try expectEqual(await coordinator.transfers.first?.status, .cancelled)
                try expectNil(await coordinator.pendingConflict)
            },

            TestCase("a failed upload is only retried when the user asks") {
                let client = MockAgentClient()
                let coordinator = await makeCoordinator(client: client, online: false)
                await coordinator.startUpload(
                    name: "notes.txt", data: Data("hi".utf8), to: "/Users/dev/work/api"
                )
                try expectEqual(await coordinator.transfers.first?.status, .failed("offline"))

                for _ in 0..<50 { await Task.yield() }
                try expectEqual(
                    await client.transferRequestCount, 0, "a failure must not retry itself"
                )

                await MainActor.run { coordinator.isOnline = true }
                let id = try expectNotNil(await coordinator.transfers.first?.id)
                await coordinator.retry(id)
                try expectEqual(await coordinator.transfers.first?.status, .completed)
            },

            TestCase("progress never moves backwards") {
                let coordinator = await makeCoordinator()
                let payload = Data(repeating: 0x41, count: 200 * 1024)
                await coordinator.startUpload(
                    name: "big.bin", data: payload, to: "/Users/dev/work/api"
                )
                let samples = await coordinator.progressSamples
                try expectTrue(samples.count >= 2, "a multi-chunk upload reports progress")
                try expectEqual(samples, samples.sorted())
                try expectEqual(samples.last, 1.0)
            },
        ]
    )
}
