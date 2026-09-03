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

/// Read-only mobile cache. Keyed by provider so an offline switch can never
/// surface the other AI's rows.
public protocol CatalogCache: Sendable {
    func snapshot(for provider: ProviderId) -> CatalogSnapshot?
    func store(_ snapshot: CatalogSnapshot)
    func clear()
}

public final class InMemoryCatalogCache: CatalogCache, @unchecked Sendable {
    private var snapshots: [ProviderId: CatalogSnapshot] = [:]
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

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        snapshots.removeAll()
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

    public convenience init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.init(directory: base.appendingPathComponent("RemoteAI/catalog", isDirectory: true))
    }

    private func url(for provider: ProviderId) -> URL {
        directory.appendingPathComponent("\(provider.rawValue).json")
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

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        for provider in ProviderId.allCases {
            try? FileManager.default.removeItem(at: url(for: provider))
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
