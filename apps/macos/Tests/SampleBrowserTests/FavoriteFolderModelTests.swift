import XCTest
@testable import SampleBrowser

@MainActor final class FavoriteFolderModelTests: XCTestCase {
    func testNamedFoldersCreateRenameReloadAndRejectAmbiguousNames() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let model = FolderBrowserModel(store: fixture.store)
        let drums = try XCTUnwrap(model.createFavoriteFolder(name: "  Drums  "))
        let bass = try XCTUnwrap(model.createFavoriteFolder(name: "Bass"))
        XCTAssertEqual(model.favoriteFolders.first(where: { $0.id == drums })?.name, "Drums")
        XCTAssertNil(model.createFavoriteFolder(name: " drums "))
        XCTAssertEqual(model.error, "同じ名前のお気に入りフォルダがあります。")
        model.renameFavoriteFolder(bass, name: "DRUMS")
        XCTAssertEqual(model.favoriteFolders.first(where: { $0.id == bass })?.name, "Bass")
        model.renameFavoriteFolder(drums, name: "  Drum Kit  ")
        XCTAssertNil(model.error)
        XCTAssertEqual(model.favoriteFolders.first(where: { $0.id == drums })?.name, "Drum Kit")
        // The same folder may change only the case of its own name.
        model.renameFavoriteFolder(drums, name: "drum kit")
        XCTAssertNil(model.error)
        let restored = FolderBrowserModel(store: fixture.store)
        XCTAssertEqual(restored.favoriteFolders, model.favoriteFolders)
        XCTAssertEqual(restored.favoriteFolders.map(\.id), [FavoriteFolder.defaultID, drums, bass])
        for invalid in ["  ", "Drum\nKit", String(repeating: "x", count: 121), "Bad\0Name"] {
            XCTAssertNil(model.createFavoriteFolder(name: invalid))
        }
        XCTAssertEqual(model.favoriteFolders, restored.favoriteFolders)
    }

    func testSameFavoriteBelongsToMultipleFoldersWithoutDuplicatingOrLosingAlias() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let model = FolderBrowserModel(store: fixture.store)
        let drums = try XCTUnwrap(model.createFavoriteFolder(name: "Drums"))
        let live = try XCTUnwrap(model.createFavoriteFolder(name: "Live Set"))
        let entry = FolderEntry(url: fixture.file, isDirectory: false)
        model.addFavorite(entry, to: drums)
        let id = try XCTUnwrap(model.favorites.first?.id)
        model.renameFavorite(id, name: "My Kick")
        model.addFavorite(entry, to: live)
        model.addFavorite(entry, to: live)
        XCTAssertEqual(model.favorites.count, 1)
        XCTAssertEqual(model.favorites.first?.id, id)
        XCTAssertEqual(model.favorites.first?.name, "My Kick")
        XCTAssertEqual(model.favorites.first?.folderIDs, [drums, live])
        XCTAssertEqual(model.favorites(in: drums).map(\.id), [id])
        XCTAssertEqual(model.favorites(in: live).map(\.id), [id])
        model.setFavoriteMembership(id, folderID: drums, included: false)
        XCTAssertTrue(model.favorites(in: drums).isEmpty)
        XCTAssertEqual(model.favorites(in: live).map(\.id), [id])
        model.setFavoriteMembership(id, folderID: live, included: false)
        XCTAssertEqual(model.favorites(in: nil).map(\.id), [id], "Removing every membership retains the global favorite")
        XCTAssertEqual(model.favorites.first?.folderIDs, [])
        XCTAssertEqual(try fixture.store.load().favorites, model.favorites)
        XCTAssertEqual(try Data(contentsOf: fixture.file), Data("audio fixture".utf8))
    }

    func testDeletingFavoriteFolderKeepsGlobalFileAndDirectoryFavorites() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let model = FolderBrowserModel(store: fixture.store)
        let group = try XCTUnwrap(model.createFavoriteFolder(name: "Production"))
        model.addFavorite(FolderEntry(url: fixture.file, isDirectory: false), to: group)
        model.addFavorite(FolderEntry(url: fixture.samples, isDirectory: true), to: group)
        let ids = model.favorites.map(\.id)
        model.removeFavoriteFolder(group)
        XCTAssertEqual(model.favorites(in: nil).map(\.id), ids)
        XCTAssertTrue(model.favorites.allSatisfy { $0.folderIDs.isEmpty })
        XCTAssertFalse(model.favoriteFolders.contains(where: { $0.id == group }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.samples.path))
        let restored = FolderBrowserModel(store: fixture.store)
        XCTAssertEqual(restored.favorites, model.favorites)
        XCTAssertEqual(restored.favoriteFolders, model.favoriteFolders)
    }

    func testGlobalFavoriteDefaultsToDefaultFolderThenFirstFolderThenAllOnly() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let model = FolderBrowserModel(store: fixture.store)
        let entry = FolderEntry(url: fixture.file, isDirectory: false)
        model.toggleFavorite(entry)
        XCTAssertEqual(model.favorites.first?.folderIDs, [FavoriteFolder.defaultID])
        model.toggleFavorite(entry)
        let group = try XCTUnwrap(model.createFavoriteFolder(name: "Working Set"))
        model.removeFavoriteFolder(FavoriteFolder.defaultID)
        model.toggleFavorite(entry)
        XCTAssertEqual(model.favorites.first?.folderIDs, [group])
        model.toggleFavorite(entry)
        model.removeFavoriteFolder(group)
        model.toggleFavorite(entry)
        XCTAssertEqual(model.favorites.first?.folderIDs, [])
        XCTAssertEqual(model.favorites(in: nil).count, 1)
        XCTAssertTrue(model.favoriteFolders.isEmpty)
        XCTAssertTrue(FolderBrowserModel(store: fixture.store).favoriteFolders.isEmpty)
    }

    func testSourceAndFavoritePersistencePreservesNamedFoldersAndMembership() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let model = FolderBrowserModel(store: fixture.store)
        let group = try XCTUnwrap(model.createFavoriteFolder(name: "Album"))
        let folders = model.favoriteFolders
        model.addSource(fixture.samples); await model.waitForIdle()
        XCTAssertEqual(try fixture.store.load().favoriteFolders, folders)
        model.toggleFavorite(FolderEntry(url: fixture.file, isDirectory: false))
        let id = try XCTUnwrap(model.favorites.first?.id)
        model.setFavoriteMembership(id, folderID: group, included: true)
        model.renameFavorite(id, name: "Album Kick")
        let memberships = try XCTUnwrap(model.favorites.first?.folderIDs)
        XCTAssertEqual(try fixture.store.load().favoriteFolders, folders)
        model.removeSource(try XCTUnwrap(model.sources.first?.id))
        let detached = try fixture.store.load()
        XCTAssertEqual(detached.favoriteFolders, folders)
        XCTAssertEqual(detached.favorites.first?.folderIDs, memberships)
        XCTAssertNil(detached.favorites.first?.sourceID)
        model.removeFavorite(id)
        XCTAssertEqual(try fixture.store.load().favoriteFolders, folders)
        XCTAssertTrue(try fixture.store.load().favorites.isEmpty)
    }

    func testRemountPathUpdatePreservesNamedFoldersAndMembership() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let oldRoot = fixture.base.appendingPathComponent("OldMount", isDirectory: true)
        let group = FavoriteFolder(id: UUID(), name: "NAS Drums")
        let source = FolderSource(id: UUID(), name: "NAS", savedPath: oldRoot.path, bookmark: nil)
        let favorite = FolderFavorite(id: UUID(), name: "Kick", savedPath: oldRoot.appendingPathComponent("Kick.wav").path,
            isDirectory: false, sourceID: source.id, relativePath: "Kick.wav", bookmark: nil,
            folderIDs: [FavoriteFolder.defaultID, group.id])
        let groups: [FavoriteFolder] = [.defaultFolder, group]
        try fixture.store.save(FolderBrowserState(sources: [source], favorites: [favorite], favoriteFolders: groups))
        let model = FolderBrowserModel(store: fixture.store, favoriteResolver: { _, _ in fixture.samples })
        var preview: URL?
        model.onPreviewFavoriteAudio = { preview = $0 }
        model.previewFavorite(favorite.id); await model.waitForIdle()
        XCTAssertEqual(preview, fixture.file)
        let restored = try fixture.store.load()
        XCTAssertEqual(restored.favoriteFolders, groups)
        XCTAssertEqual(restored.favorites.first?.folderIDs, favorite.folderIDs)
        XCTAssertEqual(restored.favorites.first?.url, fixture.file)
        XCTAssertEqual(restored.sources.first?.url, fixture.samples)
    }

    private func fixture() throws -> (base: URL, samples: URL, file: URL, store: FolderBrowserStore) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("favorite-folder-model-\(UUID())", isDirectory: true)
        let samples = base.appendingPathComponent("Samples", isDirectory: true)
        try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        let file = samples.appendingPathComponent("Kick.wav")
        try Data("audio fixture".utf8).write(to: file)
        return (base, samples, file, FolderBrowserStore(fileURL: base.appendingPathComponent("preferences.json")))
    }
}
