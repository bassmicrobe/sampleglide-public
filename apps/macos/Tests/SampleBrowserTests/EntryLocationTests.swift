import XCTest
@testable import SampleBrowser

@MainActor final class EntryLocationTests: XCTestCase {
    func testSearchResultRestoresHierarchyFromMostSpecificSourceWithoutChangingFavorites() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let model = FolderBrowserModel(store: fixture.store)
        model.addSource(fixture.samples); await model.waitForIdle()
        model.addSource(fixture.pack); await model.waitForIdle()
        let sourceID = try XCTUnwrap(model.sources.first(where: { $0.url == fixture.pack })?.id)
        let group = try XCTUnwrap(model.createFavoriteFolder(name: "Keep"))
        model.addFavorite(FolderEntry(url: fixture.otherFile, isDirectory: false), to: group)
        let favoriteState = model.favorites, folders = model.favoriteFolders
        let saved = try Data(contentsOf: fixture.store.fileURL)
        var selectedAudio: [URL] = []
        model.onSelectAudio = { selectedAudio.append($0) }

        let result = FolderEntry(url: fixture.kick, isDirectory: false)
        model.openEntryLocation(result); await model.waitForIdle()
        XCTAssertEqual(model.columns.map(\.directoryURL), [fixture.pack, fixture.drums])
        XCTAssertEqual(model.selectedSourceID, sourceID)
        XCTAssertEqual(model.selectedEntry, result)
        XCTAssertEqual(selectedAudio, [fixture.kick])
        XCTAssertEqual(model.favorites, favoriteState)
        XCTAssertEqual(model.favoriteFolders, folders)
        XCTAssertEqual(try Data(contentsOf: fixture.store.fileURL), saved, "Revealing an entry must not create a favorite or save changed preferences")

        let directory = FolderEntry(url: fixture.drums, isDirectory: true)
        model.openEntryLocation(directory); await model.waitForIdle()
        XCTAssertEqual(model.columns.map(\.directoryURL), [fixture.pack, fixture.drums])
        XCTAssertEqual(model.selectedEntry, directory)
        XCTAssertEqual(selectedAudio, [fixture.kick], "Directory results navigate without starting audio")
        XCTAssertEqual(model.favorites, favoriteState)
    }

    func testUnregisteredSearchResultUsesFileParentOrDirectoryItselfWithoutSavingSource() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let model = FolderBrowserModel(store: fixture.store)
        var selectedAudio: [URL] = []
        model.onSelectAudio = { selectedAudio.append($0) }
        let file = FolderEntry(url: fixture.kick, isDirectory: false)
        model.openEntryLocation(file); await model.waitForIdle()
        XCTAssertEqual(model.columns.map(\.directoryURL), [fixture.drums])
        XCTAssertEqual(model.selectedEntry, file)
        XCTAssertNil(model.selectedSourceID)
        XCTAssertEqual(selectedAudio, [fixture.kick])

        let directory = FolderEntry(url: fixture.drums, isDirectory: true)
        model.openEntryLocation(directory); await model.waitForIdle()
        XCTAssertEqual(model.columns.map(\.directoryURL), [fixture.drums])
        XCTAssertEqual(model.selectedEntry, directory)
        XCTAssertNil(model.selectedSourceID)
        XCTAssertTrue(model.sources.isEmpty)
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
        XCTAssertEqual(selectedAudio, [fixture.kick])
    }

    func testLateSearchResultNavigationCannotOverrideNewerLocationOrPlayOldAudio() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let deferred = DeferredEntryLocationRead()
        let model = FolderBrowserModel(store: fixture.store, reader: { url in
            if url == fixture.drums { await deferred.wait() }
            return try await FolderBrowserModel.readDirectory(url)
        })
        model.addSource(fixture.samples); await model.waitForIdle()
        var selectedAudio: [URL] = []
        model.onSelectAudio = { selectedAudio.append($0) }
        model.openEntryLocation(FolderEntry(url: fixture.kick, isDirectory: false))
        try await eventually { await deferred.pending }
        let newer = FolderEntry(url: fixture.otherFile, isDirectory: false)
        model.openEntryLocation(newer); await model.waitForIdle()
        await deferred.release()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(model.selectedEntry, newer)
        XCTAssertEqual(model.columns.map(\.directoryURL), [fixture.samples])
        XCTAssertEqual(selectedAudio, [fixture.otherFile])
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.favorites.isEmpty)
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Location navigation did not reach the delayed directory")
        throw FolderBrowserError.unavailable("Timed out")
    }

    private func fixture() throws -> (base: URL, samples: URL, pack: URL, drums: URL, kick: URL, otherFile: URL, store: FolderBrowserStore) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("entry-location-tests-\(UUID())", isDirectory: true)
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

private actor DeferredEntryLocationRead {
    private var continuation: CheckedContinuation<Void, Never>?
    var pending: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
