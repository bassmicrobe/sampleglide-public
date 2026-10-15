import Combine
import XCTest
@testable import SampleBrowser

@MainActor final class FolderBrowserTests: XCTestCase {
    func testCachedEntryAndColumnIdentitiesPreserveStandardizedUnicodePaths() {
        let directoryURL = URL(fileURLWithPath: "/tmp/SampleGlide Identity/Pack/../音素材 100%", isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("Kick #1.wav", isDirectory: false)
        let directory = FolderEntry(url: directoryURL, isDirectory: true)
        let file = FolderEntry(url: fileURL, isDirectory: false)
        XCTAssertEqual(directory.id, directoryURL.standardizedFileURL.path)
        XCTAssertEqual(file.id, fileURL.standardizedFileURL.path)
        XCTAssertEqual(FolderColumn(directoryURL: directoryURL).id, directory.id)
        XCTAssertEqual(FolderColumn(directory: directory).id, directory.id)
        XCTAssertEqual(FolderEntry(url: file.url, isDirectory: false), file)
        XCTAssertEqual(Set([file, FolderEntry(url: file.url, isDirectory: false)]).count, 1)
    }

    func testDirectorySelectionPublishesOnlyCoherentSelectedBranch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let model = FolderBrowserModel(store: fixture.store)
        model.addSource(fixture.samples); await model.waitForIdle()
        let first = try XCTUnwrap(model.columns[0].entries.first(where: { $0.name == "Pack 2" }))
        model.select(first, inColumn: 0); await model.waitForIdle()
        let sibling = try XCTUnwrap(model.columns[0].entries.first(where: { $0.name == "Pack 10" }))
        var published: [[FolderColumn]] = []
        let observation = model.$columns.dropFirst().sink { published.append($0) }
        model.select(sibling, inColumn: 0)
        await model.waitForIdle()
        observation.cancel()
        XCTAssertFalse(published.isEmpty)
        for columns in published {
            XCTAssertEqual(columns.count, 2, "Observers should not see the branch disappear between selection and reveal")
            XCTAssertEqual(columns.first?.selectedEntryID, sibling.id)
            XCTAssertEqual(columns.last?.id, sibling.id)
        }
    }

