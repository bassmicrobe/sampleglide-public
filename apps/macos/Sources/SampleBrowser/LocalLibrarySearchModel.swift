import Combine
import Foundation

struct LocalSearchResult: Identifiable, Equatable, Sendable {
    let entry: FolderEntry
    let sourceID: UUID
    let sourceName: String
    let notes: String
    let tags: [String]
    var id: String { entry.id }
    var path: String { entry.id }
    var name: String { entry.name }
    var isDirectory: Bool { entry.isDirectory }
}

/// The index lives on this Mac. Directory IO runs on its own utility queue, so a
/// slow NAS request never occupies the main actor or the SQLite search actor.
@MainActor final class LocalLibrarySearchModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { scheduleSearch(reset: true) } }
    }
    @Published private(set) var results: [LocalSearchResult] = []
    @Published var selectedID: String?
    @Published private(set) var isSearching = false
    @Published private(set) var hasMore = false
    @Published private(set) var resultCount = 0
    @Published private(set) var indexedCount = 0
    @Published private(set) var processedDirectoryCount = 0
    @Published private(set) var pendingDirectoryCount = 0
    @Published private(set) var isIndexing = false
    @Published private(set) var isPaused: Bool
    @Published private(set) var statusText = "検索インデックスを準備しています"
    @Published private(set) var errors: [String] = []
    /// Total directory count is unknown until traversal ends; avoid a misleading percentage.
    @Published private(set) var progress: Double?

    private struct SourceSnapshot: Equatable, Sendable {
        let id: UUID
        let name: String
        let path: String
        let bookmark: Data?
        var indexed: LocalIndexSource { LocalIndexSource(id: id, path: path, name: name) }
    }
    private struct AnnotationSnapshot: Equatable, Sendable {
        let path: String
        let notes: String
        let tags: [String]
        var indexed: LocalIndexAnnotation { LocalIndexAnnotation(path: path, notes: notes, tags: tags) }
    }

    private let preferences: UserDefaults
    private let reader: @Sendable (URL) async throws -> [FolderEntry]
    private let directoryWorker = LocalLibraryDirectoryWorker()
    private let storeTask: Task<LocalSearchIndexStore, Error>
    private let pageSize: Int
    private let debounceNanoseconds: UInt64
    private let directoryDelayNanoseconds: UInt64
    private var sources: [SourceSnapshot] = []
    private var annotations: [AnnotationSnapshot] = []
    private var appliedIndexedSources: [LocalIndexSource]?
    private var configured = false
    private var configurationGeneration = UUID()
    private var sourceGeneration = UUID()
    private var searchGeneration = UUID()
    private var configurationTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lastSearchRefresh = Date.distantPast
    private var nextSearchOffset = 0
    nonisolated static let pausePreferenceKey = "localLibraryIndexPaused"

    init(databaseURL: URL? = nil,
         directoryReader: (@Sendable (URL) async throws -> [FolderEntry])? = nil,
         preferences: UserDefaults = .standard,
         pageSize: Int = 200,
         debounceNanoseconds: UInt64 = 120_000_000,
         directoryDelayNanoseconds: UInt64 = 20_000_000,
         directoryRetryDelays: [TimeInterval] = [2, 10]) {
        self.preferences = preferences
        self.isPaused = preferences.bool(forKey: Self.pausePreferenceKey)
        self.pageSize = min(500, max(1, pageSize))
        self.debounceNanoseconds = debounceNanoseconds
        self.directoryDelayNanoseconds = directoryDelayNanoseconds
        let worker = directoryWorker
        self.reader = directoryReader ?? { url in try await worker.readDirectory(url) }
        let location = databaseURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jp.samplebrowser", isDirectory: true).appendingPathComponent("library-index.sqlite3")
        // Opening SQLite and creating its schema can touch disk, even before the
        // actor's first method. Keep initialization off the UI executor as well.
        self.storeTask = Task.detached(priority: .utility) {
            try LocalSearchIndexStore(databaseURL: location, retryDelays: directoryRetryDelays)
        }
    }

    deinit {
        configurationTask?.cancel(); indexTask?.cancel(); searchTask?.cancel()
        refreshTask?.cancel()
    }

    func configure(sources newSources: [FolderSource], annotations newAnnotations: [LocalAnnotation]) {
        let snapshots = newSources.map { SourceSnapshot(id: $0.id, name: $0.name, path: $0.savedPath, bookmark: $0.bookmark) }
        let indexedSources = snapshots.map(\.indexed)
        let roots = Dictionary(snapshots.map { ($0.id, $0.path) }, uniquingKeysWith: { _, new in new })
        let notes = newAnnotations.map { annotation in
            var path = annotation.savedPath
            if let id = annotation.sourceID, let root = roots[id], let relative = annotation.relativePath,
               !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") {
                path = relative.isEmpty ? root : (root == "/" ? root : root + "/") + relative
            }
            return AnnotationSnapshot(path: path, notes: annotation.notes, tags: annotation.tags)
        }
        let sourceChanged = !configured || snapshots != self.sources
        let annotationChanged = !configured || notes != self.annotations
        guard sourceChanged || annotationChanged else { return }
        configured = true
        self.sources = snapshots; self.annotations = notes
        configurationGeneration = UUID()
        let configurationToken = configurationGeneration
        if sourceChanged {
            sourceGeneration = UUID()
            indexTask?.cancel(); indexTask = nil
            refreshTask?.cancel(); refreshTask = nil
            // A removed root must disappear immediately, even if an old query
            // is still running. The generation also rejects its eventual reply.
            scheduleSearch(reset: true, start: false)
            isIndexing = !isPaused && !snapshots.isEmpty
        }
        configurationTask?.cancel()
        configurationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let store = try await storeTask.value
                guard isConfigurationCurrent(configurationToken) else { return }
                if appliedIndexedSources != indexedSources {
                    try await store.configureSources(indexedSources)
                    guard isConfigurationCurrent(configurationToken) else { return }
                    appliedIndexedSources = indexedSources
                }
                guard isConfigurationCurrent(configurationToken) else { return }
                try await store.replaceAnnotations(notes.map(\.indexed))
                guard isConfigurationCurrent(configurationToken) else { return }
                // New sources are queued by configureSources. Existing sources
                // resume durable unfinished work, while completed sources stay
                // complete until the user explicitly requests an update.
                guard isConfigurationCurrent(configurationToken) else { return }
                await updateStatus(store)
                scheduleSearch(reset: false)
                if !isPaused { startIndexing() }
            } catch {
                guard isConfigurationCurrent(configurationToken) else { return }
                reportStorageError(error)
            }
        }
    }

    func loadMore() {
        guard hasMore, !isSearching else { return }
        scheduleSearch(reset: false, append: true)
    }

    func pause() {
        isPaused = true
        preferences.set(true, forKey: Self.pausePreferenceKey)
        indexTask?.cancel(); indexTask = nil
        sourceGeneration = UUID()
        refreshTask?.cancel(); refreshTask = nil
        isIndexing = false
        statusText = "インデックス作成を一時停止中 · \(indexedCount.formatted()) 件を検索できます"
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        preferences.set(false, forKey: Self.pausePreferenceKey)
        statusText = "バックグラウンドのインデックス作成を再開しています · \(indexedCount.formatted()) 件を検索できます"
        startIndexing()
    }

    func refreshIndex() {
        guard configured, !sources.isEmpty else { return }
        guard refreshTask == nil else { return }
        let token = sourceGeneration
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if token == sourceGeneration { refreshTask = nil } }
            do {
                let store = try await storeTask.value
                guard token == sourceGeneration, !Task.isCancelled else { return }
                try await store.requestRescan()
                guard token == sourceGeneration, !Task.isCancelled else { return }
                await updateStatus(store)
                if !isPaused { startIndexing() }
            } catch {
                guard token == sourceGeneration, !Task.isCancelled else { return }
                reportStorageError(error)
            }
        }
    }

    private func isConfigurationCurrent(_ token: UUID) -> Bool {
        token == configurationGeneration && !Task.isCancelled
    }

    private func startIndexing() {
        guard configured, !isPaused, indexTask == nil, !sources.isEmpty else { return }
        let token = sourceGeneration
        let sourceSnapshots = sources
        let read = reader
        let worker = directoryWorker
        let appliedConfiguration = configurationTask
        indexTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if token == sourceGeneration { indexTask = nil; isIndexing = false }
            }
            await appliedConfiguration?.value
            guard token == sourceGeneration, !isPaused, !Task.isCancelled else { return }
            let scopes = await worker.beginAccess(sourceSnapshots.map { ($0.path, $0.bookmark) })
            defer { worker.endAccess(scopes) }
            do {
                let store = try await storeTask.value
                var lastProgress = Date.distantPast
                while token == sourceGeneration && !isPaused && !Task.isCancelled {
                    guard let work = try await store.nextDirectory() else {
                        guard let retryDate = try await store.nextRetryDate() else { break }
                        guard token == sourceGeneration, !isPaused, !Task.isCancelled else { return }
                        if !isIndexing { isIndexing = true }
                        await updateStatus(store)
                        // Other ready folders run first. If only retries remain,
                        // wait without blocking the UI or losing the durable queue.
                        let delay = max(0.01, min(10, retryDate.timeIntervalSinceNow))
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                    guard token == sourceGeneration, !Task.isCancelled else { return }
                    if !isIndexing { isIndexing = true }
                    let entries: [FolderEntry]?
                    do {
                        entries = try await read(URL(fileURLWithPath: work.path, isDirectory: true))
                    } catch is CancellationError {
                        return
                    } catch {
                        guard token == sourceGeneration, !Task.isCancelled else { return }
                        try await store.failDirectory(work, message: error.localizedDescription)
                        entries = nil
                    }
                    if let entries {
                        guard token == sourceGeneration, !isPaused, !Task.isCancelled else { return }
                        let items = entries.map { LocalIndexItem(path: $0.id, name: $0.name, isDirectory: $0.isDirectory, sourceID: work.sourceID) }
                        // Storage failures must surface as storage errors; only
                        // directory IO failures enter the NAS retry queue.
                        try await store.applyDirectory(work, items: items, childDirectories: entries.filter(\.isDirectory).map(\.id))
                    }
                    guard token == sourceGeneration, !Task.isCancelled else { return }
                    if Date().timeIntervalSince(lastProgress) >= 0.8 {
                        await updateStatus(store, refreshIndexedCounts: lastProgress == .distantPast)
                        refreshSearchDuringIndexing()
                        lastProgress = Date()
                    }
                    if directoryDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: directoryDelayNanoseconds) }
                    else { await Task.yield() }
                }
                guard token == sourceGeneration, !Task.isCancelled else { return }
                await updateStatus(store)
                scheduleSearch(reset: false)
            } catch is CancellationError {
                return
            } catch {
                guard token == sourceGeneration, !Task.isCancelled else { return }
                reportStorageError(error)
            }
        }
    }

    private func refreshSearchDuringIndexing() {
        guard !isSearching, Date().timeIntervalSince(lastSearchRefresh) >= 1.0 else { return }
        scheduleSearch(reset: false)
    }

    private func scheduleSearch(reset: Bool, start: Bool = true, append: Bool = false) {
        searchGeneration = UUID()
        let token = searchGeneration
        searchTask?.cancel(); searchTask = nil
        if reset { results = []; selectedID = nil; hasMore = false; resultCount = 0; nextSearchOffset = 0 }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard start, configured, !sources.isEmpty else { isSearching = false; return }
        let previousRows = append ? results : []
        let initialOffset = append ? nextSearchOffset : 0
        let limit = append ? results.count + pageSize : max(pageSize, results.count)
        let delay = debounceNanoseconds
        let batchSize = pageSize
        let openStore = storeTask
        let appliedConfiguration = configurationTask
        isSearching = true
        lastSearchRefresh = Date()
        searchTask = Task { [weak self] in
            do {
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                await appliedConfiguration?.value
                let store = try await openStore.value
                try Task.checkCancellation()
                // Load-more reads one bounded page. Query/index refreshes reread
                // the visible prefix so earlier-sorting changes still appear.
                var rows = previousRows
                var seenPaths = Set(previousRows.map(\.path))
                var rawOffset = initialOffset
                var more = false
                repeat {
                    let page = try await store.search(query: text, limit: min(batchSize, limit - rows.count), offset: rawOffset)
                    try Task.checkCancellation()
                    // A scan can insert earlier-sorting rows between pages.
                    // Advance by raw SQL rows, but publish each identity once.
                    // The final scan refresh then reads the settled ordering.
                    rawOffset += page.items.count
                    for hit in page.items where seenPaths.insert(hit.path).inserted {
                        rows.append(LocalSearchResult(entry: FolderEntry(indexedPath: hit.path, name: hit.name, isDirectory: hit.isDirectory),
                                                      sourceID: hit.sourceID, sourceName: hit.sourceName, notes: hit.notes, tags: hit.tags))
                    }
                    more = page.hasMore
                    if page.items.isEmpty { break }
                } while !append && rows.count < limit && more
                guard let self, token == searchGeneration else { return }
                if results != rows { results = rows }
                hasMore = more; resultCount = rows.count; nextSearchOffset = rawOffset; isSearching = false
                if let id = selectedID, !rows.contains(where: { $0.id == id }) { selectedID = nil }
            } catch is CancellationError {
                return
            } catch {
                guard let self, token == searchGeneration else { return }
                isSearching = false
                reportStorageError(error)
            }
        }
    }

    private func updateStatus(_ store: LocalSearchIndexStore, refreshIndexedCounts: Bool = false) async {
        do {
            let statuses = try await store.status(refreshIndexedCounts: refreshIndexedCounts)
            guard !Task.isCancelled else { return }
            let currentIDs = Set(sources.map(\.id))
            let current = statuses.filter { currentIDs.contains($0.sourceID) }
            indexedCount = current.reduce(0) { $0 + $1.indexedCount }
            processedDirectoryCount = current.reduce(0) { $0 + $1.processedDirectoryCount }
            pendingDirectoryCount = current.reduce(0) { $0 + $1.pendingDirectoryCount }
            errors = current.compactMap { status in status.error.map { "\(status.sourceName): \($0)" } }
            progress = !current.isEmpty && pendingDirectoryCount == 0 && errors.isEmpty
                && current.allSatisfy({ $0.lastCompletedAt != nil }) ? 1 : nil
            if sources.isEmpty { statusText = "検索する素材フォルダを追加してください" }
            else if isPaused { statusText = "インデックス作成を一時停止中 · \(indexedCount.formatted()) 件を検索できます" }
            else if pendingDirectoryCount > 0 { statusText = "バックグラウンドで検索対象を追加中 · \(indexedCount.formatted()) 件 · 待機中 \(pendingDirectoryCount.formatted()) フォルダ" }
            else if !errors.isEmpty { statusText = "インデックス作成は終了 · \(indexedCount.formatted()) 件を検索できます · 一部の場所を取得できませんでした" }
            else { statusText = "\(indexedCount.formatted()) 件を検索できます · 更新すると変更を再確認" }
        } catch { if !Task.isCancelled { reportStorageError(error) } }
    }

    private func reportStorageError(_ error: Error) {
        errors = ["検索インデックス: \(error.localizedDescription)"]
        isIndexing = false
        statusText = "検索インデックスを更新できません"
    }
}

private final class LocalLibraryDirectoryWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "jp.samplebrowser.library-index.directories", qos: .utility)

    func beginAccess(_ sources: [(String, Data?)]) async -> [URL] {
        await withCheckedContinuation { continuation in
            queue.async {
                var scopes: [URL] = []
                for (path, bookmark) in sources {
                    var url = URL(fileURLWithPath: path, isDirectory: true)
                    if let bookmark {
                        var stale = false
                        url = (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                        relativeTo: nil, bookmarkDataIsStale: &stale)) ?? url
                    }
                    if url.startAccessingSecurityScopedResource() { scopes.append(url) }
                }
                continuation.resume(returning: scopes)
            }
        }
    }

    func endAccess(_ scopes: [URL]) {
        queue.async { for url in scopes { url.stopAccessingSecurityScopedResource() } }
    }

    func readDirectory(_ url: URL) async throws -> [FolderEntry] {
        let cancellation = LocalLibraryReadCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .isHiddenKey]
                        let urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
                        var entries: [FolderEntry] = []
                        for child in urls {
                            try cancellation.check()
                            // A metadata failure must fail this directory rather
                            // than make a rescan prune previously indexed files.
                            let values = try child.resourceValues(forKeys: keys)
                            guard values.isHidden != true, values.isSymbolicLink != true, values.isAliasFile != true else { continue }
                            let directory = values.isDirectory == true
                            guard directory || (values.isRegularFile == true && FolderBrowserModel.supportedExtensions.contains(child.pathExtension.lowercased())) else { continue }
                            entries.append(FolderEntry(url: child, isDirectory: directory))
                        }
                        try cancellation.check()
                        continuation.resume(returning: entries)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
}

private final class LocalLibraryReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}
