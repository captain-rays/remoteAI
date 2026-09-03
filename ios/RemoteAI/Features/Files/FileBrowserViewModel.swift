import Foundation
import Observation

/// Drives the Files tab.
///
/// Nothing in this type starts a transfer. Uploads and downloads live in
/// `TransferCoordinator` and are only reachable from an explicit button action.
@MainActor
@Observable
public final class FileBrowserViewModel {
    public private(set) var listing: DirectoryListing?
    public private(set) var preview: FilePreview?
    public private(set) var recentDirectories: [String] = []
    public private(set) var favorites: [String] = []
    public private(set) var showHidden = false
    public private(set) var errorMessage: String?
    public var searchText = ""

    /// Mirrors `AppModel.isOnline`; offline browsing is cache-only.
    public var isOnline = true

    private let client: AgentClient
    private let preferences: PreferencesStore
    private var cachedListings: [String: DirectoryListing] = [:]
    private let recentLimit = 10

    public init(client: AgentClient, preferences: PreferencesStore) {
        self.client = client
        self.preferences = preferences
        self.showHidden = preferences.showHiddenFiles
    }

    public var currentPath: String? { listing?.path }

    public var visibleEntries: [FileEntry] {
        let entries = listing?.entries ?? []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.name.lowercased().contains(query) }
    }

    // MARK: - Navigation

    /// Loads the agent-selected home directory the first time Files is shown.
    /// Re-entering the tab keeps the user's current location intact.
    public func loadInitialDirectory() async {
        guard listing == nil, isOnline else { return }
        errorMessage = nil
        do {
            let result = try await client.initialDirectory()
            listing = result
            cachedListings[cacheKey(result.path)] = result
            recordRecent(result.path)
        } catch {
            errorMessage = "\(error)"
        }
    }

    public func open(_ path: String) async {
        errorMessage = nil
        preview = nil

        let normalized: String
        do {
            normalized = try FileBrowserViewModel.normalize(path)
        } catch {
            errorMessage = "This path is not allowed."
            return
        }

        guard isOnline else {
            guard let cached = cachedListings[cacheKey(normalized)] else {
                errorMessage = "This folder has not been loaded yet, and the Mac is offline."
                return
            }
            listing = cached
            recordRecent(normalized)
            return
        }

        do {
            let result = try await client.listFiles(path: normalized, showHidden: showHidden)
            listing = result
            cachedListings[cacheKey(normalized)] = result
            recordRecent(normalized)
        } catch {
            errorMessage = "\(error)"
        }
    }

    public func openParent() async {
        guard let parent = listing?.parentPath else { return }
        await open(parent)
    }

    /// Explicit pull-to-refresh. Re-lists the current folder and nothing else.
    public func refresh() async {
        guard let path = listing?.path else { return }
        await open(path)
    }

    private func recordRecent(_ path: String) {
        recentDirectories.removeAll { $0 == path }
        recentDirectories.insert(path, at: 0)
        if recentDirectories.count > recentLimit {
            recentDirectories.removeLast(recentDirectories.count - recentLimit)
        }
    }

    private func cacheKey(_ path: String) -> String { "\(showHidden ? "h" : "n"):\(path)" }

    // MARK: - Hidden and favourite folders

    /// Sensitive system folders stay hidden until the user confirms a prompt.
    public func revealSensitiveEntries(confirmed: Bool) async {
        guard confirmed else { return }
        showHidden = true
        preferences.setShowHiddenFiles(true)
        await refresh()
    }

    public func hideSensitiveEntries() async {
        showHidden = false
        preferences.setShowHiddenFiles(false)
        await refresh()
    }

    public func toggleFavorite(_ path: String) {
        if let index = favorites.firstIndex(of: path) {
            favorites.remove(at: index)
        } else {
            favorites.append(path)
        }
    }

    public func isFavorite(_ path: String) -> Bool { favorites.contains(path) }

    // MARK: - Preview

    public func loadPreview(_ entry: FileEntry, maxBytes: Int = 64 * 1024) async {
        guard entry.kind == .file else { return }
        guard isOnline else {
            errorMessage = "Previews need a connection to the Mac."
            return
        }
        do {
            preview = try await client.filePreview(path: entry.path, maxBytes: maxBytes)
        } catch {
            errorMessage = "\(error)"
        }
    }

    public func clearPreview() { preview = nil }

    public static func parentPath(of path: String) -> String? {
        guard path != "/" else { return nil }
        var components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return nil }
        components.removeLast()
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    static func normalize(_ path: String) throws -> String {
        guard path.hasPrefix("/") else { throw AgentClientError.rejected("relative_path") }
        let components = path.split(separator: "/")
        guard !components.contains(".."), !components.contains(".") else {
            throw AgentClientError.rejected("path_traversal")
        }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }
}
