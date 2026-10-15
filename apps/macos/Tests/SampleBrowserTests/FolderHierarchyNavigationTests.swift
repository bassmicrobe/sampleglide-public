import XCTest
@testable import SampleBrowser

@MainActor final class FolderHierarchyNavigationTests: XCTestCase {
    func testLeftSelectsParentDirectoryPrunesBranchAndStopsAudioAtSourceBoundary() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let model = FolderBrowserModel(store: fixture.store)
        model.addSource(fixture.samples); await model.waitForIdle()
        model.toggleFavorite(FolderEntry(url: fixture.kick, isDirectory: false))
        let favorites = model.favorites, sourceID = model.selectedSourceID
        let saved = try Data(contentsOf: fixture.store.fileURL)
        var playing = false, selections: [FolderEntry?] = []
        model.onSelectionChange = { selections.append($0); playing = false }
        model.onSelectAudio = { _ in playing = true }
        model.openEntryLocation(FolderEntry(url: fixture.kick, isDirectory: false)); await model.waitForIdle()
        XCTAssertTrue(playing)

        XCTAssertEqual(model.navigateToParent(fromColumn: 2), 1)
        XCTAssertEqual(model.columns.map(\.directoryURL), [fixture.samples, fixture.pack])
        XCTAssertEqual(model.selectedEntry?.url, fixture.drums)
        XCTAssertEqual(model.columns[1].selectedEntryID, fixture.drums.path)
        XCTAssertFalse(playing)
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.navigateToParent(fromColumn: 1), 0)
        XCTAssertEqual(model.columns.map(\.directoryURL), [fixture.samples])
        XCTAssertEqual(model.selectedEntry?.url, fixture.pack)
        let notifications = selections.count
        XCTAssertNil(model.navigateToParent(fromColumn: 0))
        XCTAssertNil(model.navigateToParent(fromColumn: -1))
        XCTAssertNil(model.navigateToParent(fromColumn: 9))
        XCTAssertEqual(selections.count, notifications, "Left at the source boundary is a no-op")
        XCTAssertEqual(model.selectedSourceID, sourceID)
        XCTAssertEqual(model.favorites, favorites)
        XCTAssertEqual(try Data(contentsOf: fixture.store.fileURL), saved)
    }

    func testRightReusesExistingColumnAndReopensClosedDirectoryButIgnoresFiles() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let reads = HierarchyReadCounter()
        let model = FolderBrowserModel(store: fixture.store, reader: { url in
            await reads.record(url)
            return try await FolderBrowserModel.readDirectory(url)
        })
        model.addSource(fixture.samples); await model.waitForIdle()
        XCTAssertNil(model.navigateIntoDirectory(fromColumn: 0), "A column without a selection must remain unchanged")
        let pack = try XCTUnwrap(model.columns[0].entries.first(where: { $0.url == fixture.pack }))
        model.select(pack, inColumn: 0); await model.waitForIdle()
        let child = model.columns[1]
        XCTAssertEqual(model.navigateIntoDirectory(fromColumn: 0), 1)
        XCTAssertEqual(model.columns[1], child)
        let firstReads = await reads.urls
        XCTAssertEqual(firstReads, [fixture.samples, fixture.pack])

        XCTAssertEqual(model.navigateToParent(fromColumn: 1), 0)
        XCTAssertEqual(model.navigateIntoDirectory(fromColumn: 0), 1)
        await model.waitForIdle()
        let reopenedReads = await reads.urls
        XCTAssertEqual(reopenedReads, [fixture.samples, fixture.pack, fixture.pack])
        XCTAssertEqual(model.columns[1].directoryURL, fixture.pack)
        let file = try XCTUnwrap(model.columns[0].entries.first(where: { $0.url == fixture.otherFile }))
        model.select(file, inColumn: 0)
        XCTAssertNil(model.navigateIntoDirectory(fromColumn: 0))
        XCTAssertNil(model.navigateIntoDirectory(fromColumn: -1))
        XCTAssertNil(model.navigateIntoDirectory(fromColumn: 8))
        XCTAssertEqual(model.selectedEntry, file)
        XCTAssertEqual(model.columns.count, 1)
    }

    func testRightReusesInFlightDirectoryReadWithoutCancelingIt() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let deferred = DeferredHierarchyRead()
        let model = FolderBrowserModel(store: fixture.store, reader: { url in
            if url == fixture.pack { await deferred.wait() }
            return try await FolderBrowserModel.readDirectory(url)
        })
        model.addSource(fixture.samples); await model.waitForIdle()
        let pack = try XCTUnwrap(model.columns[0].entries.first(where: { $0.url == fixture.pack }))
        model.select(pack, inColumn: 0)
        try await eventually { await deferred.pending }
        XCTAssertEqual(model.navigateIntoDirectory(fromColumn: 0), 1)
        XCTAssertTrue(model.columns[1].isLoading)
        await deferred.release()
        await model.waitForIdle()
        XCTAssertFalse(model.columns[1].isLoading)
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.columns[1].entries.map(\.url), [fixture.drums])
        XCTAssertNil(model.error)
    }

    func testLeftCancelsDelayedAncestorWalkWithoutRestoringChildOrPlayingOldFile() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let deferred = DeferredHierarchyRead()
        let model = FolderBrowserModel(store: fixture.store, reader: { url in
            if url == fixture.pack { await deferred.wait() }
            return try await FolderBrowserModel.readDirectory(url)
        })
        model.addSource(fixture.samples); await model.waitForIdle()
        var selectedAudio: [URL] = []
        model.onSelectAudio = { selectedAudio.append($0) }
        model.openEntryLocation(FolderEntry(url: fixture.kick, isDirectory: false))
        try await eventually { await deferred.pending }
        XCTAssertEqual(model.navigateToParent(fromColumn: 1), 0)
        await deferred.release()
        await model.waitForIdle()
        XCTAssertEqual(model.columns.map(\.directoryURL), [fixture.samples])
        XCTAssertEqual(model.selectedEntry?.url, fixture.pack)
        XCTAssertTrue(selectedAudio.isEmpty)
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.error)
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Directory navigation did not reach the delayed read")
        throw FolderBrowserError.unavailable("Timed out")
    }

    private func fixture() throws -> (base: URL, samples: URL, pack: URL, drums: URL, kick: URL, otherFile: URL, store: FolderBrowserStore) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("hierarchy-navigation-tests-\(UUID())", isDirectory: true)
        let samples = base.appendingPathComponent("Samples", isDirectory: true)
        let pack = samples.appendingPathComponent("Pack", isDirectory: true)
        let drums = pack.appendingPathComponent("Drums", isDirectory: true)
        try FileManager.default.createDirectory(at: drums, withIntermediateDirectories: true)
        let kick = drums.appendingPathComponent("Kick.wav"), otherFile = samples.appendingPathComponent("Other.wav")
        try Data("fixture".utf8).write(to: kick)
        try Data("fixture".utf8).write(to: otherFile)
        return (base, samples, pack, drums, kick, otherFile, FolderBrowserStore(fileURL: base.appendingPathComponent("preferences.json")))
    }
}

private actor HierarchyReadCounter {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}

private actor DeferredHierarchyRead {
    private var continuation: CheckedContinuation<Void, Never>?
    var pending: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
