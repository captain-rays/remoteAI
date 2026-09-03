import CryptoKit
import Foundation

/// A provider-scoped snapshot of everything the phone may show while offline.
///
/// Note there is deliberately no file-content field: downloaded bytes are never
/// cached, only metadata the user already browsed.
public struct CatalogSnapshot: Codable, Sendable, Hashable {
    public let provider: ProviderId
    public let dailyConversations: [ConversationSummary]
    public let projects: [ProjectSummary]
    public let projectConversations: [String: [ConversationSummary]]

    public init(
        provider: ProviderId,
        dailyConversations: [ConversationSummary],
        projects: [ProjectSummary],
        projectConversations: [String: [ConversationSummary]] = [:]
    ) {
        self.provider = provider
        self.dailyConversations = dailyConversations
        self.projects = projects
        self.projectConversations = projectConversations
    }

    public static func empty(_ provider: ProviderId) -> CatalogSnapshot {
        CatalogSnapshot(provider: provider, dailyConversations: [], projects: [])
    }
}

public struct HistorySnapshot: Sendable, Hashable {
    public let provider: ProviderId
    public let conversationId: String
    public let events: [EventEnvelope]
    public let hasMore: Bool
    public let nextCursor: String?

    public init(
        provider: ProviderId,
        conversationId: String,
        events: [EventEnvelope],
        hasMore: Bool,
        nextCursor: String?
    ) {
        self.provider = provider
        self.conversationId = conversationId
        self.events = events
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }
}

/// Read-only mobile cache. Keyed by provider so an offline switch can never
/// surface the other AI's rows.
public protocol CatalogCache: Sendable {
    func snapshot(for provider: ProviderId) -> CatalogSnapshot?
    func store(_ snapshot: CatalogSnapshot)
    func history(provider: ProviderId, conversationId: String) -> HistorySnapshot?
    func storeHistory(_ snapshot: HistorySnapshot)
    func clear()
}

public final class InMemoryCatalogCache: CatalogCache, @unchecked Sendable {
    private var snapshots: [ProviderId: CatalogSnapshot] = [:]
    private var histories: [String: HistorySnapshot] = [:]
    private let lock = NSLock()

    public init() {}

    public func snapshot(for provider: ProviderId) -> CatalogSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[provider]
    }

    public func store(_ snapshot: CatalogSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        snapshots[snapshot.provider] = snapshot
    }

    public func history(provider: ProviderId, conversationId: String) -> HistorySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return histories[Self.historyKey(provider: provider, conversationId: conversationId)]
    }

    public func storeHistory(_ snapshot: HistorySnapshot) {
        lock.lock()
        defer { lock.unlock() }
        histories[
            Self.historyKey(provider: snapshot.provider, conversationId: snapshot.conversationId)
        ] = snapshot
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        snapshots.removeAll()
        histories.removeAll()
    }

    private static func historyKey(provider: ProviderId, conversationId: String) -> String {
        "\(provider.rawValue)\u{0}\(conversationId)"
    }
}

/// JSON-on-disk cache used by the app.
///
/// The plan called for SwiftData; a file-backed store is used instead because
/// it is exercised by the same suites that run without a simulator. Swapping in
/// SwiftData later only needs a new `CatalogCache` conformance.
public final class FileCatalogCache: CatalogCache, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    private struct HistoryArchive: Codable {
        let provider: ProviderId
        let conversationId: String
        let eventData: [Data]
        let hasMore: Bool
        let nextCursor: String?
    }

    public convenience init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.init(directory: base.appendingPathComponent("RemoteAI/catalog", isDirectory: true))
    }

    private func url(for provider: ProviderId) -> URL {
        directory.appendingPathComponent("\(provider.rawValue).json")
    }

    private func historyURL(provider: ProviderId, conversationId: String) -> URL {
        let key = Data("\(provider.rawValue)\u{0}\(conversationId)".utf8)
        let digest = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("history-\(provider.rawValue)-\(digest).json")
    }

    public func snapshot(for provider: ProviderId) -> CatalogSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url(for: provider)) else { return nil }
        return try? ProtocolCoding.decoder.decode(CatalogSnapshot.self, from: data)
    }

    public func store(_ snapshot: CatalogSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? ProtocolCoding.encoder.encode(snapshot) else { return }
        try? data.write(to: url(for: snapshot.provider), options: .atomic)
    }

    public func history(provider: ProviderId, conversationId: String) -> HistorySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: historyURL(
            provider: provider, conversationId: conversationId
        )),
            let archive = try? ProtocolCoding.decoder.decode(HistoryArchive.self, from: data),
            archive.provider == provider,
            archive.conversationId == conversationId,
            let events = try? archive.eventData.map(ProtocolCoding.decodeEvent(from:))
        else { return nil }
        return HistorySnapshot(
            provider: provider,
            conversationId: conversationId,
            events: events,
            hasMore: archive.hasMore,
            nextCursor: archive.nextCursor
        )
    }

    public func storeHistory(_ snapshot: HistorySnapshot) {
        lock.lock()
        defer { lock.unlock() }
        guard let eventData = try? snapshot.events.map(ProtocolCoding.encodeEvent(_:)) else {
            return
        }
        let archive = HistoryArchive(
            provider: snapshot.provider,
            conversationId: snapshot.conversationId,
            eventData: eventData,
            hasMore: snapshot.hasMore,
            nextCursor: snapshot.nextCursor
        )
        guard let data = try? ProtocolCoding.encoder.encode(archive) else { return }
        try? data.write(
            to: historyURL(
                provider: snapshot.provider,
                conversationId: snapshot.conversationId
            ),
            options: .atomic
        )
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        for provider in ProviderId.allCases {
            try? FileManager.default.removeItem(at: url(for: provider))
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("history-") {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}

public protocol PreferencesStore: Sendable {
    var lastProvider: ProviderId? { get }
    func setLastProvider(_ provider: ProviderId)
    var showHiddenFiles: Bool { get }
    func setShowHiddenFiles(_ value: Bool)
}

public final class InMemoryPreferencesStore: PreferencesStore, @unchecked Sendable {
    private var provider: ProviderId?
    private var hidden = false
    private let lock = NSLock()

    public init(lastProvider: ProviderId? = nil) {
        self.provider = lastProvider
    }

    public var lastProvider: ProviderId? {
        lock.lock()
        defer { lock.unlock() }
        return provider
    }

    public func setLastProvider(_ provider: ProviderId) {
        lock.lock()
        defer { lock.unlock() }
        self.provider = provider
    }

    public var showHiddenFiles: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hidden
    }

    public func setShowHiddenFiles(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        hidden = value
    }
}

public final class UserDefaultsPreferencesStore: PreferencesStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let providerKey = "remoteai.lastProvider"
    private let hiddenKey = "remoteai.showHiddenFiles"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var lastProvider: ProviderId? {
        defaults.string(forKey: providerKey).flatMap(ProviderId.init(rawValue:))
    }

    public func setLastProvider(_ provider: ProviderId) {
        defaults.set(provider.rawValue, forKey: providerKey)
    }

    public var showHiddenFiles: Bool {
        defaults.bool(forKey: hiddenKey)
    }

    public func setShowHiddenFiles(_ value: Bool) {
        defaults.set(value, forKey: hiddenKey)
    }
}
