import CryptoKit
import Foundation
import Observation

public enum TransferStatus: Sendable, Hashable {
    /// A same-name upload is waiting for the user to pick keep_both or overwrite.
    case awaitingDecision
    case running
    case completed
    case cancelled
    case failed(String)
}

public struct TransferProgress: Sendable, Hashable {
    public var sent: Int64
    public var total: Int64

    public init(sent: Int64 = 0, total: Int64 = 0) {
        self.sent = sent
        self.total = total
    }

    public var fraction: Double {
        guard total > 0 else { return sent > 0 ? 1 : 0 }
        return min(1, Double(sent) / Double(total))
    }
}

public struct TransferState: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let direction: TransferDirection
    public internal(set) var destinationPath: String
    public internal(set) var progress: TransferProgress
    public internal(set) var status: TransferStatus
    public internal(set) var sha256: String?
}

/// An upload that found an existing file and stopped, holding its bytes until
/// the user chooses. No byte is written before `resolvePendingConflict`.
public struct PendingConflict: Sendable {
    public let transferId: String
    public let request: TransferRequest
    public let conflict: TransferConflict
    let payload: Data
}

/// Owns every byte that moves between the phone and the Mac.
///
/// Each public method here is reachable only from a button, a document-picker
/// confirmation, or an explicit retry. There is deliberately no `onAppear`,
/// scene-phase, timer, or file-watcher entry point.
@MainActor
@Observable
public final class TransferCoordinator {
    public private(set) var transfers: [TransferState] = []
    public private(set) var pendingConflict: PendingConflict?
    /// Progress fractions observed during the most recent transfer, for tests
    /// and for the progress view.
    public private(set) var progressSamples: [Double] = []

    /// Mirrors `AppModel.isOnline`.
    public var isOnline = true

    private let client: AgentClient
    private var retryPayloads: [String: (request: TransferRequest, payload: Data)] = [:]
    private var downloadDestinations: [String: URL] = [:]

    public init(client: AgentClient) {
        self.client = client
    }

    public nonisolated static func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Upload

    /// Called from the upload button after the user picked a file and a target
    /// directory, and never from anywhere else.
    public func startUpload(name: String, data: Data, to directory: String) async {
        let request = TransferRequest(
            direction: .upload,
            name: name,
            remoteDirectory: directory,
            byteCount: Int64(data.count),
            conflictPolicy: nil
        )
        let localId = "local-\(transfers.count + 1)"
        transfers.append(
            TransferState(
                id: localId, name: name, direction: .upload,
                destinationPath: "\(directory)/\(name)",
                progress: TransferProgress(sent: 0, total: Int64(data.count)),
                status: .running, sha256: nil
            )
        )
        retryPayloads[localId] = (request, data)
        await performUpload(localId: localId, request: request, payload: data)
    }

    private func performUpload(localId: String, request: TransferRequest, payload: Data) async {
        guard isOnline else {
            update(localId) { $0.status = .failed("offline") }
            return
        }
        progressSamples = []

        do {
            let ticket = try await client.createTransfer(request)
            if let conflict = ticket.conflict {
                // Stop here. The destination is untouched until the user decides.
                pendingConflict = PendingConflict(
                    transferId: localId, request: request, conflict: conflict, payload: payload
                )
                update(localId) { $0.status = .awaitingDecision }
                return
            }
            try await sendChunks(localId: localId, ticket: ticket, payload: payload)
        } catch {
            update(localId) { $0.status = .failed("\(error)") }
        }
    }

    private func sendChunks(localId: String, ticket: TransferTicket, payload: Data) async throws {
        update(localId) {
            $0.destinationPath = ticket.destinationPath
            $0.status = .running
            $0.progress = TransferProgress(sent: 0, total: Int64(payload.count))
        }

        var offset = 0
        var index = 0
        while offset < payload.count {
            if state(localId)?.status == .cancelled {
                try await client.cancelTransfer(transferId: ticket.id)
                return
            }
            let end = min(offset + ticket.chunkSize, payload.count)
            try await client.uploadChunk(
                transferId: ticket.id, index: index, data: payload[offset..<end]
            )
            offset = end
            index += 1
            update(localId) { $0.progress.sent = Int64(offset) }
            progressSamples.append(Double(offset) / Double(max(payload.count, 1)))
        }
        if payload.isEmpty {
            progressSamples.append(1)
        }

        let receipt = try await client.finishTransfer(transferId: ticket.id)
        update(localId) {
            $0.destinationPath = receipt.finalPath
            $0.status = .completed
            $0.sha256 = TransferCoordinator.checksum(payload)
            $0.progress.sent = $0.progress.total
        }
    }

