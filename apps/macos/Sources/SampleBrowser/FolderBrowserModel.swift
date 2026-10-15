import AppKit
import Combine
import Foundation

struct FolderEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    // Standardizing a file URL can query its volume. SwiftUI reads row IDs on
    // every selection update, so normalize once when the directory is read.
    let id: String
    init(url: URL, name: String? = nil, isDirectory: Bool) {
        self.url = url.standardizedFileURL
        self.id = self.url.path
        self.name = name ?? url.lastPathComponent
        self.isDirectory = isDirectory
    }

    /// Index rows already contain a normalized absolute path. Reconstructing a
    /// search result must not contact its volume, which may currently be offline.
    init(indexedPath: String, name: String, isDirectory: Bool) {
        self.id = indexedPath
        self.url = URL(fileURLWithPath: indexedPath, isDirectory: isDirectory)
        self.name = name
        self.isDirectory = isDirectory
    }
}

struct FolderColumn: Identifiable, Equatable {
    let directoryURL: URL
    var title: String { directoryURL.lastPathComponent.isEmpty ? directoryURL.path : directoryURL.lastPathComponent }
    let id: String
    var entries: [FolderEntry] = []
    var selectedEntryID: String?
    var isLoading = true
    var error: String?

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.id = directoryURL.standardizedFileURL.path
    }

    init(directory: FolderEntry) {
        self.directoryURL = directory.url
        self.id = directory.id
    }
}

