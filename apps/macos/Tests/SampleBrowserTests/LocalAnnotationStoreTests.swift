import XCTest
@testable import SampleBrowser

private struct AnnotationSearchFixture: Encodable {
    var version = 1
    let records: [LocalAnnotation]
}

@MainActor final class LocalAnnotationStoreTests: XCTestCase {
    func testSaveReloadPreservesJapaneseMultilineNotesAndNormalizesTags() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = LocalAnnotationStore(fileURL: fixture.fileURL)
        let notes = "柔らかいキック\n\nサビの頭に使用。\n  余白も保持  "
        XCTAssertTrue(store.save(entry: fixture.entry, notes: notes, tags: [" #House ", "house", "##深い", " café ", "CAFE", "", "#"], sources: [fixture.source]))
        let annotation = try XCTUnwrap(store.annotation(for: fixture.entry, sources: [fixture.source]))
        XCTAssertEqual(annotation.notes, notes)
        XCTAssertEqual(annotation.tags, ["café", "House", "深い"])
        XCTAssertEqual(annotation.sourceID, fixture.source.id)
        XCTAssertEqual(annotation.relativePath, "Drums/Kick.wav")
        let restored = LocalAnnotationStore(fileURL: fixture.fileURL)
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.records, store.records)
        XCTAssertEqual(restored.allTags, ["café", "House", "深い"])
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(try Data(contentsOf: fixture.entry.url), Data("original sample".utf8), "Annotation writes must leave source bytes unchanged")
    }

    func testFavoriteAliasAndFolderEntryShareOneAnnotationIdentity() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = LocalAnnotationStore(fileURL: fixture.fileURL)
        XCTAssertTrue(store.save(entry: fixture.entry, notes: "元のメモ", tags: ["kick"], sources: [fixture.source]))
        let originalID = try XCTUnwrap(store.records.first?.id)
        let favorite = FolderFavorite(id: UUID(), name: "お気に入りキック", savedPath: fixture.entry.url.path, isDirectory: false, sourceID: fixture.source.id, relativePath: "Drums/Kick.wav", bookmark: nil)
        let favoriteEntry = FolderEntry(url: favorite.url, name: favorite.name, isDirectory: favorite.isDirectory)
        XCTAssertEqual(store.annotation(for: favoriteEntry, sources: [fixture.source])?.id, originalID)
        XCTAssertTrue(store.matches(entry: fixture.entry, query: "お気に入り", sources: [fixture.source], alternateName: favorite.name))
        XCTAssertTrue(store.save(entry: favoriteEntry, notes: "お気に入りから更新", tags: ["DRUM"], sources: [fixture.source]))
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.annotation(for: fixture.entry, sources: [fixture.source])?.id, originalID)
        XCTAssertEqual(store.annotation(for: fixture.entry, sources: [fixture.source])?.notes, "お気に入りから更新")
    }

    func testRemountedSourceResolvesRelativePathAndRetainsRecordID() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = LocalAnnotationStore(fileURL: fixture.fileURL)
        XCTAssertTrue(store.save(entry: fixture.entry, notes: "NAS の素材", tags: ["重要"], sources: [fixture.source]))
        let original = try XCTUnwrap(store.records.first)
        var remountedSource = fixture.source
        remountedSource.savedPath = fixture.directory.appendingPathComponent("NAS-1").path
        let remounted = FolderEntry(url: remountedSource.url.appendingPathComponent("Drums/Kick.wav"), isDirectory: false)
        XCTAssertEqual(original.entry(sources: [remountedSource]).url, remounted.url)
        XCTAssertEqual(store.annotation(for: remounted, sources: [remountedSource])?.id, original.id)
        XCTAssertEqual(store.search(query: "#重要 NAS", sources: [remountedSource]).first?.entry(sources: [remountedSource]).url, remounted.url)
        XCTAssertTrue(store.save(entry: remounted, notes: "再接続後のメモ", tags: ["重要"], sources: [remountedSource]))
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.id, original.id)
        XCTAssertEqual(store.records.first?.savedPath, remounted.url.path)
        let restored = LocalAnnotationStore(fileURL: fixture.fileURL)
        XCTAssertEqual(restored.annotation(for: remounted, sources: [remountedSource])?.notes, "再接続後のメモ")
        XCTAssertEqual(original.entry(sources: []).url, fixture.entry.url, "Removed sources fall back to the saved path")
    }

    func testSearchUsesAndAcrossJapaneseNotesNamesAndMultipleTags() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = LocalAnnotationStore(fileURL: fixture.fileURL)
        let pad = FolderEntry(url: fixture.source.url.appendingPathComponent("Pad.wav"), isDirectory: false)
        let noTags = FolderEntry(url: fixture.source.url.appendingPathComponent("Ambient.wav"), isDirectory: false)
        XCTAssertTrue(store.save(entry: fixture.entry, notes: "柔らかい低音。空間を広く", tags: ["Ambient", "Café", "深い"], sources: [fixture.source]))
        XCTAssertTrue(store.save(entry: pad, notes: "明るいパッド", tags: ["Ambient Pad", "深い"], sources: [fixture.source]))
        XCTAssertTrue(store.save(entry: noTags, notes: "名前に Ambient を含む", tags: [], sources: [fixture.source]))
        XCTAssertEqual(store.search(query: "柔らか #ambi #深", sources: [fixture.source]).map(\.savedPath), [fixture.entry.url.path])
        XCTAssertEqual(store.search(query: "KICK CAFE", sources: [fixture.source]).count, 1)
        XCTAssertEqual(store.search(query: "#ambient", sources: [fixture.source]).count, 2, "A hashtag must not match only the filename or notes")
        XCTAssertEqual(store.search(query: "#ambient", tag: "AMBIENT", sources: [fixture.source]).count, 1, "The tag filter is exact, although hashtag tokens are partial")
        XCTAssertTrue(store.search(query: "柔らか #missing", sources: [fixture.source]).isEmpty)
        XCTAssertFalse(store.matches(entry: noTags, query: "#ambient", sources: [fixture.source]))
        XCTAssertTrue(store.matches(entry: noTags, query: "ambient 名前", sources: [fixture.source]))
        let unannotated = FolderEntry(url: fixture.source.url.appendingPathComponent("Bright Bell.wav"), isDirectory: false)
        XCTAssertTrue(store.matches(entry: unannotated, query: "bright bell", sources: [fixture.source]))
        XCTAssertFalse(store.matches(entry: unannotated, query: "#bell", sources: [fixture.source]))
    }

    func testCachedLookupsRefreshAfterRemountSourceRemovalAndRecordEdits() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = LocalAnnotationStore(fileURL: fixture.fileURL)
        XCTAssertNil(store.annotation(for: fixture.entry, sources: [fixture.source]))
        XCTAssertTrue(store.save(entry: fixture.entry, notes: "original", tags: ["old"], sources: [fixture.source]))
        let originalID = try XCTUnwrap(store.annotation(for: fixture.entry, sources: [fixture.source])?.id)

        var remountedSource = fixture.source
        remountedSource.savedPath = fixture.directory.appendingPathComponent("NAS-1", isDirectory: true).path
        let remounted = FolderEntry(url: remountedSource.url.appendingPathComponent("Drums/Kick.wav"), isDirectory: false)
        XCTAssertEqual(store.annotation(for: remounted, sources: [remountedSource])?.id, originalID)
        XCTAssertNil(store.annotation(for: fixture.entry, sources: [remountedSource]), "A warm path index must stop pointing to the old mount")
        XCTAssertEqual(store.annotation(for: fixture.entry, sources: [])?.id, originalID, "Removing the root must restore the saved-path fallback")
        XCTAssertNil(store.annotation(for: remounted, sources: []))

        XCTAssertEqual(store.annotation(for: remounted, sources: [remountedSource])?.id, originalID)
        XCTAssertTrue(store.save(entry: remounted, notes: "edited", tags: ["new"], sources: [remountedSource]))
        XCTAssertEqual(store.annotation(for: remounted, sources: [remountedSource])?.notes, "edited")
        XCTAssertEqual(store.annotation(for: remounted, sources: [])?.id, originalID, "After editing, fallback follows the latest saved path")
        XCTAssertTrue(store.search(query: "#old", sources: [remountedSource]).isEmpty)
        XCTAssertEqual(store.search(query: "kick #new", sources: [remountedSource]).map(\.id), [originalID])

        XCTAssertTrue(store.save(entry: remounted, notes: "", tags: [], sources: [remountedSource]))
        XCTAssertNil(store.annotation(for: remounted, sources: [remountedSource]))
        XCTAssertTrue(store.search(query: "", sources: [remountedSource]).isEmpty)
    }

    func testNormalizedNestedRootAnchorsSurviveSourceIdentityChanges() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = LocalAnnotationStore(fileURL: fixture.fileURL)
        let nested = FolderSource(id: UUID(), name: "Drums", savedPath: fixture.source.savedPath + "//Drums///", bookmark: nil)
        XCTAssertTrue(store.save(entry: fixture.entry, notes: "nested", tags: [], sources: [fixture.source, nested]))
        let original = try XCTUnwrap(store.annotation(for: fixture.entry, sources: [fixture.source, nested]))
        XCTAssertEqual(original.sourceID, nested.id)
        XCTAssertEqual(original.relativePath, "Kick.wav")

        let replacement = FolderSource(id: UUID(), name: "Re-added Drums", savedPath: nested.savedPath, bookmark: nil)
        XCTAssertEqual(store.annotation(for: fixture.entry, sources: [fixture.source, replacement])?.id, original.id, "A new source UUID at the same path must retain path-based annotations")
        XCTAssertTrue(store.save(entry: fixture.entry, notes: "re-anchored", tags: [], sources: [fixture.source, replacement]))
        XCTAssertEqual(store.annotation(for: fixture.entry, sources: [fixture.source, replacement])?.sourceID, replacement.id)
        XCTAssertEqual(store.records.count, 1)
    }

    func testSavedAnnotationRenderingResolvesOfflineRemountPathsLexically() throws {
        let sourceID = UUID()
        let source = FolderSource(id: sourceID, name: "Offline NAS", savedPath: "/Volumes/Unavailable NAS-1//日本語///", bookmark: nil)
        let annotation = LocalAnnotation(id: UUID(), savedPath: "/Volumes/Unavailable NAS/日本語/Kick #1.wav", isDirectory: false,
            sourceID: sourceID, relativePath: "Drums/Kick #1.wav", notes: "warm", tags: ["House"])
        let entry = annotation.entry(sources: [source])
        XCTAssertEqual(entry.id, "/Volumes/Unavailable NAS-1/日本語/Drums/Kick #1.wav")
        XCTAssertEqual(entry.name, "Kick #1.wav")
        XCTAssertEqual(annotation.entry(sources: []).id, annotation.savedPath)
        let directory = LocalAnnotation(id: UUID(), savedPath: "/Volumes/Unavailable NAS/日本語", isDirectory: true,
            sourceID: sourceID, relativePath: "", notes: "root", tags: [])
        XCTAssertEqual(directory.entry(sources: [source]).id, "/Volumes/Unavailable NAS-1/日本語")
    }

    func testCachedSearchResultsAndResolvedEntriesRefreshAfterEditsAndSourceChanges() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = LocalAnnotationStore(fileURL: fixture.fileURL)
        XCTAssertTrue(store.save(entry: fixture.entry, notes: "warm", tags: ["House"], sources: [fixture.source]))
        let original = try XCTUnwrap(store.search(query: "warm #house", sources: [fixture.source]).first)
        XCTAssertEqual(store.search(query: "warm #house", sources: [fixture.source]).map(\.id), [original.id])
        var source = fixture.source
        source.savedPath = "/Volumes/Offline New Mount//Samples///"
        let remounted = store.entry(for: original, sources: [source])
        XCTAssertEqual(remounted.id, "/Volumes/Offline New Mount/Samples/Drums/Kick.wav")
        XCTAssertEqual(store.entry(for: original, sources: []).id, fixture.entry.id)
        XCTAssertTrue(store.save(entry: fixture.entry, notes: "bright", tags: ["House"], sources: [fixture.source]))
        XCTAssertTrue(store.search(query: "warm #house", sources: [fixture.source]).isEmpty, "Repeated query results must expire after edits")
        XCTAssertEqual(store.search(query: "bright #house", sources: [fixture.source]).map(\.id), [original.id])
        XCTAssertTrue(store.save(entry: fixture.entry, notes: "", tags: [], sources: [fixture.source]))
        XCTAssertTrue(store.search(query: "bright #house", sources: [fixture.source]).isEmpty)
    }

    func testLargeAnnotationSearchReusesResultsAndPreservesNaturalNameOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-search-benchmark-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("annotations.json")
        let values = (0..<10_000).reversed().map { index in
            LocalAnnotation(id: UUID(), savedPath: "/tmp/Annotation Search/Kick \(index).wav", isDirectory: false,
                sourceID: nil, relativePath: nil, notes: String(repeating: "Ambient sound memo house. ", count: 40), tags: ["House", "Kick", "Warm"])
        }
        try JSONEncoder().encode(AnnotationSearchFixture(records: values)).write(to: fileURL)
        let store = LocalAnnotationStore(fileURL: fileURL)
        XCTAssertNil(store.error)
        let firstStart = Date.timeIntervalSinceReferenceDate
        let first = store.search(query: "house warm", sources: [])
        let firstSeconds = Date.timeIntervalSinceReferenceDate - firstStart
        XCTAssertEqual(first.count, 10_000)
        XCTAssertEqual(first.prefix(3).map { store.entry(for: $0, sources: []).name }, ["Kick 0.wav", "Kick 1.wav", "Kick 2.wav"])
        let repeatedStart = Date.timeIntervalSinceReferenceDate
        for _ in 0..<50 { XCTAssertEqual(store.search(query: "house warm", sources: []).count, 10_000) }
        let repeatedSeconds = Date.timeIntervalSinceReferenceDate - repeatedStart
        let changedStart = Date.timeIntervalSinceReferenceDate
        XCTAssertEqual(store.search(query: "#kick house", sources: []).count, 10_000)
        let changedSeconds = Date.timeIntervalSinceReferenceDate - changedStart
        print(String(format: "Annotation search benchmark: 10,000 records / ~10 MB notes; first %.4f s; 50 repeated %.4f s; changed query %.4f s", firstSeconds, repeatedSeconds, changedSeconds))
        XCTAssertTrue(store.search(query: "#missing", sources: []).isEmpty)
    }

    func testClearingNotesAndTagsRemovesRecordAndUnusedTags() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = LocalAnnotationStore(fileURL: fixture.fileURL)
        XCTAssertTrue(store.save(entry: fixture.entry, notes: "削除するメモ", tags: ["old"], sources: [fixture.source]))
        XCTAssertTrue(store.save(entry: fixture.entry, notes: "", tags: [" ", "#"], sources: [fixture.source]))
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(store.allTags.isEmpty)
        XCTAssertTrue(LocalAnnotationStore(fileURL: fixture.fileURL).records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.entry.url), Data("original sample".utf8))
    }

    func testMissingFileLoadAndEmptySaveDoNotCreateFiles() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("annotation-missing-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("annotations.json")
        let store = LocalAnnotationStore(fileURL: fileURL)
        let entry = FolderEntry(url: directory.appendingPathComponent("Sample.wav"), isDirectory: false)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(store.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(store.save(entry: entry, notes: "", tags: [], sources: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCorruptLoadBlocksAllWritesEvenIfUserDismissesTheError() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = Data("{broken JSON: keep this file}".utf8)
        try original.write(to: fixture.fileURL)
        let store = LocalAnnotationStore(fileURL: fixture.fileURL)
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.records.isEmpty)
        store.error = nil
        XCTAssertFalse(store.save(entry: fixture.entry, notes: "new", tags: ["new"], sources: [fixture.source]))
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.save(entry: fixture.entry, notes: "", tags: [], sources: [fixture.source]))
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), original)
    }

    func testSaveFailureKeepsThePublishedSnapshotAndPreviouslySavedBytes() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let writable = fixture.directory.appendingPathComponent("preferences", isDirectory: true)
        let fileURL = writable.appendingPathComponent("annotations.json")
        let store = LocalAnnotationStore(fileURL: fileURL)
        XCTAssertTrue(store.save(entry: fixture.entry, notes: "保存済み", tags: ["kept"], sources: [fixture.source]))
        let previous = store.records, bytes = try Data(contentsOf: fileURL)
        let backup = fixture.directory.appendingPathComponent("preserved-preferences", isDirectory: true)
        try FileManager.default.moveItem(at: writable, to: backup)
        try Data("A regular file prevents directory creation".utf8).write(to: writable)
        XCTAssertFalse(store.save(entry: fixture.entry, notes: "保存失敗する内容", tags: ["new"], sources: [fixture.source]))
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.records, previous)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("annotations.json")), bytes)
    }

    func testInputLimitsAndInvalidSourceReferencesDoNotReplaceExistingNotes() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = LocalAnnotationStore(fileURL: fixture.fileURL)
        XCTAssertTrue(store.save(entry: fixture.entry, notes: "keep", tags: ["valid"], sources: [fixture.source]))
        let previous = store.records, bytes = try Data(contentsOf: fixture.fileURL)
        XCTAssertFalse(store.save(entry: fixture.entry, notes: String(repeating: "あ", count: 10_001), tags: [], sources: [fixture.source]))
        XCTAssertFalse(store.save(entry: fixture.entry, notes: "", tags: [String(repeating: "x", count: 65)], sources: [fixture.source]))
        XCTAssertFalse(store.save(entry: fixture.entry, notes: "", tags: (0..<33).map { "tag\($0)" }, sources: [fixture.source]))
        XCTAssertFalse(store.save(entry: fixture.entry, notes: "", tags: ["two\nlines"], sources: [fixture.source]))
        XCTAssertFalse(store.save(entry: fixture.entry, notes: "new", tags: [], sources: [fixture.source, fixture.source]))
        XCTAssertEqual(store.records, previous)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), bytes)
    }

    func testLoadedTraversalDuplicateIdentityAndBrokenReferencesAreRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let valid = LocalAnnotation(id: UUID(), savedPath: fixture.entry.url.path, isDirectory: false, sourceID: fixture.source.id, relativePath: "Drums/Kick.wav", notes: "keep", tags: ["valid"])
        var malformed: [[LocalAnnotation]] = []
        for path in ["../Other/Kick.wav", "/absolute.wav", "Drums//Kick.wav", "Drums/./Kick.wav"] {
            var record = valid; record.relativePath = path; malformed.append([record])
            XCTAssertEqual(record.entry(sources: [fixture.source]).url, fixture.entry.url, "Invalid relative paths must never escape the registered root")
        }
        var missingRelative = valid; missingRelative.relativePath = nil; malformed.append([missingRelative])
        var missingSource = valid; missingSource.sourceID = nil; malformed.append([missingSource])
        let duplicate = LocalAnnotation(id: UUID(), savedPath: valid.savedPath, isDirectory: false, sourceID: valid.sourceID, relativePath: valid.relativePath, notes: "duplicate", tags: [])
        malformed.append([valid, duplicate])
        malformed.append([valid, valid])
        for records in malformed {
            let recordJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records))
            let bytes = try JSONSerialization.data(withJSONObject: ["version": 1, "records": recordJSON], options: [.sortedKeys])
            try bytes.write(to: fixture.fileURL)
            let store = LocalAnnotationStore(fileURL: fixture.fileURL)
            XCTAssertNotNil(store.error)
            XCTAssertFalse(store.save(entry: fixture.entry, notes: "new", tags: [], sources: [fixture.source]))
            XCTAssertEqual(try Data(contentsOf: fixture.fileURL), bytes)
        }
    }

    func testFolderNotesUseExactRootAndSiblingPrefixesNeverBecomeRelativeChildren() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = LocalAnnotationStore(fileURL: fixture.fileURL)
        let folder = FolderEntry(url: fixture.source.url, isDirectory: true)
        XCTAssertTrue(store.save(entry: folder, notes: "フォルダのメモ", tags: ["folder"], sources: [fixture.source]))
        XCTAssertEqual(store.annotation(for: folder, sources: [fixture.source])?.relativePath, "")
        let sibling = FolderEntry(url: URL(fileURLWithPath: fixture.source.savedPath + " Other/Kick.wav"), isDirectory: false)
        XCTAssertTrue(store.save(entry: sibling, notes: "兄弟パス", tags: ["outside"], sources: [fixture.source]))
        XCTAssertNil(store.annotation(for: sibling, sources: [fixture.source])?.sourceID)
        let nested = FolderSource(id: UUID(), name: "Drums", savedPath: fixture.source.url.appendingPathComponent("Drums").path, bookmark: nil)
        XCTAssertTrue(store.save(entry: fixture.entry, notes: "nested", tags: [], sources: [fixture.source, nested]))
        XCTAssertEqual(store.annotation(for: fixture.entry, sources: [fixture.source, nested])?.sourceID, nested.id)
        XCTAssertEqual(store.annotation(for: fixture.entry, sources: [fixture.source, nested])?.relativePath, "Kick.wav")
    }

    private func makeFixture() throws -> (directory: URL, fileURL: URL, source: FolderSource, entry: FolderEntry) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("local-annotation-tests-\(UUID().uuidString)", isDirectory: true)
        let root = directory.appendingPathComponent("NAS", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Drums", isDirectory: true), withIntermediateDirectories: true)
        let entry = FolderEntry(url: root.appendingPathComponent("Drums/Kick.wav"), isDirectory: false)
        try Data("original sample".utf8).write(to: entry.url)
        return (directory, directory.appendingPathComponent("annotations.json"), FolderSource(id: UUID(), name: "NAS", savedPath: root.path, bookmark: nil), entry)
    }
}