    func testColumnsReadOnlySelectedHierarchyAndFilterAudio() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let model = FolderBrowserModel(store: fixture.store)
        var selectedAudio: URL?
        model.onSelectAudio = { selectedAudio = $0 }
        model.addSource(fixture.samples)
        await model.waitForIdle()
        XCTAssertEqual(model.columns.count, 1)
        XCTAssertEqual(model.columns[0].entries.map(\.name), ["Pack 2", "Pack 10", "Bass.WAV", "Texture.FLAC"])
        let pack = try XCTUnwrap(model.columns[0].entries.first)
        model.select(pack, inColumn: 0)
        await model.waitForIdle()
        XCTAssertEqual(model.columns.count, 2)
        XCTAssertEqual(model.columns[1].entries.map(\.name), ["Drums", "Pad.aiff"])
        let drums = try XCTUnwrap(model.columns[1].entries.first)
        model.select(drums, inColumn: 1)
        await model.waitForIdle()
        XCTAssertEqual(model.columns.count, 3)
        let kick = try XCTUnwrap(model.columns[2].entries.first)
        model.select(kick, inColumn: 2)
        XCTAssertEqual(selectedAudio, kick.url)
        XCTAssertEqual(model.selectedEntry, kick)
        XCTAssertFalse(model.loading)
        // A sibling choice must discard all deeper columns.
        let sibling = try XCTUnwrap(model.columns[0].entries.first(where: { $0.name == "Pack 10" }))
        model.select(sibling, inColumn: 0)
        await model.waitForIdle()
        XCTAssertEqual(model.columns.count, 2)
        XCTAssertEqual(model.columns[1].directoryURL, sibling.url)
        XCTAssertTrue(model.columns[1].entries.isEmpty)
    }

    func testFileAndFolderFavoriteAliasesPersistWithoutRenamingSources() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let model = FolderBrowserModel(store: fixture.store)
        model.addSource(fixture.samples)
        await model.waitForIdle()
        let folder = try XCTUnwrap(model.columns[0].entries.first)
        let file = try XCTUnwrap(model.columns[0].entries.first(where: { !$0.isDirectory }))
        model.toggleFavorite(folder); model.toggleFavorite(file)
        XCTAssertEqual(model.favorites.count, 2)
        XCTAssertTrue(model.isFavorite(folder))
        XCTAssertTrue(model.isFavorite(file))
        let aliasID = try XCTUnwrap(model.favorites.first(where: { $0.url == file.url })?.id)
        model.renameFavorite(aliasID, name: "お気に入りのベース")
        XCTAssertNil(model.error)
        XCTAssertEqual(model.favorites.first(where: { $0.id == aliasID })?.name, "お気に入りのベース")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.deletingLastPathComponent().appendingPathComponent("お気に入りのベース").path))
        XCTAssertEqual(try Data(contentsOf: file.url), Data("fixture".utf8))
        let restored = FolderBrowserModel(store: fixture.store)
        XCTAssertEqual(restored.sources, model.sources)
        XCTAssertEqual(restored.favorites, model.favorites)
        XCTAssertTrue(restored.isFavorite(folder))
        XCTAssertTrue(restored.isFavorite(file))
        model.renameFavorite(aliasID, name: " \n ")
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.favorites.first(where: { $0.id == aliasID })?.name, "お気に入りのベース")
        model.toggleFavorite(file)
        XCTAssertFalse(model.isFavorite(file))
        XCTAssertTrue(model.isFavorite(folder))
        XCTAssertFalse(model.isFavorite(file.url))
        XCTAssertTrue(model.isFavorite(folder.url))
    }

    func testOpenNestedFavoriteRestoresAncestorsAndSelectsAudio() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let model = FolderBrowserModel(store: fixture.store)
        model.addSource(fixture.samples); await model.waitForIdle()
        let file = FolderEntry(url: fixture.samples.appendingPathComponent("Pack 2/Drums/Kick.wav"), isDirectory: false)
        let folder = FolderEntry(url: fixture.samples.appendingPathComponent("Pack 2/Drums"), isDirectory: true)
        model.toggleFavorite(file); model.toggleFavorite(folder)
        let fileID = try XCTUnwrap(model.favorites.first(where: { !$0.isDirectory })?.id)
        let folderID = try XCTUnwrap(model.favorites.first(where: { $0.isDirectory })?.id)
        var previews: [URL] = []
        model.onSelectAudio = { previews.append($0) }
        model.openFavorite(fileID); await model.waitForIdle()
        XCTAssertEqual(model.columns.map(\.title), ["Samples", "Pack 2", "Drums"])
        XCTAssertEqual(model.selectedEntry, file)
        XCTAssertEqual(previews, [file.url])
        model.openFavorite(folderID); await model.waitForIdle()
        XCTAssertEqual(model.columns.map(\.title), ["Samples", "Pack 2", "Drums"])
        XCTAssertEqual(model.selectedEntry, folder)
        XCTAssertEqual(previews.count, 1)
        model.removeSource(try XCTUnwrap(model.sources.first?.id))
        XCTAssertTrue(model.sources.isEmpty)
        XCTAssertEqual(model.favorites.count, 2)
        XCTAssertTrue(model.isFavorite(file), "Detaching a source must retain the favorite's cached identity")
        XCTAssertTrue(model.isFavorite(folder))
        model.openFavorite(fileID); await model.waitForIdle()
        XCTAssertEqual(model.selectedEntry, file)
        XCTAssertEqual(previews.count, 2)
    }

    func testRefreshReadsOnlyDisplayedFolderAndPreservesSelectedAudioForFavoriteAndOrdinaryFiles() async throws {
        for favorite in [false, true] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.base) }
            let reads = FolderRefreshReadRecorder()
            let model = FolderBrowserModel(store: fixture.store, reader: { url in
                await reads.record(url)
                return try await FolderBrowserModel.readDirectory(url)
            })
            model.addSource(fixture.samples); await model.waitForIdle()
            let target = FolderEntry(url: fixture.samples.appendingPathComponent("Pack 2/Drums/Kick.wav"), isDirectory: false)
            model.openEntryLocation(target); await model.waitForIdle()
            if favorite { model.toggleFavorite(target) }
            let beforeColumns = model.columns
            let beforeReads = await reads.urls.count
            var selections: [FolderEntry?] = [], previews: [URL] = []
            model.onSelectionChange = { selections.append($0) }
            model.onSelectAudio = { previews.append($0) }

            model.refresh(); await model.waitForIdle()

            let afterReads = await reads.urls
            XCTAssertEqual(Array(afterReads.dropFirst(beforeReads)), [target.url.deletingLastPathComponent()])
            XCTAssertEqual(model.columns, beforeColumns)
            XCTAssertEqual(model.selectedEntry, target)
            XCTAssertTrue(selections.isEmpty, "A folder refresh must not clear an existing preview")
            XCTAssertTrue(previews.isEmpty, "Favorite membership must not restart the audio")
        }
    }

    func testRefreshClearsSelectionOnlyAfterSelectedFileDisappears() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let model = FolderBrowserModel(store: fixture.store)
        model.addSource(fixture.samples); await model.waitForIdle()
        let target = try XCTUnwrap(model.columns[0].entries.first(where: { $0.name == "Bass.WAV" }))
        model.select(target, inColumn: 0)
        var selections: [FolderEntry?] = [], previews: [URL] = []
        model.onSelectionChange = { selections.append($0) }
        model.onSelectAudio = { previews.append($0) }
        try FileManager.default.removeItem(at: target.url)

        model.refresh(); await model.waitForIdle()

        XCTAssertNil(model.selectedEntry)
        XCTAssertNil(model.columns[0].selectedEntryID)
        XCTAssertEqual(selections, [nil])
        XCTAssertTrue(previews.isEmpty)
        XCTAssertNil(model.error)
    }

    func testRefreshPreservesParentDirectorySelectionWhileReloadingItsChild() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let model = FolderBrowserModel(store: fixture.store)
        model.addSource(fixture.samples); await model.waitForIdle()
        let directory = try XCTUnwrap(model.columns[0].entries.first(where: { $0.name == "Pack 2" }))
        model.select(directory, inColumn: 0); await model.waitForIdle()
        model.toggleFavorite(directory)
        let before = model.columns
        var selections: [FolderEntry?] = []
        model.onSelectionChange = { selections.append($0) }

        model.refresh(); await model.waitForIdle()

        XCTAssertEqual(model.columns, before)
        XCTAssertEqual(model.selectedEntry, directory)
        XCTAssertTrue(selections.isEmpty)
    }

    func testFavoriteArrowSelectionUsesAutomaticCallbackAndDirectorySelectionDoesNotNavigate() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let model = FolderBrowserModel(store: fixture.store)
        model.addSource(fixture.samples); await model.waitForIdle()
        let file = try XCTUnwrap(model.columns[0].entries.first(where: { !$0.isDirectory }))
        let directory = try XCTUnwrap(model.columns[0].entries.first(where: \.isDirectory))
        model.toggleFavorite(file); model.toggleFavorite(directory)
        let fileID = try XCTUnwrap(model.favorites.first(where: { !$0.isDirectory })?.id)
        let directoryID = try XCTUnwrap(model.favorites.first(where: \.isDirectory)?.id)
        let columns = model.columns
        var automatic: [URL] = [], explicit: [URL] = []
        model.onSelectFavoriteAudio = { automatic.append($0) }
        model.onPreviewFavoriteAudio = { explicit.append($0) }

        model.previewFavorite(fileID, explicitPlayback: false); await model.waitForIdle()
        XCTAssertEqual(automatic, [file.url])
        XCTAssertTrue(explicit.isEmpty)
        XCTAssertEqual(model.columns, columns)
        model.selectFavoriteDirectory(directoryID)
        XCTAssertEqual(model.selectedFavoriteID, directoryID)
        XCTAssertEqual(model.columns, columns)
        model.previewFavorite(fileID); await model.waitForIdle()
        XCTAssertEqual(explicit, [file.url])
        XCTAssertEqual(automatic, [file.url])
    }

    func testSlowStaleDirectoryCannotReplaceNewerBranch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let model = FolderBrowserModel(store: fixture.store, reader: { url in
            let entries = try await FolderBrowserModel.readDirectory(url)
            if url.lastPathComponent == "Pack 2" {
                // Emulate an already-issued network response which ignores cancellation.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { continuation.resume() }
                }
            }
            return entries
        })
        model.addSource(fixture.samples); await model.waitForIdle()
        let slow = try XCTUnwrap(model.columns[0].entries.first(where: { $0.name == "Pack 2" }))
        let fast = try XCTUnwrap(model.columns[0].entries.first(where: { $0.name == "Pack 10" }))
        model.select(slow, inColumn: 0)
        try await Task.sleep(for: .milliseconds(30))
        model.select(fast, inColumn: 0)
        await model.waitForIdle()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.columns.count, 2)
        XCTAssertEqual(model.columns[1].directoryURL, fast.url)
        XCTAssertTrue(model.columns[1].entries.isEmpty)
        XCTAssertEqual(model.selectedEntry, fast)
        XCTAssertFalse(model.loading)
    }

    func testMissingSourceHasRetryableOfflineColumnAndKeepsFavorites() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let model = FolderBrowserModel(store: fixture.store)
        model.addSource(fixture.samples); await model.waitForIdle()
        let folder = try XCTUnwrap(model.columns[0].entries.first)
        model.toggleFavorite(folder)
        try FileManager.default.removeItem(at: fixture.samples)
        model.openSource(try XCTUnwrap(model.sources.first?.id)); await model.waitForIdle()
        XCTAssertEqual(model.columns.count, 1)
        XCTAssertNotNil(model.columns[0].error)
        XCTAssertFalse(model.columns[0].isLoading)
        XCTAssertEqual(model.favorites.count, 1)
        try FileManager.default.createDirectory(at: fixture.samples, withIntermediateDirectories: true)
        model.retryColumn(0); await model.waitForIdle()
        XCTAssertNil(model.columns[0].error)
        XCTAssertTrue(model.columns[0].entries.isEmpty)
    }

    func testStoreRejectsTraversalCorruptionAndSiblingPrefixIsNotDescendant() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let favorite = FolderFavorite(id: UUID(), name: "invalid", savedPath: fixture.samples.path, isDirectory: true, sourceID: nil, relativePath: "../Other", bookmark: nil)
        XCTAssertThrowsError(try fixture.store.save(FolderBrowserState(favorites: [favorite])))
        let sibling = fixture.samples.deletingLastPathComponent().appendingPathComponent("Samples Other/Kick.wav")
        XCTAssertNil(FolderBrowserModel.relativePath(of: sibling, within: fixture.samples))
        XCTAssertEqual(FolderBrowserModel.relativePath(of: fixture.samples.appendingPathComponent("Pack 2/Kick.wav"), within: fixture.samples), "Pack 2/Kick.wav")
        try Data("not JSON".utf8).write(to: fixture.store.fileURL)
        XCTAssertThrowsError(try fixture.store.load())
    }

    func testFavoriteFilePreviewKeepsColumnsAndFolderSelectionWithoutListingDirectories() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let reads = FavoriteDirectoryReadCounter()
        let model = FolderBrowserModel(store: fixture.store, reader: { url in
            await reads.increment()
            return try await FolderBrowserModel.readDirectory(url)
        })
        model.addSource(fixture.samples); await model.waitForIdle()
        let selected = try XCTUnwrap(model.columns[0].entries.first(where: { $0.name == "Bass.WAV" }))
        model.select(selected, inColumn: 0)
        let favorite = FolderEntry(url: fixture.samples.appendingPathComponent("Pack 2/Drums/Kick.wav"), isDirectory: false)
        model.toggleFavorite(favorite)
        let id = try XCTUnwrap(model.favorites.first?.id)
        let columns = model.columns, sourceID = model.selectedSourceID
        var previews: [URL] = [], normalSelections: [URL] = [], clearedAudio = false
        model.onPreviewFavoriteAudio = { previews.append($0) }
        model.onSelectAudio = { normalSelections.append($0) }
        model.onSelectionChange = { if $0 == nil { clearedAudio = true } }
        model.previewFavorite(id); await model.waitForIdle()
        XCTAssertEqual(previews, [favorite.url])
        XCTAssertTrue(normalSelections.isEmpty, "Favorite audition is distinct from folder auto-preview")
        XCTAssertTrue(clearedAudio)
        XCTAssertEqual(model.selectedFavoriteID, id)
        XCTAssertEqual(model.columns, columns)
        XCTAssertEqual(model.selectedSourceID, sourceID)
        XCTAssertEqual(model.selectedEntry, selected)
        let count = await reads.value
        XCTAssertEqual(count, 1, "Audition must not list the favorite's ancestors")
    }

    func testFavoritePreviewResolvesRemountedSourceRelativePathOffMainWithoutOpeningColumns() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let oldRoot = fixture.base.appendingPathComponent("DisconnectedMount", isDirectory: true)
        let source = FolderSource(id: UUID(), name: "NAS", savedPath: oldRoot.path, bookmark: Data("fixture bookmark".utf8))
        let favorite = FolderFavorite(id: UUID(), name: "Kick", savedPath: oldRoot.appendingPathComponent("Pack 2/Drums/Kick.wav").path, isDirectory: false, sourceID: source.id, relativePath: "Pack 2/Drums/Kick.wav", bookmark: nil)
        try fixture.store.save(FolderBrowserState(sources: [source], favorites: [favorite]))
        let resolvedCalls = FavoriteResolverRecorder()
        let model = FolderBrowserModel(store: fixture.store,
            reader: { _ in throw FolderBrowserError.invalidURL },
            favoriteResolver: { url, bookmark in
                await resolvedCalls.record(url: url, bookmark: bookmark, onMainThread: favoriteResolutionIsOnMainThread())
                return fixture.samples
            })
        let oldEntry = FolderEntry(url: favorite.url, isDirectory: false)
        XCTAssertTrue(model.isFavorite(oldEntry))
        var previews: [URL] = []
        model.onPreviewFavoriteAudio = { previews.append($0) }
        model.previewFavorite(favorite.id); await model.waitForIdle()
        let target = fixture.samples.appendingPathComponent("Pack 2/Drums/Kick.wav")
        XCTAssertEqual(previews, [target])
        XCTAssertTrue(model.columns.isEmpty)
        XCTAssertNil(model.selectedSourceID)
        XCTAssertNil(model.selectedEntry)
        XCTAssertEqual(model.sources.first?.url, fixture.samples)
        XCTAssertEqual(model.favorites.first?.url, target)
        XCTAssertFalse(model.isFavorite(oldEntry))
        XCTAssertTrue(model.isFavorite(FolderEntry(url: target, isDirectory: false)))
        XCTAssertTrue(model.isFavorite(target))
        let calls = await resolvedCalls.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.url, oldRoot)
        XCTAssertEqual(calls.first?.bookmark, source.bookmark)
        XCTAssertEqual(calls.first?.onMainThread, false)
    }

    func testNewestFavoriteWinsAndLateResolutionErrorCannotInterruptIt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let deferred = DeferredFavoriteResolution()
        let model = FolderBrowserModel(store: fixture.store, favoriteResolver: { url, _ in try await deferred.resolve(url) })
        let first = FolderEntry(url: fixture.samples.appendingPathComponent("Bass.WAV"), isDirectory: false)
        let second = FolderEntry(url: fixture.samples.appendingPathComponent("Pack 2/Drums/Kick.wav"), isDirectory: false)
        model.toggleFavorite(first); model.toggleFavorite(second)
        let firstID = try XCTUnwrap(model.favorites.first(where: { $0.url == first.url })?.id)
        let secondID = try XCTUnwrap(model.favorites.first(where: { $0.url == second.url })?.id)
        var previews: [URL] = []
        model.onPreviewFavoriteAudio = { previews.append($0) }
        model.previewFavorite(firstID)
        try await eventually { await deferred.contains(first.url) }
        model.previewFavorite(secondID)
        try await eventually { await deferred.contains(second.url) }
        await deferred.finish(second.url, with: .success(second.url))
        await model.waitForIdle()
        await deferred.finish(first.url, with: .failure(FolderBrowserError.unavailable("stale")))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(previews, [second.url])
        XCTAssertEqual(model.selectedFavoriteID, secondID)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.columns.isEmpty)
    }

    func testLeavingFavoritesOrStartingNavigationCancelsPendingFavoriteAudio() async throws {
        for navigate in [false, true] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.base) }
            let deferred = DeferredFavoriteResolution()
            let model = FolderBrowserModel(store: fixture.store, favoriteResolver: { url, _ in try await deferred.resolve(url) })
            model.addSource(fixture.samples); await model.waitForIdle()
            let favorite = FolderEntry(url: fixture.samples.appendingPathComponent("Bass.WAV"), isDirectory: false)
            model.toggleFavorite(favorite)
            let id = try XCTUnwrap(model.favorites.first?.id)
            var previews: [URL] = []
            model.onPreviewFavoriteAudio = { previews.append($0) }
            model.previewFavorite(id)
            try await eventually { await deferred.contains(fixture.samples) }
            if navigate { model.openSource(try XCTUnwrap(model.sources.first?.id)) }
            else { model.cancelFavoritePreview() }
            await deferred.finish(fixture.samples, with: .success(fixture.samples))
            await model.waitForIdle()
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertNil(model.selectedFavoriteID)
            XCTAssertTrue(previews.isEmpty)
            XCTAssertNil(model.error)
        }
    }

    func testRemovingSelectedFavoriteCancelsPendingPreview() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let deferred = DeferredFavoriteResolution()
        let model = FolderBrowserModel(store: fixture.store, favoriteResolver: { url, _ in try await deferred.resolve(url) })
        let file = FolderEntry(url: fixture.samples.appendingPathComponent("Bass.WAV"), isDirectory: false)
        model.toggleFavorite(file)
        let id = try XCTUnwrap(model.favorites.first?.id)
        var previews: [URL] = []
        model.onPreviewFavoriteAudio = { previews.append($0) }
        model.previewFavorite(id)
        try await eventually { await deferred.contains(file.url) }
        model.removeFavorite(id)
        await deferred.finish(file.url, with: .success(file.url))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(model.selectedFavoriteID)
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertTrue(previews.isEmpty)
    }

    func testClearingFilteredFavoriteSelectionCancelsDelayedAutomaticAuditionAndKeepsSavedFavorite() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let deferred = DeferredFavoriteResolution()
        let model = FolderBrowserModel(store: fixture.store, favoriteResolver: { url, _ in try await deferred.resolve(url) })
        let file = FolderEntry(url: fixture.samples.appendingPathComponent("Bass.WAV"), isDirectory: false)
        model.toggleFavorite(file)
        let favorite = try XCTUnwrap(model.favorites.first)
        var automatic: [URL] = []
        model.onSelectFavoriteAudio = { automatic.append($0) }
        model.previewFavorite(favorite.id, explicitPlayback: false)
        try await eventually { await deferred.contains(file.url) }
        var selections: [FolderEntry?] = []
        model.onSelectionChange = { selections.append($0) }

        model.clearFavoriteSelection()
        model.clearFavoriteSelection() // A filtered UI and deletion may both reconcile.
        await deferred.finish(file.url, with: .success(file.url))
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertNil(model.selectedFavoriteID)
        XCTAssertEqual(selections, [nil], "Selection must clear its active/pending audio exactly once")
        XCTAssertEqual(model.favorites, [favorite], "Filtering must not erase saved favorites")
        XCTAssertTrue(automatic.isEmpty, "The delayed result cannot restart hidden audio")
    }

    func testRemovingAuditionedFavoriteClearsItsAudioSelection() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let model = FolderBrowserModel(store: fixture.store)
        let file = FolderEntry(url: fixture.samples.appendingPathComponent("Bass.WAV"), isDirectory: false)
        model.toggleFavorite(file)
        let id = try XCTUnwrap(model.favorites.first?.id)
        var previews: [URL] = []
        model.onPreviewFavoriteAudio = { previews.append($0) }
        model.previewFavorite(id); await model.waitForIdle()
        XCTAssertEqual(previews, [file.url])
        var selections: [FolderEntry?] = []
        model.onSelectionChange = { selections.append($0) }

        model.removeFavorite(id)

        XCTAssertEqual(selections, [nil])
        XCTAssertNil(model.selectedFavoriteID)
        XCTAssertTrue(model.favorites.isEmpty)
    }

    func testFavoritePreviewSupersedesPendingFavoriteAncestorNavigation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let deferred = DeferredFavoriteResolution()
        let model = FolderBrowserModel(store: fixture.store, reader: { url in
            if url.lastPathComponent == "Pack 2" { _ = try await deferred.resolve(url) }
            return try await FolderBrowserModel.readDirectory(url)
        })
        model.addSource(fixture.samples); await model.waitForIdle()
        let oldFile = FolderEntry(url: fixture.samples.appendingPathComponent("Pack 2/Drums/Kick.wav"), isDirectory: false)
        let newFile = FolderEntry(url: fixture.samples.appendingPathComponent("Bass.WAV"), isDirectory: false)
        model.toggleFavorite(oldFile); model.toggleFavorite(newFile)
        let oldID = try XCTUnwrap(model.favorites.first(where: { $0.url == oldFile.url })?.id)
        let newID = try XCTUnwrap(model.favorites.first(where: { $0.url == newFile.url })?.id)
        var previews: [URL] = [], oldSelections: [URL] = []
        model.onPreviewFavoriteAudio = { previews.append($0) }
        model.onSelectAudio = { oldSelections.append($0) }
        model.openFavorite(oldID)
        let pendingFolder = fixture.samples.appendingPathComponent("Pack 2", isDirectory: true)
        try await eventually { await deferred.contains(pendingFolder) }
        model.previewFavorite(newID); await model.waitForIdle()
        await deferred.finish(pendingFolder, with: .success(pendingFolder))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(previews, [newFile.url])
        XCTAssertTrue(oldSelections.isEmpty)
        XCTAssertEqual(model.selectedFavoriteID, newID)
        XCTAssertFalse(model.loading)
        XCTAssertFalse(model.columns.contains(where: \.isLoading))
        XCTAssertNotNil(model.columns.last?.error, "An interrupted column remains retryable when returning to folders")
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Favorite resolution did not settle")
        throw FolderBrowserError.unavailable("Timed out")
    }

    private func makeFixture() throws -> (base: URL, samples: URL, store: FolderBrowserStore) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("folder-browser-tests-\(UUID())", isDirectory: true)
        let samples = base.appendingPathComponent("Samples", isDirectory: true)
        for folder in ["Pack 2/Drums", "Pack 10", ".Hidden Pack"] {
            try FileManager.default.createDirectory(at: samples.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for name in ["Bass.WAV", "Texture.FLAC", "notes.txt", ".Hidden.wav", "Pack 2/Pad.aiff", "Pack 2/Drums/Kick.wav"] {
            try Data("fixture".utf8).write(to: samples.appendingPathComponent(name))
        }
        try FileManager.default.createSymbolicLink(at: samples.appendingPathComponent("Linked Pack"), withDestinationURL: samples.appendingPathComponent("Pack 2"))
        return (base, samples, FolderBrowserStore(fileURL: base.appendingPathComponent("preferences.json")))
    }
}

private actor FavoriteDirectoryReadCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor FolderRefreshReadRecorder {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}

private func favoriteResolutionIsOnMainThread() -> Bool { Thread.isMainThread }

private actor FavoriteResolverRecorder {
    struct Call: Sendable { let url: URL; let bookmark: Data?; let onMainThread: Bool }
    private(set) var calls: [Call] = []
    func record(url: URL, bookmark: Data?, onMainThread: Bool) {
        calls.append(Call(url: url, bookmark: bookmark, onMainThread: onMainThread))
    }
}

private actor DeferredFavoriteResolution {
    private var pending: [URL: CheckedContinuation<URL, Error>] = [:]
    func resolve(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { pending[url] = $0 }
    }
    func contains(_ url: URL) -> Bool { pending[url] != nil }
    func finish(_ url: URL, with result: Result<URL, Error>) { pending.removeValue(forKey: url)?.resume(with: result) }
}