@MainActor final class FolderBrowserModel: ObservableObject {
    @Published private(set) var sources: [FolderSource] = []
    @Published private(set) var columns: [FolderColumn] = []
    @Published private(set) var selectedEntry: FolderEntry?
    @Published private(set) var selectedSourceID: UUID?
    @Published private(set) var favorites: [FolderFavorite] = []
    @Published private(set) var favoriteFolders: [FavoriteFolder] = [.defaultFolder]
    @Published private(set) var selectedFavoriteID: UUID?
    @Published private(set) var loading = false
    @Published var error: String?
    var onSelectAudio: ((URL) -> Void)?
    var onPreviewFavoriteAudio: ((URL) -> Void)?
    var onSelectFavoriteAudio: ((URL) -> Void)?
    var onSelectionChange: ((FolderEntry?) -> Void)?
    nonisolated static let supportedExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "flac"]

    private let store: FolderBrowserStore
    private let reader: @Sendable (URL) async throws -> [FolderEntry]
    private let favoriteResolver: @Sendable (URL, Data?) async throws -> URL
    private var task: Task<Void, Never>?
    private var favoritePreviewTask: Task<Void, Never>?
    private var favoriteResolutionTask: Task<FavoriteResolution, Error>?
    private var favoritePreviewGeneration = UUID()
    private var generation = UUID()
    private var securityScopedURLs: [URL] = []
    private var started = false
    private var favoritePaths: Set<String> = []
    private var favoriteEntries: [UUID: FolderEntry] = [:]

    init(store: FolderBrowserStore = FolderBrowserStore(), reader: (@Sendable (URL) async throws -> [FolderEntry])? = nil,
         favoriteResolver: (@Sendable (URL, Data?) async throws -> URL)? = nil) {
        self.store = store
        self.reader = reader ?? { url in try await Self.readDirectory(url) }
        self.favoriteResolver = favoriteResolver ?? { url, bookmark in Self.resolve(url, bookmark: bookmark) }
        do {
            let state = try store.load()
            sources = state.sources
            updateFavorites(state.favorites)
            favoriteFolders = state.favoriteFolders
        } catch { self.error = "フォルダ設定の読込: \(error.localizedDescription)" }
    }

    deinit {
        task?.cancel()
        favoritePreviewTask?.cancel(); favoriteResolutionTask?.cancel()
        for url in securityScopedURLs { url.stopAccessingSecurityScopedResource() }
    }

    func startup() {
        guard !started else { return }
        started = true
        if let first = sources.first { openSource(first.id) }
    }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "サンプルフォルダを追加"
        panel.message = "Finder に接続済みの NAS、またはこの Mac のフォルダを選択してください。"
        panel.prompt = "フォルダを追加"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { addSource(url) }
    }

    func addSource(_ url: URL) {
        guard url.isFileURL else { error = FolderBrowserError.invalidURL.localizedDescription; return }
        let url = url.standardizedFileURL
        if let existing = sources.first(where: { $0.url.standardizedFileURL.path == url.path }) { openSource(existing.id); return }
        guard sources.count < 64 else { error = FolderBrowserError.tooManySources.localizedDescription; return }
        let token = beginNavigation()
        columns = [FolderColumn(directoryURL: url)]
        selectedSourceID = nil
        clearSelection()
        task = Task {
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw FolderBrowserError.invalidURL }
                    return Self.bookmark(for: url)
                }.value
                guard isCurrent(token) else { return }
                let source = FolderSource(id: UUID(), name: String((url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent).prefix(120)), savedPath: url.path, bookmark: prepared)
                // Retain access before reading the directory for sandbox-compatible future builds.
                retainAccess(to: url)
                var next = sources; next.append(source)
                try store.save(FolderBrowserState(sources: next, favorites: favorites, favoriteFolders: favoriteFolders))
                sources = next; selectedSourceID = source.id
                _ = await populateColumn(0, token: token)
            } catch { failColumn(0, error: error, token: token) }
            finish(token)
        }
    }

    func removeSource(_ id: UUID) {
        let next = sources.filter { $0.id != id }
        guard next != sources else { return }
        do {
            // Keep favorites as independently reopenable local aliases.
            let detached = favorites.map { favorite -> FolderFavorite in
                guard favorite.sourceID == id else { return favorite }
                var copy = favorite; copy.sourceID = nil; copy.relativePath = nil
                return copy
            }
            try store.save(FolderBrowserState(sources: next, favorites: detached, favoriteFolders: favoriteFolders))
            sources = next; updateFavorites(detached)
            if selectedSourceID == id {
                _ = beginNavigation(); columns = []; selectedSourceID = nil; loading = false; clearSelection()
            }
        } catch { self.error = error.localizedDescription }
    }

    func openSource(_ id: UUID) {
        guard let source = sources.first(where: { $0.id == id }) else { return }
        let token = beginNavigation()
        selectedSourceID = id; clearSelection()
        columns = [FolderColumn(directoryURL: source.url)]
        task = Task {
            let resolved = await Task.detached(priority: .userInitiated) { Self.resolve(source.url, bookmark: source.bookmark) }.value
            guard isCurrent(token) else { return }
            retainAccess(to: resolved)
            if resolved != source.url { updateSourcePath(id, url: resolved) }
            columns = [FolderColumn(directoryURL: resolved)]
            _ = await populateColumn(0, token: token)
            finish(token)
        }
    }

    func select(_ entry: FolderEntry, inColumn index: Int) {
        guard columns.indices.contains(index), columns[index].entries.contains(where: { $0.id == entry.id }) else { return }
        let token = beginNavigation()
        var nextColumns = Array(columns.prefix(index + 1))
        nextColumns[index].selectedEntryID = entry.id
        if entry.isDirectory { nextColumns.append(FolderColumn(directory: entry)) }
        columns = nextColumns
        selectedEntry = entry
        onSelectionChange?(entry)
        if entry.isDirectory {
            task = Task { _ = await populateColumn(index + 1, token: token); finish(token) }
        } else {
            loading = false
            onSelectAudio?(entry.url)
        }
    }

    /// Left closes the current branch and selects its directory in the parent.
    /// The registered source is the boundary; it never navigates above column 0.
    func navigateToParent(fromColumn index: Int) -> Int? {
        guard index > 0, columns.indices.contains(index) else { return nil }
        let parentIndex = index - 1
        let directoryID = columns[index].id
        guard let directory = columns[parentIndex].entries.first(where: { $0.isDirectory && $0.id == directoryID }) else { return nil }
        _ = beginNavigation()
        var nextColumns = Array(columns.prefix(index))
        nextColumns[parentIndex].selectedEntryID = directory.id
        columns = nextColumns
        selectedEntry = directory; loading = false
        onSelectionChange?(directory)
        return parentIndex
    }

    /// Right reveals the selected directory. Reuse its column, including an
    /// in-flight read; the view controls which child row receives selection.
    func navigateIntoDirectory(fromColumn index: Int) -> Int? {
        guard columns.indices.contains(index), let selectedID = columns[index].selectedEntryID,
              let directory = columns[index].entries.first(where: { $0.id == selectedID && $0.isDirectory }) else { return nil }
        let nextIndex = index + 1
        if columns.indices.contains(nextIndex), columns[nextIndex].id == directory.id {
            return nextIndex
        }
        select(directory, inColumn: index)
        return nextIndex
    }

    func retryColumn(_ index: Int) {
        guard columns.indices.contains(index) else { return }
        if index == 0, let id = selectedSourceID { openSource(id); return }
        let token = beginNavigation()
        var nextColumns = Array(columns.prefix(index + 1))
        nextColumns[index].error = nil; nextColumns[index].isLoading = true
        columns = nextColumns
        task = Task { _ = await populateColumn(index, token: token); finish(token) }
    }

    func refresh() {
        guard let index = columns.indices.last else {
            if let source = sources.first { openSource(source.id) }
            return
        }
        let token = beginNavigation()
        columns[index].error = nil; columns[index].isLoading = true
        task = Task {
            if await populateColumn(index, token: token), isCurrent(token),
               let selectedID = columns[index].selectedEntryID {
                if let refreshed = columns[index].entries.first(where: { $0.id == selectedID }) {
                    if selectedEntry?.id == selectedID { selectedEntry = refreshed }
                } else {
                    columns[index].selectedEntryID = nil
                    if selectedEntry?.id == selectedID { clearSelection() }
                }
            }
            finish(token)
        }
    }

    func isFavorite(_ entry: FolderEntry) -> Bool { favoritePaths.contains(entry.id) }

    func isFavorite(_ url: URL) -> Bool { favoritePaths.contains(url.standardizedFileURL.path) }

    func favorites(in folderID: UUID?) -> [FolderFavorite] {
        guard let folderID else { return favorites }
        return favorites.filter { $0.folderIDs.contains(folderID) }
    }

    /// Saved favorite paths are normalized when their snapshot changes, not
    /// while drawing rows or filtering an offline library.
    func entry(for favorite: FolderFavorite) -> FolderEntry {
        favoriteEntries[favorite.id] ?? FolderEntry(indexedPath: favorite.savedPath, name: (favorite.savedPath as NSString).lastPathComponent, isDirectory: favorite.isDirectory)
    }

    @discardableResult func createFavoriteFolder(name: String) -> UUID? {
        guard let name = validatedFavoriteFolderName(name) else { return nil }
        guard favoriteFolders.count < 64 else { error = FolderBrowserError.tooManyFavoriteFolders.localizedDescription; return nil }
        let folder = FavoriteFolder(id: UUID(), name: name)
        guard persistFavoriteState(favorites, folders: favoriteFolders + [folder]) else { return nil }
        return folder.id
    }

    func renameFavoriteFolder(_ id: UUID, name: String) {
        guard let name = validatedFavoriteFolderName(name, excluding: id), let index = favoriteFolders.firstIndex(where: { $0.id == id }) else { return }
        var next = favoriteFolders; next[index].name = name
        _ = persistFavoriteState(favorites, folders: next)
    }

    func removeFavoriteFolder(_ id: UUID) {
        let remaining = favoriteFolders.filter { $0.id != id }
        guard remaining.count != favoriteFolders.count else { return }
        let aliases = favorites.map { favorite -> FolderFavorite in
            var copy = favorite; copy.folderIDs.removeAll { $0 == id }; return copy
        }
        // Removing an organizational folder never removes a favorite or source file.
        _ = persistFavoriteState(aliases, folders: remaining)
    }

    func addFavorite(_ entry: FolderEntry, to folderID: UUID) {
        guard favoriteFolders.contains(where: { $0.id == folderID }) else { return }
        if let favorite = favorites.first(where: { $0.url.standardizedFileURL.path == entry.id }) {
            setFavoriteMembership(favorite.id, folderID: folderID, included: true)
            return
        }
        guard favorites.count < 2000 else { error = FolderBrowserError.tooManyFavorites.localizedDescription; return }
        persistFavorites(favorites + [favorite(for: entry, folderIDs: [folderID])])
    }

    func setFavoriteMembership(_ id: UUID, folderID: UUID, included: Bool) {
        guard favoriteFolders.contains(where: { $0.id == folderID }), let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        guard favorites[index].folderIDs.contains(folderID) != included else { return }
        var next = favorites
        if included { next[index].folderIDs.append(folderID) }
        else { next[index].folderIDs.removeAll { $0 == folderID } }
        persistFavorites(next)
    }

    func toggleFavorite(_ entry: FolderEntry) {
        if let favorite = favorites.first(where: { $0.url.standardizedFileURL.path == entry.id }) { removeFavorite(favorite.id); return }
        guard favorites.count < 2000 else { error = FolderBrowserError.tooManyFavorites.localizedDescription; return }
        let folderID = favoriteFolders.first(where: { $0.id == FavoriteFolder.defaultID })?.id ?? favoriteFolders.first?.id
        persistFavorites(favorites + [favorite(for: entry, folderIDs: folderID.map { [$0] } ?? [])])
    }

    private func favorite(for entry: FolderEntry, folderIDs: [UUID]) -> FolderFavorite {
        let source = sources.filter { Self.relativePath(of: entry.url, within: $0.url) != nil }.max { $0.savedPath.count < $1.savedPath.count }
        return FolderFavorite(id: UUID(), name: String(entry.name.prefix(120)), savedPath: entry.url.path, isDirectory: entry.isDirectory, sourceID: source?.id, relativePath: source.flatMap { Self.relativePath(of: entry.url, within: $0.url) }, bookmark: nil, folderIDs: folderIDs)
    }

    func renameFavorite(_ id: UUID, name: String) {
        guard let name = validatedFavoriteName(name) else { return }
        guard let index = favorites.firstIndex(where: { $0.id == id }) else { return }
        var next = favorites; next[index].name = name
        persistFavorites(next)
    }

    func removeFavorite(_ id: UUID) { persistFavorites(favorites.filter { $0.id != id }) }

    /// Audition a file in place: the folder browser's columns and selection stay
    /// intact, so returning to folders restores the user's browsing position.
    func previewFavorite(_ id: UUID, explicitPlayback: Bool = true) {
        guard let favorite = favorites.first(where: { $0.id == id }), !favorite.isDirectory else { return }
        cancelFavoritePreview()
        // A previously requested ancestor walk must not later select a file over
        // this favorite. Preserve completed columns and make interrupted reads retryable.
        task?.cancel(); task = nil; generation = UUID(); loading = false
        for index in columns.indices where columns[index].isLoading {
            columns[index].isLoading = false
            columns[index].error = "フォルダを再読み込みしてください。"
        }
        selectedFavoriteID = id; error = nil
        onSelectionChange?(nil)
        let token = favoritePreviewGeneration
        let source = sources.first(where: { $0.id == favorite.sourceID })
        let resolver = favoriteResolver
        let resolution = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let root: URL, target: URL
            if let source {
                root = try await resolver(source.url, source.bookmark).standardizedFileURL
                if let relative = favorite.relativePath {
                    target = root.appendingPathComponent(relative, isDirectory: false).standardizedFileURL
                } else {
                    target = try await resolver(favorite.url, favorite.bookmark).standardizedFileURL
                }
            } else {
                target = try await resolver(favorite.url, favorite.bookmark).standardizedFileURL
                root = target
            }
            try Task.checkCancellation()
            return FavoriteResolution(root: root, target: target)
        }
        favoriteResolutionTask = resolution
        favoritePreviewTask = Task {
            do {
                let resolved = try await resolution.value
                guard isCurrentFavorite(token, id: id) else { return }
                retainAccess(to: resolved.root)
                if resolved.target != resolved.root { retainAccess(to: resolved.target) }
                // File metadata can block on disconnected SMB volumes. Resolve
                // and validate away from the main actor; navigation uses no reader.
                try await Task.detached(priority: .userInitiated) {
                    let values = try resolved.target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                          Self.supportedExtensions.contains(resolved.target.pathExtension.lowercased()) else {
                        throw FolderBrowserError.unavailable(favorite.name)
                    }
                }.value
                guard isCurrentFavorite(token, id: id) else { return }
                if let source, source.url != resolved.root { updateSourcePath(source.id, url: resolved.root) }
                favoritePreviewTask = nil; favoriteResolutionTask = nil
                if explicitPlayback { onPreviewFavoriteAudio?(resolved.target) }
                else { onSelectFavoriteAudio?(resolved.target) }
            } catch is CancellationError { }
            catch {
                guard isCurrentFavorite(token, id: id) else { return }
                favoritePreviewTask = nil; favoriteResolutionTask = nil
                self.error = FolderBrowserError.unavailable(favorite.name).localizedDescription
            }
        }
    }

    func cancelFavoritePreview() {
        favoritePreviewGeneration = UUID()
        favoritePreviewTask?.cancel(); favoritePreviewTask = nil
        favoriteResolutionTask?.cancel(); favoriteResolutionTask = nil
        selectedFavoriteID = nil
    }

    /// Filtering or removing a selected favorite clears its audio as well as
    /// invalidating any pending resolution, while leaving saved aliases intact.
    func clearFavoriteSelection() {
        guard selectedFavoriteID != nil else { return }
        cancelFavoritePreview()
        onSelectionChange?(nil)
    }

    func selectFavoriteDirectory(_ id: UUID) {
        guard favorites.contains(where: { $0.id == id && $0.isDirectory }) else { return }
        cancelFavoritePreview()
        selectedFavoriteID = id
        onSelectionChange?(nil)
    }

    func openFavorite(_ id: UUID) {
        guard let favorite = favorites.first(where: { $0.id == id }) else { return }
        let source = sources.first(where: { $0.id == favorite.sourceID })
        openLocation(FolderEntry(url: favorite.url, name: favorite.name, isDirectory: favorite.isDirectory), source: source, relativePath: favorite.relativePath)
    }

    /// Search results can reveal their location without becoming favorites.
    func openEntryLocation(_ entry: FolderEntry) {
        guard entry.url.isFileURL else { error = FolderBrowserError.invalidURL.localizedDescription; return }
        let source = sources.filter { Self.relativePath(of: entry.url, within: $0.url) != nil }.max { $0.savedPath.count < $1.savedPath.count }
        openLocation(entry, source: source, relativePath: source.flatMap { Self.relativePath(of: entry.url, within: $0.url) })
    }

    private func openLocation(_ entry: FolderEntry, source: FolderSource?, relativePath: String?) {
        let token = beginNavigation()
        clearSelection(); selectedSourceID = source?.id
        let fallbackRoot = entry.isDirectory ? entry.url : entry.url.deletingLastPathComponent()
        columns = [FolderColumn(directoryURL: source?.url ?? fallbackRoot)]
        task = Task {
            let root = await Task.detached(priority: .userInitiated) { Self.resolve(source?.url ?? fallbackRoot, bookmark: source?.bookmark) }.value
            guard isCurrent(token) else { return }
            retainAccess(to: root)
            if let source, root != source.url { updateSourcePath(source.id, url: root) }
            let target = source != nil && relativePath != nil ? root.appendingPathComponent(relativePath!, isDirectory: entry.isDirectory).standardizedFileURL : entry.url
            columns = [FolderColumn(directoryURL: root)]
            guard await populateColumn(0, token: token), isCurrent(token) else { finish(token); return }
            guard let relative = Self.relativePath(of: target, within: root) else { finish(token); return }
            let components = relative.split(separator: "/").map(String.init)
            if components.isEmpty {
                selectedEntry = FolderEntry(url: root, isDirectory: true)
                onSelectionChange?(selectedEntry)
            }
            var index = 0
            for component in components {
                guard isCurrent(token) else { return }
                guard let found = columns[index].entries.first(where: { $0.url.lastPathComponent == component }) else {
                    failColumn(index, error: FolderBrowserError.unavailable(entry.name), token: token); finish(token); return
                }
                columns[index].selectedEntryID = found.id
                selectedEntry = found
                if found.isDirectory {
                    columns.append(FolderColumn(directory: found)); index += 1
                    guard await populateColumn(index, token: token) else { finish(token); return }
                } else {
                    onSelectionChange?(found); onSelectAudio?(found.url)
                }
            }
            if selectedEntry?.isDirectory == true { onSelectionChange?(selectedEntry) }
            finish(token)
        }
    }

    /// Synchronizes asynchronous directory navigation in integration tests.
    func waitForIdle() async { await task?.value; await favoritePreviewTask?.value }

    private func beginNavigation() -> UUID {
        cancelFavoritePreview()
        task?.cancel(); generation = UUID(); loading = true; error = nil
        return generation
    }
    private func isCurrent(_ token: UUID) -> Bool { token == generation && !Task.isCancelled }
    private func isCurrentFavorite(_ token: UUID, id: UUID) -> Bool {
        token == favoritePreviewGeneration && selectedFavoriteID == id && !Task.isCancelled
    }
    private func finish(_ token: UUID) { if isCurrent(token) { loading = false } }
    private func clearSelection() { selectedEntry = nil; onSelectionChange?(nil) }
    private func populateColumn(_ index: Int, token: UUID) async -> Bool {
        guard isCurrent(token), columns.indices.contains(index) else { return false }
        let url = columns[index].directoryURL
        do {
            let entries = try await reader(url)
            guard isCurrent(token), columns.indices.contains(index), columns[index].directoryURL == url else { return false }
            var column = columns[index]
            column.entries = entries; column.error = nil; column.isLoading = false
            columns[index] = column
            return true
        } catch {
            failColumn(index, error: error, token: token)
            return false
        }
    }
    private func failColumn(_ index: Int, error: Error, token: UUID) {
        guard isCurrent(token) else { return }
        let message = (error as? FolderBrowserError)?.localizedDescription ?? FolderBrowserError.unavailable(columns.indices.contains(index) ? columns[index].title : "フォルダ").localizedDescription
        if columns.indices.contains(index) {
            var column = columns[index]
            column.entries = []; column.error = message; column.isLoading = false
            columns[index] = column
        }
        self.error = message
    }
    private func persistFavorites(_ next: [FolderFavorite]) {
        _ = persistFavoriteState(next, folders: favoriteFolders)
    }
    private func persistFavoriteState(_ next: [FolderFavorite], folders: [FavoriteFolder]) -> Bool {
        do {
            try store.save(FolderBrowserState(sources: sources, favorites: next, favoriteFolders: folders))
            updateFavorites(next); favoriteFolders = folders; error = nil
            if let selectedFavoriteID, !next.contains(where: { $0.id == selectedFavoriteID }) { clearFavoriteSelection() }
            return true
        }
        catch { self.error = error.localizedDescription; return false }
    }
    private func updateFavorites(_ values: [FolderFavorite]) {
        // Normalize only when favorite state changes, never while drawing rows.
        favoriteEntries = Dictionary(uniqueKeysWithValues: values.map { favorite in
            let url: URL
            if let sourceID = favorite.sourceID, let relative = favorite.relativePath,
               let source = sources.first(where: { $0.id == sourceID }) {
                url = relative.isEmpty ? source.url : source.url.appendingPathComponent(relative, isDirectory: favorite.isDirectory)
            } else { url = favorite.url }
            let entry = FolderEntry(url: url, isDirectory: favorite.isDirectory)
            return (favorite.id, entry)
        })
        favoritePaths = Set(favoriteEntries.values.map(\.id))
        favorites = values
    }
    private func validatedFavoriteName(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, !name.contains(where: \.isNewline), !name.contains("\0") else {
            error = FolderBrowserError.invalidName.localizedDescription; return nil
        }
        return name
    }
    private func validatedFavoriteFolderName(_ value: String, excluding id: UUID? = nil) -> String? {
        guard let name = validatedFavoriteName(value) else { return nil }
        guard !favoriteFolders.contains(where: { $0.id != id && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            error = "同じ名前のお気に入りフォルダがあります。"; return nil
        }
        return name
    }
    private func updateSourcePath(_ id: UUID, url: URL) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        var next = sources; next[index].savedPath = url.path
        var aliases = favorites
        for index in aliases.indices where aliases[index].sourceID == id {
            if let relative = aliases[index].relativePath { aliases[index].savedPath = url.appendingPathComponent(relative).standardizedFileURL.path }
        }
        do { try store.save(FolderBrowserState(sources: next, favorites: aliases, favoriteFolders: favoriteFolders)); sources = next; updateFavorites(aliases) }
        catch { self.error = error.localizedDescription }
    }
    private func retainAccess(to url: URL) {
        guard !securityScopedURLs.contains(url) else { return }
        if url.startAccessingSecurityScopedResource() { securityScopedURLs.append(url) }
    }
    nonisolated static func relativePath(of url: URL, within root: URL) -> String? {
        let path = url.standardizedFileURL.path, rootPath = root.standardizedFileURL.path
        if path == rootPath { return "" }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
    nonisolated private static func bookmark(for url: URL) -> Data? {
        (try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil))
    }
    nonisolated private static func resolve(_ fallback: URL, bookmark: Data?) -> URL {
        guard let bookmark else { return fallback }
        var stale = false
        return (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale))?.standardizedFileURL ?? fallback
    }
    nonisolated static func readDirectory(_ url: URL) async throws -> [FolderEntry] {
        let work = Task.detached(priority: .userInitiated) {
            let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey], options: [.skipsHiddenFiles])
            var entries: [FolderEntry] = []
            for child in urls {
                try Task.checkCancellation()
                // Skip aliases/symlinks: a selected root cannot silently traverse another volume.
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey]), values.isHidden != true, values.isSymbolicLink != true else { continue }
                let isDirectory = values.isDirectory == true
                guard isDirectory || (values.isRegularFile == true && supportedExtensions.contains(child.pathExtension.lowercased())) else { continue }
                entries.append(FolderEntry(url: child, isDirectory: isDirectory))
            }
            return entries.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }
}

private struct FavoriteResolution: Sendable {
    let root: URL
    let target: URL
}
