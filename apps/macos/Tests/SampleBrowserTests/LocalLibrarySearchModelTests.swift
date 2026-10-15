import XCTest
@testable import SampleBrowser

@MainActor final class LocalLibrarySearchModelTests: XCTestCase {
    func testRecursivelyIndexesAllSourcesAndSearchesNamesPathsNotesAndTags() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.base.appendingPathComponent("First Library", isDirectory: true)
        let second = fixture.base.appendingPathComponent("Second Library", isDirectory: true)
        let deep = first.appendingPathComponent("Drums/Acoustic", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let kick = deep.appendingPathComponent("Kick.WAV")
        try Data("metadata-only fixture, not decoded".utf8).write(to: kick)
        try Data().write(to: second.appendingPathComponent("Kick.aiff"))
        try Data().write(to: deep.appendingPathComponent("ignore.mp3"))
        try Data().write(to: deep.appendingPathComponent(".hidden.wav"))
        try FileManager.default.createSymbolicLink(at: deep.appendingPathComponent("linked.wav"), withDestinationURL: kick)
        let sources = [fixture.source(first), fixture.source(second)]
        let annotation = LocalAnnotation(id: UUID(), savedPath: kick.path, isDirectory: false,
                                         sourceID: sources[0].id, relativePath: "Drums/Acoustic/Kick.WAV",
                                         notes: "深い低音", tags: ["Warm", "打楽器"])
        let model = fixture.model()
        defer { model.pause() }
        model.query = "kick"
        model.configure(sources: sources, annotations: [annotation])
        try await eventually { model.results.count == 2 && !model.isIndexing && !model.isSearching }
        XCTAssertEqual(model.indexedCount, 4)
        XCTAssertEqual(model.processedDirectoryCount, 4, "Both roots and the two nested directories were scanned")
        XCTAssertEqual(model.pendingDirectoryCount, 0)
        XCTAssertEqual(model.progress, 1)
        XCTAssertEqual(Set(model.results.map(\.sourceID)), Set(sources.map(\.id)))
        XCTAssertFalse(model.results.contains { $0.name == "linked.wav" })
        model.query = "Acoustic #warm"
        try await eventually { model.results.count == 1 && !model.isSearching }
        XCTAssertEqual(model.results[0].entry.url.path, kick.path)
        XCTAssertEqual(model.results[0].notes, "深い低音")
        model.query = "深い #打楽器"
        try await eventually { model.results.count == 1 && !model.isSearching }
        XCTAssertEqual(model.results[0].tags, ["Warm", "打楽器"])
    }

