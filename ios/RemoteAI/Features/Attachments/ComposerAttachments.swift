import Foundation
import Observation

/// The files staged on one composer, and their trip to the Mac.
///
/// Every entry here exists because the reader picked a file: there is no
/// watcher, no timer and no lifecycle hook that can add one. A file is
/// uploaded as soon as it is picked, so the message that names it is sent
/// against a path that already exists.
@MainActor
@Observable
public final class ComposerAttachments {
    public struct Item: Identifiable, Sendable, Hashable {
        public enum State: Sendable, Hashable {
            case uploading(Double)
            /// Uploaded. The path is the one the Mac reported writing, which
            /// is what the provider is handed.
            case ready(String)
            case failed(String)
        }

        public let id: UUID
        public let name: String
        public internal(set) var state: State
    }

    /// Above this a file is refused before any byte moves. A phone on a train
    /// uploading a 4K video chunk by chunk helps nobody, and the reader would
    /// be left watching a spinner with no way to tell it had stalled.
    public static let byteLimit = 50 * 1024 * 1024

    public private(set) var items: [Item] = []

    private let transfers: TransferCoordinator
    private let directory: () async throws -> String
    /// Kept only so a failed upload can be retried without asking the reader
    /// to pick the file again. Dropped the moment it lands.
    private var payloads: [UUID: Data] = [:]

    public init(transfers: TransferCoordinator, directory: @escaping () async throws -> String) {
        self.transfers = transfers
        self.directory = directory
    }

    /// Mirrors the screen's connectivity, so a file cannot be picked into a
    /// composer that has no Mac to send it to.
    public var isOnline: Bool {
        get { transfers.isOnline }
        set { transfers.isOnline = newValue }
    }

    /// The paths a send should carry.
    public var readyPaths: [String] {
        items.compactMap { item in
            if case let .ready(path) = item.state { return path }
            return nil
        }
    }

    /// Nothing is still moving, so a send would carry exactly what the reader
    /// can see attached.
    public var isSettled: Bool {
        !items.contains { item in
            if case .uploading = item.state { return true }
            return false
        }
    }

    public var isEmpty: Bool { items.isEmpty }

    /// Stage one picked file and start carrying it over.
    public func attach(name: String, data: Data) async {
        let id = UUID()
        guard data.count <= Self.byteLimit else {
            items.append(Item(id: id, name: name, state: .failed("File is larger than 50 MB.")))
            return
        }
        items.append(Item(id: id, name: name, state: .uploading(0)))
        payloads[id] = data
        await carry(id)
    }

    public func retry(_ id: UUID) async {
        guard payloads[id] != nil else { return }
        setState(id, .uploading(0))
        await carry(id)
    }

    public func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        payloads[id] = nil
    }

    /// Called after a send, so the next message starts with nothing attached.
    /// The files themselves stay on the Mac — they were named in a message.
    public func clear() {
        items.removeAll()
        payloads.removeAll()
    }

    private func carry(_ id: UUID) async {
        guard let data = payloads[id],
            let name = items.first(where: { $0.id == id })?.name
        else { return }
        do {
            let destination = try await directory()
            let written = try await transfers.upload(
                name: name, data: data, to: destination,
                progress: { [weak self] fraction in
                    guard let self else { return }
                    MainActor.assumeIsolated { self.setState(id, .uploading(fraction)) }
                }
            )
            setState(id, .ready(written))
            payloads[id] = nil
        } catch {
            setState(id, .failed(Self.message(for: error)))
        }
    }

    private func setState(_ id: UUID, _ state: Item.State) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        // A removed-then-recreated entry must not be revived by a late
        // progress call from the upload it no longer owns.
        items[index].state = state
    }

    private static func message(for error: Error) -> String {
        if case let AgentClientError.transport(reason) = error {
            return reason == "offline"
                ? "The Mac is offline." : "The file did not reach the Mac."
        }
        return "The file did not reach the Mac."
    }
}
