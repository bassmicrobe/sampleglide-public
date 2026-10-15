import XCTest
@testable import SampleBrowser

final class FavoriteFolderStoreTests: XCTestCase {
    func testMissingStateReturnsDefaultFolderWithoutCreatingAnyFiles() throws {
        let directory = temporaryDirectory()
        let store = FolderBrowserStore(fileURL: directory.appendingPathComponent("folders.json"))
        let state = try store.load()
        XCTAssertEqual(state.version, 2)
        XCTAssertEqual(state.favoriteFolders, [.defaultFolder])
        XCTAssertTrue(state.favorites.isEmpty)
        XCTAssertTrue(state.sources.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testVersionOneMigrationPreservesEveryExistingFieldAndNeverWritesOnLoad() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = FolderSource(id: UUID(), name: "制作 NAS", savedPath: "/Volumes/Old NAS/Samples", bookmark: Data([1, 3, 5, 7]))
        let file = FolderFavorite(id: UUID(), name: "自分のキック", savedPath: "/Volumes/Old NAS/Samples/Drums/Kick.wav", isDirectory: false, sourceID: source.id, relativePath: "Drums/Kick.wav", bookmark: Data([2, 4, 6]))
        let directory = FolderFavorite(id: UUID(), name: "よく使うパッド", savedPath: "/Volumes/Another NAS/Pads", isDirectory: true, sourceID: nil, relativePath: nil, bookmark: Data([9, 8, 7]))
        let legacy = try legacyJSON(sources: [source], favorites: [file, directory])
        try legacy.write(to: fixture.store.fileURL)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: fixture.store.fileURL.path)

        let loaded = try fixture.store.load()

        XCTAssertEqual(loaded.version, 2)
        XCTAssertEqual(loaded.favoriteFolders, [.defaultFolder])
        XCTAssertEqual(loaded.sources, [source])
        var migrated = [file, directory]
        for index in migrated.indices { migrated[index].folderIDs = [FavoriteFolder.defaultID] }
        XCTAssertEqual(loaded.favorites, migrated, "IDs, aliases, source IDs, relative paths and bookmarks must all survive migration")
        XCTAssertEqual(try Data(contentsOf: fixture.store.fileURL), legacy)
        let afterLoadAttributes = try FileManager.default.attributesOfItem(atPath: fixture.store.fileURL.path)
        XCTAssertEqual(originalAttributes[.modificationDate] as? Date, afterLoadAttributes[.modificationDate] as? Date)

        try fixture.store.save(loaded)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.store.fileURL)) as? [String: Any])
        XCTAssertEqual(saved["version"] as? Int, 2)
        XCTAssertNotNil(saved["favoriteFolders"])
        XCTAssertEqual(try fixture.store.load(), loaded)
    }

    func testVersionTwoSupportsMultipleMembershipsAndFolderRenameRoundTrip() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let drums = FavoriteFolder(id: UUID(), name: "Drums"), live = FavoriteFolder(id: UUID(), name: "Live set")
        let source = FolderSource(id: UUID(), name: "NAS", savedPath: "/Volumes/Test NAS/Samples", bookmark: Data([1]))
        let shared = FolderFavorite(id: UUID(), name: "Kick alias", savedPath: "/Volumes/Test NAS/Samples/Kick.wav", isDirectory: false, sourceID: source.id, relativePath: "Kick.wav", bookmark: Data([2]), folderIDs: [drums.id, live.id])
        let unfiled = favorite(name: "All Favorites only")
        var state = FolderBrowserState(sources: [source], favorites: [shared, unfiled], favoriteFolders: [drums, live])
        try fixture.store.save(state)
        XCTAssertEqual(try fixture.store.load(), state)

        state.favoriteFolders[0].name = "ドラム素材"
        try fixture.store.save(state)
        let restored = try fixture.store.load()
        XCTAssertEqual(restored, state)
        XCTAssertEqual(restored.favoriteFolders[0].id, drums.id)
        XCTAssertEqual(restored.favorites, [shared, unfiled], "Folder renames must not alter aliases, memberships or source paths")
        XCTAssertEqual(restored.sources, [source])
    }

    func testZeroNamedFoldersKeepsUnfiledFavoritesAndDoesNotRecreateDefaultFolder() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let state = FolderBrowserState(favorites: [favorite(name: "Unfiled")], favoriteFolders: [])
        try fixture.store.save(state)
        XCTAssertEqual(try fixture.store.load(), state)
        XCTAssertTrue(try fixture.store.load().favoriteFolders.isEmpty)
    }

    func testInvalidFolderReferencesAndDuplicateMembershipsAreRejectedOnSaveAndLoad() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let folder = FavoriteFolder(id: UUID(), name: "Folder")
        let valid = FolderBrowserState(favorites: [favorite(folderIDs: [folder.id])], favoriteFolders: [folder])
        var missingReference = valid
        missingReference.favorites[0].folderIDs = [UUID()]
        var duplicateMembership = valid
        duplicateMembership.favorites[0].folderIDs = [folder.id, folder.id]
        var deletedFolder = valid
        deletedFolder.favoriteFolders = []
        var duplicateFolders = valid
        duplicateFolders.favoriteFolders.append(FavoriteFolder(id: folder.id, name: "Duplicate UUID"))
        var duplicateFavorites = valid
        duplicateFavorites.favorites.append(valid.favorites[0])
        for invalid in [missingReference, duplicateMembership, deletedFolder, duplicateFolders, duplicateFavorites] {
            try fixture.store.save(valid)
            let original = try Data(contentsOf: fixture.store.fileURL)
            XCTAssertThrowsError(try fixture.store.save(invalid))
            XCTAssertEqual(try Data(contentsOf: fixture.store.fileURL), original, "Rejected saves must preserve the last valid state")
            let invalidBytes = try JSONEncoder().encode(invalid)
            try invalidBytes.write(to: fixture.store.fileURL)
            XCTAssertThrowsError(try fixture.store.load())
            XCTAssertEqual(try Data(contentsOf: fixture.store.fileURL), invalidBytes, "Loading corrupt state must not silently rewrite it")
        }
    }

    func testFolderNamesAndCountAreBoundedButEqualDisplayNamesAreAllowed() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for invalidName in ["", " \t ", "two\nlines", "nul\0name", String(repeating: "あ", count: 121)] {
            let state = FolderBrowserState(favoriteFolders: [FavoriteFolder(id: UUID(), name: invalidName)])
            XCTAssertThrowsError(try fixture.store.save(state), "Invalid folder name: \(invalidName.debugDescription)")
        }
        let limit = (0..<64).map { _ in FavoriteFolder(id: UUID(), name: String(repeating: "あ", count: 120)) }
        let allowed = FolderBrowserState(favoriteFolders: limit)
        try fixture.store.save(allowed)
        XCTAssertEqual(try fixture.store.load(), allowed)
        let excessive = FolderBrowserState(favoriteFolders: limit + [FavoriteFolder(id: UUID(), name: "65")])
        XCTAssertThrowsError(try fixture.store.save(excessive))
    }

    func testUnsupportedVersionsAndMissingVersionTwoFoldersAreRejectedWithoutWrites() throws {
        let fixture = try makeStore()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        for json: [String: Any] in [
            ["version": 3, "sources": [], "favorites": [], "favoriteFolders": []],
            ["version": 0, "sources": [], "favorites": []],
            ["version": 2, "sources": [], "favorites": []]
        ] {
            let bytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            try bytes.write(to: fixture.store.fileURL)
            XCTAssertThrowsError(try fixture.store.load())
            XCTAssertEqual(try Data(contentsOf: fixture.store.fileURL), bytes)
        }
    }

    private func favorite(name: String = "Sample", folderIDs: [UUID] = []) -> FolderFavorite {
        FolderFavorite(id: UUID(), name: name, savedPath: "/Volumes/Test NAS/Sample.wav", isDirectory: false, sourceID: nil, relativePath: nil, bookmark: nil, folderIDs: folderIDs)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("favorite-folders-store-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeStore() throws -> (directory: URL, store: FolderBrowserStore) {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, FolderBrowserStore(fileURL: directory.appendingPathComponent("folders.json")))
    }

    private func legacyJSON(sources: [FolderSource], favorites: [FolderFavorite]) throws -> Data {
        let state = FolderBrowserState(sources: sources, favorites: favorites)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json["version"] = 1
        json.removeValue(forKey: "favoriteFolders")
        var entries = try XCTUnwrap(json["favorites"] as? [[String: Any]])
        for index in entries.indices { entries[index].removeValue(forKey: "folderIDs") }
        json["favorites"] = entries
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }
}