    func testPausedTraversalResumesAfterReopeningWithoutReadingCompletedDirectories() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.base.appendingPathComponent("Samples", isDirectory: true)
        let child = root.appendingPathComponent("Nested", isDirectory: true)
        let first = root.appendingPathComponent("First.wav")
        let nested = child.appendingPathComponent("Nested.wav")
        let source = fixture.source(root)
        let reader = ControlledDirectoryReader(entries: [
            root.path: [FolderEntry(url: child, isDirectory: true), FolderEntry(url: first, isDirectory: false)],
            child.path: [FolderEntry(url: nested, isDirectory: false)]
        ], blockedPath: child.path)
        let model = fixture.model(reader: { try await reader.read($0) })
        model.configure(sources: [source], annotations: [])
        try await eventuallyAsync { await reader.isBlocked }
        model.query = "First"
        try await eventually { model.results.map(\.name) == ["First.wav"] && !model.isSearching }
        XCTAssertEqual(model.processedDirectoryCount, 1)
        XCTAssertEqual(model.pendingDirectoryCount, 1, "The blocked directory remains pending until its listing is committed")
        XCTAssertNil(model.progress, "Discovered directories do not reveal the total size of an unfinished traversal")
        model.pause()
        XCTAssertNil(model.progress)
        XCTAssertEqual(model.processedDirectoryCount, 1)
        XCTAssertEqual(model.pendingDirectoryCount, 1)
        await reader.release()
        try await eventually { !model.isSearching && model.indexedCount == 2 }
        XCTAssertTrue(fixture.preferences.bool(forKey: LocalLibrarySearchModel.pausePreferenceKey))
        let restored = fixture.model(reader: { try await reader.read($0) })
        defer { restored.pause() }
        restored.configure(sources: [source], annotations: [])
        try await eventually { restored.indexedCount == 2 && !restored.isSearching }
        XCTAssertTrue(restored.isPaused)
        XCTAssertFalse(restored.isIndexing)
        XCTAssertEqual(restored.processedDirectoryCount, 1, "Completed directory progress must survive reopening")
        XCTAssertEqual(restored.pendingDirectoryCount, 1)
        XCTAssertNil(restored.progress)
        restored.resume()
        try await eventually { restored.indexedCount == 3 && !restored.isIndexing && !restored.isSearching }
        let rootReads = await reader.readCount(root.path)
        XCTAssertEqual(rootReads, 1, "Persisted traversal should not restart completed parents")
        let childReads = await reader.readCount(child.path)
        XCTAssertEqual(childReads, 2, "The cancelled directory remains queued")
        XCTAssertTrue(restored.results.contains { $0.path == nested.path })
        XCTAssertEqual(restored.processedDirectoryCount, 2)
        XCTAssertEqual(restored.pendingDirectoryCount, 0)
        XCTAssertEqual(restored.progress, 1)
    }

    func testReopeningCompletedLibraryDoesNotStartAnotherFullScan() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.base.appendingPathComponent("Completed", isDirectory: true)
        let sample = root.appendingPathComponent("Once.wav")
        let source = fixture.source(root)
        let reader = ControlledDirectoryReader(entries: [
            root.path: [FolderEntry(url: sample, isDirectory: false)]
        ])
        let first = fixture.model(reader: { try await reader.read($0) })
        first.configure(sources: [source], annotations: [])
        try await eventually { first.indexedCount == 1 && !first.isIndexing && !first.isSearching }
        let initialReads = await reader.readCount(root.path)
        XCTAssertEqual(initialReads, 1)

        let reopened = fixture.model(reader: { try await reader.read($0) })
        defer { reopened.pause() }
        reopened.configure(sources: [source], annotations: [])
        try await eventually { reopened.indexedCount == 1 && !reopened.isIndexing && !reopened.isSearching }
        try await Task.sleep(nanoseconds: 80_000_000)
        let readsAfterReopen = await reader.readCount(root.path)
        XCTAssertEqual(readsAfterReopen, 1, "Opening the app must not restart a completed full scan")
        XCTAssertEqual(reopened.processedDirectoryCount, 1)
        XCTAssertEqual(reopened.pendingDirectoryCount, 0)
        XCTAssertEqual(reopened.progress, 1)

        reopened.refreshIndex()
        try await eventuallyAsync { await reader.readCount(root.path) == 2 }
        try await eventually { !reopened.isIndexing && !reopened.isSearching }
        XCTAssertEqual(reopened.processedDirectoryCount, 1, "Only an explicit update starts the next generation")
    }

    func testRemovedSourceCannotReappearWhenItsSlowDirectoryReadCompletes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldRoot = fixture.base.appendingPathComponent("Old", isDirectory: true)
        let newRoot = fixture.base.appendingPathComponent("New", isDirectory: true)
        let old = fixture.source(oldRoot), new = fixture.source(newRoot)
        let reader = ControlledDirectoryReader(entries: [
            oldRoot.path: [FolderEntry(url: oldRoot.appendingPathComponent("Old.wav"), isDirectory: false)],
            newRoot.path: [FolderEntry(url: newRoot.appendingPathComponent("New.wav"), isDirectory: false)]
        ], blockedPath: oldRoot.path)
        let model = fixture.model(reader: { try await reader.read($0) })
        defer { model.pause() }
        model.configure(sources: [old], annotations: [])
        try await eventuallyAsync { await reader.isBlocked }
        model.configure(sources: [new], annotations: [])
        XCTAssertTrue(model.results.isEmpty)
        try await eventually { model.results.map(\.name) == ["New.wav"] && !model.isIndexing && !model.isSearching }
        await reader.release()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.results.map(\.sourceID), [new.id])
        XCTAssertEqual(model.indexedCount, 1)
        XCTAssertEqual(model.processedDirectoryCount, 1)
        XCTAssertEqual(model.pendingDirectoryCount, 0)
        XCTAssertEqual(model.progress, 1)
        model.configure(sources: [], annotations: [])
        XCTAssertTrue(model.results.isEmpty)
        try await eventually { model.indexedCount == 0 && model.processedDirectoryCount == 0 && model.pendingDirectoryCount == 0 && model.progress == nil }
        XCTAssertFalse(model.isIndexing)
        XCTAssertFalse(model.isSearching)
        XCTAssertNil(model.progress, "An empty library must not look like a completed scan")
    }

    func testOfflineRescanPreservesSearchablePreviousResultsAndReportsError() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.base.appendingPathComponent("Offline", isDirectory: true)
        let source = fixture.source(root)
        let reader = ControlledDirectoryReader(entries: [root.path: [FolderEntry(url: root.appendingPathComponent("Retained.wav"), isDirectory: false)]])
        let model = fixture.model(reader: { try await reader.read($0) })
        defer { model.pause() }
        model.query = "retained"
        model.configure(sources: [source], annotations: [])
        try await eventually { model.results.count == 1 && !model.isIndexing && !model.isSearching }
        XCTAssertEqual(model.progress, 1)
        XCTAssertEqual(model.processedDirectoryCount, 1)
        XCTAssertEqual(model.pendingDirectoryCount, 0)
        await reader.setOffline(true)
        model.refreshIndex()
        try await eventually { !model.errors.isEmpty && !model.isIndexing && !model.isSearching }
        XCTAssertEqual(model.results.map(\.name), ["Retained.wav"])
        XCTAssertEqual(model.indexedCount, 1)
        XCTAssertEqual(model.processedDirectoryCount, 1, "The failed attempt consumes a checkpoint but does not complete the scan successfully")
        XCTAssertEqual(model.pendingDirectoryCount, 0)
        XCTAssertNil(model.progress, "An offline rescan must not report 100% merely because its pending queue is empty")
        XCTAssertTrue(model.statusText.hasPrefix("インデックス作成は終了"))
        let offlineReads = await reader.readCount(root.path)
        XCTAssertEqual(offlineReads, 4, "A failed scan makes at most three attempts, then stops")
        await reader.setOffline(false)
        model.refreshIndex()
        try await eventually { model.errors.isEmpty && !model.isIndexing && !model.isSearching }
        XCTAssertEqual(model.progress, 1)
        XCTAssertEqual(model.processedDirectoryCount, 1, "A fresh scan reports its own progress, rather than accumulating earlier attempts")
        XCTAssertEqual(model.pendingDirectoryCount, 0)
    }

    func testAnnotationUpdatesAndPagingRetainSelectionWithoutRestartingTraversal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.base.appendingPathComponent("Paged", isDirectory: true)
        let source = fixture.source(root)
        let entries = (0..<501).map { FolderEntry(url: root.appendingPathComponent("Sample \($0).wav"), isDirectory: false) }
        let reader = ControlledDirectoryReader(entries: [root.path: entries])
        let model = fixture.model(reader: { try await reader.read($0) }, pageSize: 200)
        defer { model.pause() }
        model.query = "sample"
        model.configure(sources: [source], annotations: [])
        try await eventually { model.results.count == 200 && !model.isIndexing && !model.isSearching }
        XCTAssertTrue(model.hasMore)
        model.selectedID = model.results[0].id
        let selected = model.selectedID
        model.loadMore()
        try await eventually { model.results.count == 400 && !model.isSearching }
        XCTAssertEqual(model.selectedID, selected)
        model.loadMore()
        try await eventually { model.results.count == 501 && !model.isSearching }
        XCTAssertFalse(model.hasMore)
        let annotation = LocalAnnotation(id: UUID(), savedPath: entries[0].id, isDirectory: false,
                                         sourceID: source.id, relativePath: entries[0].name, notes: "Updated memo", tags: ["updated"])
        model.configure(sources: [source], annotations: [annotation])
        try await eventually { model.results.first(where: { $0.id == entries[0].id })?.notes == "Updated memo" && !model.isSearching }
        XCTAssertEqual(model.selectedID, selected)
        XCTAssertEqual(model.results.count, 501)
        let annotationReads = await reader.readCount(root.path)
        XCTAssertEqual(annotationReads, 1)
        model.query = "#updated"
        try await eventually { model.results.count == 1 && !model.isSearching }
        XCTAssertEqual(model.results[0].id, entries[0].id)
    }

    func testLoadMoreAppendsOnePageAndRefreshReconcilesEarlierInsertions() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.base.appendingPathComponent("Append", isDirectory: true)
        let source = fixture.source(root)
        let entries = (1_000..<1_600).map { FolderEntry(url: root.appendingPathComponent("Sample \($0).wav"), isDirectory: false) }
        let reader = ControlledDirectoryReader(entries: [root.path: entries])
        let model = fixture.model(reader: { try await reader.read($0) })
        defer { model.pause() }
        model.query = "sample"
        model.configure(sources: [source], annotations: [])
        try await eventually { model.results.count == 200 && !model.isIndexing && !model.isSearching }
        let originalPrefix = model.results.map(\.id)
        model.selectedID = originalPrefix[0]

        // Another indexing connection inserts a row before the current page.
        // Appending must retain the visible prefix and suppress the shifted
        // duplicate, rather than repeatedly reloading every previous page.
        let store = try LocalSearchIndexStore(databaseURL: fixture.base.appendingPathComponent("index.sqlite3"))
        try await store.requestRescan()
        let pendingWork = try await store.nextDirectory()
        let work = try XCTUnwrap(pendingWork)
        let earlyPath = root.appendingPathComponent("Sample 0000.wav").path
        let indexedItems = entries.map { LocalIndexItem(path: $0.id, name: $0.name, isDirectory: false, sourceID: source.id) }
            + [LocalIndexItem(path: earlyPath, name: "Sample 0000.wav", isDirectory: false, sourceID: source.id)]
        try await store.applyDirectory(work, items: indexedItems, childDirectories: [])
        model.loadMore()
        try await eventually { model.results.count == 399 && !model.isSearching }
        XCTAssertEqual(Array(model.results.prefix(200).map(\.id)), originalPrefix)
        XCTAssertEqual(Set(model.results.map(\.id)).count, 399)
        XCTAssertEqual(model.selectedID, originalPrefix[0])
        XCTAssertTrue(model.hasMore)

        let annotation = LocalAnnotation(id: UUID(), savedPath: entries[0].id, isDirectory: false,
                                         sourceID: source.id, relativePath: entries[0].name, notes: "Refresh", tags: [])
        model.configure(sources: [source], annotations: [annotation])
        try await eventually { model.results.first?.id == earlyPath && !model.isSearching }
        XCTAssertEqual(model.results.count, 399)
        XCTAssertEqual(model.selectedID, originalPrefix[0])
        model.loadMore()
        try await eventually { model.results.count == 599 && !model.isSearching }
        XCTAssertEqual(Set(model.results.map(\.id)).count, 599)
        model.loadMore()
        try await eventually { model.results.count == 601 && !model.isSearching }
        XCTAssertFalse(model.hasMore)
    }

    func testAnnotationChangeDuringInitialConfigurationStillAppliesSources() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.base.appendingPathComponent("Configure", isDirectory: true)
        let source = fixture.source(root)
        let entry = FolderEntry(url: root.appendingPathComponent("Sample.wav"), isDirectory: false)
        let model = fixture.model(reader: { _ in [entry] })
        defer { model.pause() }
        model.configure(sources: [source], annotations: [])
        let annotation = LocalAnnotation(id: UUID(), savedPath: entry.id, isDirectory: false,
                                         sourceID: source.id, relativePath: entry.name, notes: "Configured", tags: [])
        model.configure(sources: [source], annotations: [annotation])
        try await eventually { model.results.first?.notes == "Configured" && !model.isIndexing && !model.isSearching }
        XCTAssertEqual(model.indexedCount, 1)
        XCTAssertEqual(model.progress, 1)
    }

    func testChangingQueryCancelsPendingLoadMoreWithoutPublishingOldRows() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.base.appendingPathComponent("Cancel", isDirectory: true)
        let source = fixture.source(root)
        let entries = (0..<600).map { FolderEntry(url: root.appendingPathComponent("Sample \($0).wav"), isDirectory: false) }
        let unique = FolderEntry(url: root.appendingPathComponent("Unique.wav"), isDirectory: false)
        let model = LocalLibrarySearchModel(databaseURL: fixture.base.appendingPathComponent("index.sqlite3"),
                                           directoryReader: { _ in entries + [unique] }, preferences: fixture.preferences,
                                           debounceNanoseconds: 50_000_000, directoryDelayNanoseconds: 0)
        defer { model.pause() }
        model.query = "sample"
        model.configure(sources: [source], annotations: [])
        try await eventually { model.results.count == 200 && !model.isIndexing && !model.isSearching }
        model.selectedID = model.results[0].id
        model.loadMore()
        model.query = "unique"
        try await eventually { model.results.map(\.id) == [unique.id] && !model.isSearching }
        XCTAssertNil(model.selectedID)
        XCTAssertFalse(model.hasMore)
    }

    func testTransientFailureRecoversWithoutRestartingCompletedParents() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.base.appendingPathComponent("Transient", isDirectory: true)
        let child = root.appendingPathComponent("Retry", isDirectory: true)
        let other = root.appendingPathComponent("Healthy", isDirectory: true)
        let reader = ControlledDirectoryReader(entries: [
            root.path: [FolderEntry(url: child, isDirectory: true), FolderEntry(url: other, isDirectory: true)],
            child.path: [FolderEntry(url: child.appendingPathComponent("Recovered.wav"), isDirectory: false)],
            other.path: [FolderEntry(url: other.appendingPathComponent("Healthy.wav"), isDirectory: false)]
        ])
        await reader.failNextReads(child.path, count: 1)
        let model = fixture.model(reader: { try await reader.read($0) }, retryDelays: [0.2, 0.3])
        defer { model.pause() }
        model.configure(sources: [fixture.source(root)], annotations: [])
        try await eventually { !model.errors.isEmpty && model.pendingDirectoryCount == 1 }
        XCTAssertTrue(model.errors[0].contains(child.path), "The failed location must be identifiable")
        XCTAssertTrue(model.isIndexing)
        XCTAssertNil(model.progress)
        try await eventually { model.indexedCount == 4 && !model.isIndexing && !model.isSearching }
        let rootReads = await reader.readCount(root.path)
        let childReads = await reader.readCount(child.path)
        let healthyReads = await reader.readCount(other.path)
        XCTAssertEqual(rootReads, 1)
        XCTAssertEqual(childReads, 2)
        XCTAssertEqual(healthyReads, 1)
        XCTAssertEqual(model.processedDirectoryCount, 3, "Retries do not count as extra folders")
        XCTAssertEqual(model.pendingDirectoryCount, 0)
        XCTAssertTrue(model.errors.isEmpty)
        XCTAssertEqual(model.progress, 1)
    }

    func testPauseDuringRetryWaitPreservesCheckpointAcrossReopen() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.base.appendingPathComponent("Retry after reopen", isDirectory: true)
        let source = fixture.source(root)
        let reader = ControlledDirectoryReader(entries: [
            root.path: [FolderEntry(url: root.appendingPathComponent("Recovered.wav"), isDirectory: false)]
        ])
        await reader.failNextReads(root.path, count: 1)
        let model = fixture.model(reader: { try await reader.read($0) }, retryDelays: [1, 1])
        model.configure(sources: [source], annotations: [])
        try await eventually { !model.errors.isEmpty && model.pendingDirectoryCount == 1 }
        model.pause()
        try await Task.sleep(nanoseconds: 60_000_000)
        let pausedReads = await reader.readCount(root.path)
        XCTAssertEqual(pausedReads, 1, "Pause cancels the retry wait")
        XCTAssertEqual(model.processedDirectoryCount, 0)
        let restored = fixture.model(reader: { try await reader.read($0) })
        defer { restored.pause() }
        restored.configure(sources: [source], annotations: [])
        try await eventually { restored.pendingDirectoryCount == 1 && !restored.isSearching }
        XCTAssertTrue(restored.isPaused)
        restored.resume()
        try await eventually { restored.isIndexing && restored.pendingDirectoryCount == 1 }
        XCTAssertNil(restored.progress, "A resumed backoff is still an active unfinished scan")
        try await eventually { restored.indexedCount == 1 && !restored.isIndexing && !restored.isSearching }
        let resumedReads = await reader.readCount(root.path)
        XCTAssertEqual(resumedReads, 2)
        XCTAssertEqual(restored.processedDirectoryCount, 1)
        XCTAssertTrue(restored.errors.isEmpty)
        XCTAssertEqual(restored.progress, 1)
    }

    private func eventually(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail("Timed out waiting for model state"); throw WaitError.timeout }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func eventuallyAsync(timeout: TimeInterval = 5, _ condition: @Sendable () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() >= deadline { XCTFail("Timed out waiting for directory reader"); throw WaitError.timeout }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private enum WaitError: Error { case timeout }

    private struct Fixture {
        let base: URL
        let preferences: UserDefaults
        let preferencesName: String
        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("SampleGlide-index-model-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            preferencesName = "SampleGlide-index-model-\(UUID())"
            preferences = UserDefaults(suiteName: preferencesName)!
        }
        func source(_ url: URL) -> FolderSource { FolderSource(id: UUID(), name: url.lastPathComponent, savedPath: url.path, bookmark: nil) }
        @MainActor func model(reader: (@Sendable (URL) async throws -> [FolderEntry])? = nil, pageSize: Int = 200,
                              retryDelays: [TimeInterval] = [0.01, 0.02]) -> LocalLibrarySearchModel {
            LocalLibrarySearchModel(databaseURL: base.appendingPathComponent("index.sqlite3"), directoryReader: reader,
                                    preferences: preferences, pageSize: pageSize, debounceNanoseconds: 1_000_000,
                                    directoryDelayNanoseconds: 0, directoryRetryDelays: retryDelays)
        }
        func remove() {
            preferences.removePersistentDomain(forName: preferencesName)
            try? FileManager.default.removeItem(at: base)
        }
    }

}

private actor ControlledDirectoryReader {
    let entries: [String: [FolderEntry]]
    let blockedPath: String?
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var offline = false
    private var counts: [String: Int] = [:]
    private var failuresRemaining: [String: Int] = [:]
    private(set) var isBlocked = false
    init(entries: [String: [FolderEntry]], blockedPath: String? = nil) {
        self.entries = entries; self.blockedPath = blockedPath
    }
    func read(_ url: URL) async throws -> [FolderEntry] {
        counts[url.path, default: 0] += 1
        if url.path == blockedPath && !released {
            isBlocked = true
            await withCheckedContinuation { continuation = $0 }
        }
        if offline { throw CocoaError(.fileReadNoSuchFile) }
        if failuresRemaining[url.path, default: 0] > 0 {
            failuresRemaining[url.path, default: 0] -= 1
            throw CocoaError(.fileReadUnknown)
        }
        return entries[url.path] ?? []
    }
    func readCount(_ path: String) -> Int { counts[path, default: 0] }
    func release() { released = true; continuation?.resume(); continuation = nil }
    func setOffline(_ value: Bool) { offline = value }
    func failNextReads(_ path: String, count: Int) { failuresRemaining[path] = count }
}