    /// The only way a same-name upload can proceed.
    public func resolvePendingConflict(_ policy: ConflictPolicy) async {
        guard let pending = pendingConflict else { return }
        pendingConflict = nil

        let resolved = TransferRequest(
            direction: pending.request.direction,
            name: pending.request.name,
            remoteDirectory: pending.request.remoteDirectory,
            byteCount: pending.request.byteCount,
            conflictPolicy: policy
        )
        update(pending.transferId) { $0.status = .running }

        do {
            let ticket = try await client.createTransfer(resolved)
            try await sendChunks(
                localId: pending.transferId, ticket: ticket, payload: pending.payload
            )
        } catch {
            update(pending.transferId) { $0.status = .failed("\(error)") }
        }
    }

    public func discardPendingConflict() async {
        guard let pending = pendingConflict else { return }
        pendingConflict = nil
        update(pending.transferId) { $0.status = .cancelled }
    }

    // MARK: - Download

    /// Called from the download button after the user chose a destination.
    public func startDownload(_ entry: FileEntry, to destination: URL) async {
        let directory = FileBrowserViewModel.parentPath(of: entry.path) ?? "/"
        let request = TransferRequest(
            direction: .download,
            name: entry.name,
            remoteDirectory: directory,
            byteCount: entry.size ?? 0,
            conflictPolicy: nil
        )
        let localId = "local-\(transfers.count + 1)"
        transfers.append(
            TransferState(
                id: localId, name: entry.name, direction: .download,
                destinationPath: destination.path,
                progress: TransferProgress(sent: 0, total: entry.size ?? 0),
                status: .running, sha256: nil
            )
        )
        retryPayloads[localId] = (request, Data())
        downloadDestinations[localId] = destination

        guard isOnline else {
            update(localId) { $0.status = .failed("offline") }
            return
        }
        progressSamples = []

        do {
            let ticket = try await client.createTransfer(request)
            var payload = Data()
            for index in 0..<max(ticket.totalChunks, 1) {
                if state(localId)?.status == .cancelled {
                    try await client.cancelTransfer(transferId: ticket.id)
                    return
                }
                payload.append(
                    try await client.downloadChunk(transferId: ticket.id, index: index)
                )
                update(localId) { $0.progress.sent = Int64(payload.count) }
                progressSamples.append(Double(index + 1) / Double(max(ticket.totalChunks, 1)))
            }

            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try payload.write(to: destination, options: .atomic)

            update(localId) {
                $0.status = .completed
                $0.sha256 = TransferCoordinator.checksum(payload)
                $0.progress = TransferProgress(
                    sent: Int64(payload.count), total: Int64(payload.count)
                )
            }
        } catch {
            update(localId) { $0.status = .failed("\(error)") }
        }
    }

    // MARK: - Cancel and retry

    public func cancel(_ id: String) async {
        if pendingConflict?.transferId == id { pendingConflict = nil }
        update(id) { $0.status = .cancelled }
    }

    /// Only ever called from the retry button.
    public func retry(_ id: String) async {
        guard let saved = retryPayloads[id] else { return }
        guard let destination = downloadDestinations[id] else {
            update(id) { $0.status = .running }
            await performUpload(localId: id, request: saved.request, payload: saved.payload)
            return
        }
        transfers.removeAll { $0.id == id }
        await startDownload(
            FileEntry(
                path: "\(saved.request.remoteDirectory)/\(saved.request.name)",
                name: saved.request.name, kind: .file, size: saved.request.byteCount
            ),
            to: destination
        )
    }

    // MARK: - Helpers

    private func state(_ id: String) -> TransferState? {
        transfers.first { $0.id == id }
    }

    private func update(_ id: String, _ mutate: (inout TransferState) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        var copy = transfers[index]
        mutate(&copy)
        transfers[index] = copy
    }
}
