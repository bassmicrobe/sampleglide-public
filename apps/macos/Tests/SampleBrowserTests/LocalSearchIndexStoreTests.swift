import XCTest
import SQLite3
@testable import SampleBrowser

@MainActor final class LocalSearchIndexStoreTests: XCTestCase {
    func testDirectoryCheckpointResumesAfterReopeningWithoutRescanningCompletedRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await first.configureSources([fixture.source])
        let root = try await work(first)
        let folder = fixture.item("Drums", directory: true)
        try await first.applyDirectory(root, items: [folder], childDirectories: [folder.path, folder.path])

        let restored = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await restored.configureSources([fixture.source])
        let resumed = try await work(restored)
        XCTAssertEqual(resumed.path, folder.path)
        XCTAssertEqual(resumed.scanID, root.scanID)
        let status = try await restored.status()
        XCTAssertEqual(status.first?.pendingDirectoryCount, 1)
        XCTAssertEqual(status.first?.processedDirectoryCount, 1)
        let child = fixture.item("Drums/Deep Kick.wav")
        try await restored.applyDirectory(resumed, items: [child], childDirectories: [])
        let page = try await restored.search(query: "deep kick")
        XCTAssertEqual(page.items.map(\.path), [child.path])
        let emptyQueue = try await restored.nextDirectory()
        XCTAssertNil(emptyQueue)
        let completed = try await restored.status()
        XCTAssertNotNil(completed.first?.lastCompletedAt)
        XCTAssertEqual(completed.first?.processedDirectoryCount, 2)
    }

    func testProcessedDirectoryCountTracksFailuresAndResetsOnlyForNewScan() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await store.configureSources([fixture.source])
        let initial = try await store.status()
        XCTAssertEqual(initial.first?.processedDirectoryCount, 0)
        let root = try await work(store)
        let folder = fixture.item("Drums", directory: true)
        try await store.applyDirectory(root, items: [folder], childDirectories: [folder.path])
        try await store.applyDirectory(root, items: [folder], childDirectories: [folder.path])
        let once = try await store.status()
        XCTAssertEqual(once.first?.processedDirectoryCount, 1, "Replayed work must not increment the counter twice")
        try await store.requestRescan()
        let active = try await store.status()
        XCTAssertEqual(active.first?.processedDirectoryCount, 1, "Requesting a scan must preserve an active checkpoint")
        let child = try await work(store)
        let firstFailureAt = Date(timeIntervalSince1970: 1_000)
        try await store.failDirectory(child, message: "Permission denied", now: firstFailureAt)
        try await store.failDirectory(child, message: "Repeated callback", now: firstFailureAt)
        try await store.applyDirectory(child, items: [fixture.item("Drums/stale.wav")], childDirectories: [])
        let retrying = try await store.status()
        XCTAssertEqual(retrying.first?.processedDirectoryCount, 1, "Retrying a checkpoint does not consume it")
        XCTAssertEqual(retrying.first?.pendingDirectoryCount, 1)
        XCTAssertEqual(retrying.first?.error, "\(child.path): Permission denied", "Stale callbacks must not overwrite the current attempt")
        let staleResults = try await store.search(query: "stale")
        XCTAssertTrue(staleResults.items.isEmpty)
        let retry = try await work(store, now: firstFailureAt.addingTimeInterval(2))
        XCTAssertEqual(retry.failureCount, 1)
        try await exhaustFailure(store, work: retry, message: "Permission denied", now: firstFailureAt.addingTimeInterval(2))
        let failed = try await store.status()
        XCTAssertEqual(failed.first?.processedDirectoryCount, 2, "A failed directory is still a processed checkpoint")
        XCTAssertEqual(failed.first?.pendingDirectoryCount, 0)
        let restored = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await restored.configureSources([fixture.source])
        let reopened = try await restored.status()
        XCTAssertEqual(reopened.first?.processedDirectoryCount, 2)
        try await restored.requestRescan()
        let newScan = try await restored.status()
        XCTAssertEqual(newScan.first?.processedDirectoryCount, 0)
        XCTAssertEqual(newScan.first?.pendingDirectoryCount, 1)
        try await restored.applyDirectory(child, items: [], childDirectories: [])
        let obsolete = try await restored.status()
        XCTAssertEqual(obsolete.first?.processedDirectoryCount, 0)
        try await restored.applyDirectory(try await work(restored), items: [], childDirectories: [])
        let completed = try await restored.status()
        XCTAssertEqual(completed.first?.processedDirectoryCount, 1)
    }

    func testProgressStatusCachesItemCountsWhileQueueAndCheckpointCountsStayFresh() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await store.configureSources([fixture.source])
        let now = Date(timeIntervalSince1970: 1_000)
        let initial = try await store.status(refreshIndexedCounts: false, now: now)
        XCTAssertEqual(initial.first?.indexedCount, 0)
        let folder = fixture.item("Drums", directory: true)
        try await store.applyDirectory(try await work(store), items: [folder, fixture.item("Root.wav")], childDirectories: [folder.path])
        let cached = try await store.status(refreshIndexedCounts: false, now: now.addingTimeInterval(1))
        XCTAssertEqual(cached.first?.indexedCount, 0, "Frequent progress reads must not recount all memberships")
        XCTAssertEqual(cached.first?.processedDirectoryCount, 1)
        XCTAssertEqual(cached.first?.pendingDirectoryCount, 1)
        let periodic = try await store.status(refreshIndexedCounts: false, now: now.addingTimeInterval(5))
        XCTAssertEqual(periodic.first?.indexedCount, 2, "An active scan refreshes counts within a bounded interval")

        let nested = fixture.item("Drums/Nested", directory: true)
        try await store.applyDirectory(try await work(store), items: [nested, fixture.item("Drums/Kick.wav")], childDirectories: [nested.path])
        let fresh = try await store.status(now: now.addingTimeInterval(6))
        XCTAssertEqual(fresh.first?.indexedCount, 4, "Explicit status reads remain fresh")
        try await store.applyDirectory(try await work(store), items: [fixture.item("Drums/Nested/Snare.wav")], childDirectories: [])
        let completed = try await store.status(refreshIndexedCounts: false, now: now.addingTimeInterval(7))
        XCTAssertEqual(completed.first?.indexedCount, 5, "Finalization immediately invalidates the cached count")
        XCTAssertEqual(completed.first?.pendingDirectoryCount, 0)
        XCTAssertEqual(completed.first?.processedDirectoryCount, 3)

        try await store.configureSources([])
        let removed = try await store.status(refreshIndexedCounts: false, now: now.addingTimeInterval(8))
        XCTAssertTrue(removed.isEmpty)
    }

    func testTerminalFailureRefreshesCachedCountWithoutMarkingScanComplete() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await store.configureSources([fixture.source])
        let now = Date(timeIntervalSince1970: 1_000)
        _ = try await store.status(refreshIndexedCounts: false, now: now)
        let folder = fixture.item("Locked", directory: true)
        try await store.applyDirectory(try await work(store), items: [folder, fixture.item("Keep.wav")], childDirectories: [folder.path])
        try await exhaustFailure(store, work: try await work(store), message: "Offline", now: now)
        let ended = try await store.status(refreshIndexedCounts: false, now: now.addingTimeInterval(1))
        XCTAssertEqual(ended.first?.indexedCount, 2)
        XCTAssertEqual(ended.first?.pendingDirectoryCount, 0)
        XCTAssertNotNil(ended.first?.error)
        XCTAssertNil(ended.first?.lastCompletedAt)
    }

    func testTransientRetryRecoversInSameScanAndPrunesOnlyAfterSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await store.configureSources([fixture.source])
        try await store.applyDirectory(try await work(store), items: [fixture.item("old.wav")], childDirectories: [])
        let before = try await store.status()
        try await store.requestRescan()
        let root = try await work(store)
        let now = Date(timeIntervalSince1970: 1_000)
        try await store.failDirectory(root, message: "Temporary NAS timeout", now: now)
        let tooSoon = try await store.nextDirectory(now: now.addingTimeInterval(1.999))
        XCTAssertNil(tooSoon)
        let wakeAt = try await store.nextRetryDate()
        XCTAssertEqual(wakeAt, now.addingTimeInterval(2))
        let waiting = try await store.status()
        XCTAssertEqual(waiting.first?.indexedCount, 1)
        XCTAssertEqual(waiting.first?.processedDirectoryCount, 0)
        XCTAssertEqual(waiting.first?.lastCompletedAt, before.first?.lastCompletedAt)
        XCTAssertEqual(waiting.first?.error, "/library: Temporary NAS timeout")
        try await store.requestRescan()
        let retry = try await work(store, now: now.addingTimeInterval(2))
        XCTAssertEqual(retry.scanID, root.scanID)
        XCTAssertEqual(retry.failureCount, 1)
        try await store.applyDirectory(retry, items: [fixture.item("new.wav")], childDirectories: [])
        let complete = try await store.status()
        XCTAssertEqual(complete.first?.processedDirectoryCount, 1)
        XCTAssertEqual(complete.first?.pendingDirectoryCount, 0)
        XCTAssertNil(complete.first?.error)
        XCTAssertNotNil(complete.first?.lastCompletedAt)
        let noRetry = try await store.nextRetryDate()
        XCTAssertNil(noRetry)
        let results = try await store.search(query: "wav")
        XCTAssertEqual(results.items.map(\.name), ["new.wav"])
    }

    func testRetryPersistsAcrossRestartAndDoesNotBlockReadyDirectories() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await store.configureSources([fixture.source])
        let first = fixture.item("First", directory: true)
        let second = fixture.item("Second", directory: true)
        try await store.applyDirectory(try await work(store), items: [first, second], childDirectories: [first.path, second.path])
        let failed = try await work(store)
        let now = Date(timeIntervalSince1970: 1_000)
        try await store.failDirectory(failed, message: "Temporary read failure", now: now)
        let ready = try await work(store, now: now)
        XCTAssertNotEqual(ready.path, failed.path)
        try await store.applyDirectory(ready, items: [], childDirectories: [])

        let restored = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await restored.configureSources([fixture.source])
        try await restored.requestRescan()
        let tooSoon = try await restored.nextDirectory(now: now)
        XCTAssertNil(tooSoon)
        let retryAt = try await restored.nextRetryDate()
        XCTAssertEqual(retryAt, now.addingTimeInterval(2))
        let waiting = try await restored.status()
        XCTAssertEqual(waiting.first?.processedDirectoryCount, 2)
        XCTAssertEqual(waiting.first?.pendingDirectoryCount, 1)
        XCTAssertEqual(waiting.first?.error, "\(failed.path): Temporary read failure")
        let retry = try await work(restored, now: now.addingTimeInterval(2))
        XCTAssertEqual(retry.path, failed.path)
        XCTAssertEqual(retry.scanID, failed.scanID)
        XCTAssertEqual(retry.failureCount, 1)
        try await restored.failDirectory(retry, message: "Still unavailable", now: now.addingTimeInterval(2))
        let secondRetryAt = try await restored.nextRetryDate()
        XCTAssertEqual(secondRetryAt, now.addingTimeInterval(12))
        let earlySecondRetry = try await restored.nextDirectory(now: now.addingTimeInterval(11.999))
        XCTAssertNil(earlySecondRetry)
        let finalAttempt = try await work(restored, now: now.addingTimeInterval(12))
        XCTAssertEqual(finalAttempt.failureCount, 2)
        try await restored.failDirectory(finalAttempt, message: "Offline", now: now.addingTimeInterval(12))
        try await restored.failDirectory(finalAttempt, message: "Duplicate terminal callback", now: now.addingTimeInterval(12))
        let exhausted = try await restored.status()
        XCTAssertEqual(exhausted.first?.processedDirectoryCount, 3)
        XCTAssertEqual(exhausted.first?.pendingDirectoryCount, 0)
        XCTAssertNil(exhausted.first?.lastCompletedAt)
        XCTAssertEqual(exhausted.first?.error, "\(failed.path): Offline")
        let emptyQueue = try await restored.nextDirectory(now: now.addingTimeInterval(100))
        let noRetry = try await restored.nextRetryDate()
        XCTAssertNil(emptyQueue)
        XCTAssertNil(noRetry)
    }

    func testVersionTwoMigrationKeepsLegacyErrorsAndExistingGeneration() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try createLegacyDatabase(fixture, rows: """
            ALTER TABLE sources ADD COLUMN processed_directory_count INTEGER NOT NULL DEFAULT 0;
            UPDATE sources SET processed_directory_count = 37, had_errors = 1, error = 'Legacy failure';
            INSERT INTO items VALUES (1, '/library/Keep.wav', 'Keep.wav', 0, 'keep.wav', '');
            INSERT INTO source_items VALUES ('\(fixture.source.id.uuidString)', 1, 6);
            INSERT INTO pending_directories(source_id, path, generation)
                VALUES ('\(fixture.source.id.uuidString)', '/library', 7);
            """, version: 2)
        let migrated = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        XCTAssertEqual(try schemaVersion(fixture.databaseURL), 3)
        let root = try await work(migrated)
        XCTAssertEqual(root.scanID, 7)
        XCTAssertEqual(root.failureCount, 0)
        let now = Date(timeIntervalSince1970: 1_000)
        try await migrated.failDirectory(root, message: "New temporary failure", now: now)
        let retrying = try await migrated.status()
        XCTAssertEqual(retrying.first?.error, "Legacy failure", "A temporary retry cannot hide a discarded legacy failure")
        let retry = try await work(migrated, now: now.addingTimeInterval(2))
        try await migrated.applyDirectory(retry, items: [], childDirectories: [])
        let complete = try await migrated.status()
        XCTAssertEqual(complete.first?.processedDirectoryCount, 38)
        XCTAssertEqual(complete.first?.pendingDirectoryCount, 0)
        XCTAssertEqual(complete.first?.error, "Legacy failure")
        XCTAssertEqual(complete.first?.lastCompletedAt, Date(timeIntervalSince1970: 1_000))
        let kept = try await migrated.search(query: "keep")
        XCTAssertEqual(kept.items.count, 1, "Legacy failed paths are unknown, so migration cannot safely enable stale pruning")
    }

    func testVersionOneMigrationRecoversProgressAndResumesTheExistingGeneration() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try createLegacyDatabase(fixture, rows: """
            INSERT INTO items VALUES (1, '/library/Finished', 'Finished', 1, 'finished', '');
            INSERT INTO items VALUES (2, '/library/Pending', 'Pending', 1, 'pending', '');
            INSERT INTO items VALUES (3, '/library/Old', 'Old', 1, 'old', '');
            INSERT INTO items VALUES (4, '/library/Keep.wav', 'Keep.wav', 0, 'keep.wav', '');
            INSERT INTO source_items VALUES ('\(fixture.source.id.uuidString)', 1, 7);
            INSERT INTO source_items VALUES ('\(fixture.source.id.uuidString)', 2, 7);
            INSERT INTO source_items VALUES ('\(fixture.source.id.uuidString)', 3, 6);
            INSERT INTO source_items VALUES ('\(fixture.source.id.uuidString)', 4, 7);
            INSERT INTO pending_directories(source_id, path, generation)
                VALUES ('\(fixture.source.id.uuidString)', '/library/Pending', 7);
            """)
        let migrated = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        let progress = try await migrated.status()
        XCTAssertEqual(progress.first?.processedDirectoryCount, 2, "Two current directories plus the root, minus one pending directory")
        XCTAssertEqual(progress.first?.indexedCount, 4, "Migration must preserve the existing index")
        XCTAssertEqual(progress.first?.lastCompletedAt, Date(timeIntervalSince1970: 1_000))
        let pending = try await work(migrated)
        XCTAssertEqual(pending.scanID, 7)
        XCTAssertEqual(pending.path, "/library/Pending")
        try await migrated.applyDirectory(pending, items: [], childDirectories: [])
        let completed = try await migrated.status()
        XCTAssertEqual(completed.first?.processedDirectoryCount, 3)
        let reopened = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        let preserved = try await reopened.status()
        XCTAssertEqual(preserved.first?.processedDirectoryCount, 3)
        try await reopened.requestRescan()
        let nextGeneration = try await work(reopened)
        XCTAssertGreaterThan(nextGeneration.scanID, 7, "A legacy database without index_state must retain monotonic generations")
        let reset = try await reopened.status()
        XCTAssertEqual(reset.first?.processedDirectoryCount, 0)
    }

    func testLegacyProgressBackfillClampsToZeroWhenPendingQueueExceedsKnownDirectories() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try createLegacyDatabase(fixture, rows: """
            INSERT INTO pending_directories(source_id, path, generation) VALUES
                ('\(fixture.source.id.uuidString)', '/library', 7),
                ('\(fixture.source.id.uuidString)', '/library/First', 7),
                ('\(fixture.source.id.uuidString)', '/library/Second', 7);
            """)
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        let status = try await store.status()
        XCTAssertEqual(status.first?.processedDirectoryCount, 0)
        XCTAssertEqual(status.first?.pendingDirectoryCount, 3)
    }

    func testExistingProcessedCounterIsNotRecomputedWhenOpeningOrReopening() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try createLegacyDatabase(fixture, rows: """
            ALTER TABLE sources ADD COLUMN processed_directory_count INTEGER NOT NULL DEFAULT 0;
            UPDATE sources SET processed_directory_count = 37;
            INSERT INTO pending_directories(source_id, path, generation)
                VALUES ('\(fixture.source.id.uuidString)', '/library', 7);
            """)
        let first = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        let initial = try await first.status()
        XCTAssertEqual(initial.first?.processedDirectoryCount, 37)
        let second = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        let reopened = try await second.status()
        XCTAssertEqual(reopened.first?.processedDirectoryCount, 37)
    }

    func testSuccessfulRescanPrunesStaleFilesOnlyAfterEveryDirectoryCompletes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await store.configureSources([fixture.source])
        let folder = fixture.item("Drums", directory: true)
        try await store.applyDirectory(try await work(store), items: [folder, fixture.item("old.wav")], childDirectories: [folder.path])
        try await store.applyDirectory(try await work(store), items: [fixture.item("Drums/stale.wav")], childDirectories: [])

        try await store.requestRescan()
        try await store.applyDirectory(try await work(store), items: [folder, fixture.item("new.wav")], childDirectories: [folder.path])
        let partial = try await store.search(query: "wav")
        XCTAssertEqual(Set(partial.items.map(\.name)), ["old.wav", "stale.wav", "new.wav"])
        try await store.applyDirectory(try await work(store), items: [], childDirectories: [])
        let complete = try await store.search(query: "wav")
        XCTAssertEqual(complete.items.map(\.name), ["new.wav"])
    }

    func testOfflineFailureRetainsLastSuccessfulIndexAndCompletionTimeAcrossRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await store.configureSources([fixture.source])
        try await store.applyDirectory(try await work(store), items: [fixture.item("keep.wav")], childDirectories: [])
        let before = try await store.status()
        try await store.requestRescan()
        try await exhaustFailure(store, work: try await work(store), message: "NAS is offline")

        let restored = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        let page = try await restored.search(query: "keep")
        XCTAssertEqual(page.items.count, 1)
        let status = try await restored.status()
        XCTAssertEqual(status.first?.lastCompletedAt, before.first?.lastCompletedAt)
        XCTAssertEqual(status.first?.pendingDirectoryCount, 0)
        XCTAssertEqual(status.first?.error, "/library: NAS is offline")
    }

    func testAnySubtreeFailurePreventsGlobalStalePruningUntilNextSuccessfulScan() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await store.configureSources([fixture.source])
        let folder = fixture.item("Locked", directory: true)
        try await store.applyDirectory(try await work(store), items: [folder, fixture.item("previous.wav")], childDirectories: [folder.path])
        try await store.applyDirectory(try await work(store), items: [fixture.item("Locked/important.wav")], childDirectories: [])
        try await store.requestRescan()
        try await store.applyDirectory(try await work(store), items: [folder, fixture.item("added.wav")], childDirectories: [folder.path])
        try await exhaustFailure(store, work: try await work(store), message: "Permission denied")
        let partial = try await store.search(query: "wav")
        XCTAssertEqual(Set(partial.items.map(\.name)), ["previous.wav", "important.wav", "added.wav"])

        try await store.requestRescan()
        try await store.applyDirectory(try await work(store), items: [fixture.item("added.wav")], childDirectories: [])
        let recovered = try await store.search(query: "wav")
        XCTAssertEqual(recovered.items.map(\.name), ["added.wav"])
        let status = try await store.status()
        XCTAssertNil(status.first?.error)
    }

    func testRemovingOrRelocatingSourceHidesOldPathsAndRejectsStaleWork() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await store.configureSources([fixture.source])
        let stale = try await work(store)
        let moved = LocalIndexSource(id: fixture.source.id, path: "/other", name: "Moved NAS")
        try await store.configureSources([moved])
        try await store.applyDirectory(stale, items: [fixture.item("stale.wav")], childDirectories: [])
        let afterStale = try await store.search(query: "stale")
        XCTAssertTrue(afterStale.items.isEmpty)
        let movedWork = try await work(store)
        XCTAssertEqual(movedWork.sourcePath, "/other")
        try await store.applyDirectory(movedWork, items: [LocalIndexItem(path: "/other/current.wav", name: "current.wav", isDirectory: false, sourceID: moved.id)], childDirectories: [])
        let renamed = LocalIndexSource(id: moved.id, path: moved.path, name: "Renamed NAS")
        try await store.configureSources([renamed])
        let found = try await store.search(query: "current")
        XCTAssertEqual(found.items.first?.sourceName, "Renamed NAS")
        try await store.configureSources([])
        let removed = try await store.search(query: "")
        XCTAssertTrue(removed.items.isEmpty)
        let statuses = try await store.status()
        XCTAssertTrue(statuses.isEmpty)
    }

    func testOverlappingSourcesReturnOnePathAndRemovingOneSourcePreservesOtherMembership() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        let nested = LocalIndexSource(id: UUID(), path: "/library/Drums", name: "Drums")
        try await store.configureSources([fixture.source, nested])
        let folder = fixture.item("Drums", directory: true)
        try await store.applyDirectory(try await work(store), items: [folder], childDirectories: [folder.path])
        let item = fixture.item("Drums/shared.wav")
        try await store.applyDirectory(try await work(store), items: [LocalIndexItem(path: item.path, name: item.name, isDirectory: false, sourceID: nested.id)], childDirectories: [])
        try await store.applyDirectory(try await work(store), items: [item], childDirectories: [])
        let found = try await store.search(query: "shared")
        XCTAssertEqual(found.items.count, 1)
        try await store.configureSources([nested])
        let surviving = try await store.search(query: "shared")
        XCTAssertEqual(surviving.items.count, 1)
        XCTAssertEqual(surviving.items.first?.sourceID, nested.id)
    }

    func testRemovedAndReaddedSameSourceNeverReusesInterruptedGeneration() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await store.configureSources([fixture.source])
        let obsolete = try await work(store)
        try await store.configureSources([])
        try await store.configureSources([fixture.source])
        let current = try await work(store)
        XCTAssertNotEqual(current.scanID, obsolete.scanID)
        try await store.applyDirectory(obsolete, items: [fixture.item("obsolete.wav")], childDirectories: [])
        let result = try await store.search(query: "obsolete")
        XCTAssertTrue(result.items.isEmpty)
        let stillPending = try await store.nextDirectory()
        XCTAssertEqual(stillPending, current)
    }

    func testUnicodeSubstringAndQueriesSpanPathNotesAndTagsWithHashtagRestrictedToTags() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await store.configureSources([fixture.source])
        let item = fixture.item("Café 東京低音.wav")
        try await store.replaceAnnotations([LocalIndexAnnotation(path: item.path, notes: "柔らかいキックと広い空間", tags: ["House", "Énergie", "深い"] )])
        try await store.applyDirectory(try await work(store), items: [item, fixture.item("House.wav")], childDirectories: [])
        for query in ["CAFE 東京低", "東京", "柔らかい #ENERGIE", "library #house 空間", "ＣＡＦＥ #深"] {
            let page = try await store.search(query: query)
            XCTAssertEqual(page.items.map(\.path), [item.path], query)
        }
        let hashtag = try await store.search(query: "#house")
        XCTAssertEqual(hashtag.items.map(\.path), [item.path])
        XCTAssertEqual(hashtag.items.first?.notes, "柔らかいキックと広い空間")
        XCTAssertEqual(hashtag.items.first?.tags, ["House", "Énergie", "深い"])
        let impossible = try await store.search(query: "cafe #missing")
        XCTAssertTrue(impossible.items.isEmpty)
    }

    func testPercentUnderscoreAndQuotedPhraseQueriesAreLiteral() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await store.configureSources([fixture.source])
        try await store.applyDirectory(try await work(store), items: [
            fixture.item("100% a_b Warm Pad.wav"), fixture.item("1000 acb Warm Huge Pad.wav")
        ], childDirectories: [])
        for query in ["100%", "a_b", "\"warm pad\"", "% _"] {
            let page = try await store.search(query: query)
            XCTAssertEqual(page.items.map(\.name), ["100% a_b Warm Pad.wav"], query)
        }
        let injected = try await store.search(query: "' OR 1=1 --")
        XCTAssertTrue(injected.items.isEmpty)
    }

    func testAnnotationEditsAndRemovalUpdateSearchWithoutRecrawling() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await store.configureSources([fixture.source])
        let item = fixture.item("Kick.wav")
        try await store.applyDirectory(try await work(store), items: [item], childDirectories: [])
        try await store.replaceAnnotations([LocalIndexAnnotation(path: item.path, notes: "使いやすい", tags: ["first"] )])
        let first = try await store.search(query: "使いやすい #first")
        XCTAssertEqual(first.items.count, 1)
        try await store.replaceAnnotations([LocalIndexAnnotation(path: item.path, notes: "軽い", tags: ["second"] )])
        let previous = try await store.search(query: "#first")
        let changed = try await store.search(query: "軽い #second")
        XCTAssertTrue(previous.items.isEmpty)
        XCTAssertEqual(changed.items.count, 1)
        try await store.replaceAnnotations([])
        let cleared = try await store.search(query: "#second")
        let filename = try await store.search(query: "kick")
        XCTAssertTrue(cleared.items.isEmpty)
        XCTAssertEqual(filename.items.count, 1)
        XCTAssertEqual(filename.items.first?.notes, "")
        XCTAssertEqual(filename.items.first?.tags, [])
    }

    func testPaginationIsBoundedAndCanReachAllMatchesBeyondFirstThousand() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await store.configureSources([fixture.source])
        let items = (0..<1_205).map { fixture.item(String(format: "Kick-%04d.wav", $0)) }
        try await store.applyDirectory(try await work(store), items: items, childDirectories: [])
        var paths: [String] = []
        var hasMore = true
        while hasMore {
            let page = try await store.search(query: "kick", limit: 200, offset: paths.count)
            XCTAssertLessThanOrEqual(page.items.count, 200)
            XCTAssertEqual(page.offset, paths.count)
            paths.append(contentsOf: page.items.map(\.path))
            hasMore = page.hasMore
        }
        XCTAssertEqual(paths.count, 1_205)
        XCTAssertEqual(Set(paths).count, 1_205)
        XCTAssertEqual(paths.last, items.last?.path)
        let bounded = try await store.search(query: "kick", limit: Int.max, offset: -1)
        XCTAssertEqual(bounded.items.count, 500)
        XCTAssertTrue(bounded.hasMore)
        XCTAssertEqual(bounded.offset, 0)
    }

    func testPagedSearchHydratesNotesAndTagsWithoutDuplicatingOverlappingSources() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        let nested = LocalIndexSource(id: UUID(), path: "/library/Drums", name: "Nested")
        try await store.configureSources([fixture.source, nested])
        let folder = fixture.item("Drums", directory: true)
        try await store.applyDirectory(try await work(store), items: [folder], childDirectories: [folder.path])
        let items = (0..<405).map { fixture.item(String(format: "Drums/Kick-%04d-日本語.wav", $0)) }
        while let work = try await store.nextDirectory() {
            let memberships = items.map { LocalIndexItem(path: $0.path, name: $0.name, isDirectory: false, sourceID: work.sourceID) }
            try await store.applyDirectory(work, items: memberships, childDirectories: [])
        }
        let annotated = items[250]
        try await store.replaceAnnotations([LocalIndexAnnotation(path: annotated.path, notes: "柔らかい音", tags: ["Warm", "打楽器"])])
        let first = try await store.search(query: "kick", limit: 200)
        let second = try await store.search(query: "kick", limit: 200, offset: 200)
        XCTAssertEqual(first.items.count, 200)
        XCTAssertEqual(second.items.count, 200)
        XCTAssertEqual(Set((first.items + second.items).map(\.path)).count, 400)
        let hit = try XCTUnwrap(second.items.first { $0.path == annotated.path })
        XCTAssertEqual(hit.notes, "柔らかい音")
        XCTAssertEqual(hit.tags, ["Warm", "打楽器"])
        let chosen = [fixture.source, nested].sorted { $0.id.uuidString < $1.id.uuidString }[0]
        XCTAssertEqual(hit.sourceID, chosen.id)
        XCTAssertEqual(hit.sourceName, chosen.name)
        for query in ["0250", "日本語 #warm", "柔らかい #打楽器"] {
            let rare = try await store.search(query: query)
            XCTAssertEqual(rare.items.map(\.path), [annotated.path], query)
        }
    }

    func testRequestRescanDoesNotDiscardPendingSubtrees() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await store.configureSources([fixture.source])
        let root = try await work(store)
        let child = fixture.item("Deep", directory: true)
        try await store.applyDirectory(root, items: [child], childDirectories: [child.path])
        try await store.requestRescan()
        let pending = try await work(store)
        XCTAssertEqual(pending.path, child.path)
        XCTAssertEqual(pending.scanID, root.scanID)
    }

    func testCancelledSearchExitsWithoutChangingDurableQueue() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await store.configureSources([fixture.source])
        let before = try await store.nextDirectory()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.search(query: "kick")
        }
        do {
            _ = try await cancelled.value
            XCTFail("Search should honor cancellation")
        } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        let after = try await store.nextDirectory()
        XCTAssertEqual(after, before)
    }

    func testLargeDirectoryAllowsSearchBetweenBatchesAndCancellationResumesItsCheckpoint() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await store.configureSources([fixture.source])
        let root = try await work(store)
        let items = (0..<20_000).map { fixture.item(String(format: "Kick-%05d.wav", $0)) }
        let crawl = Task { try await store.applyDirectory(root, items: items, childDirectories: []) }
        var partialCount = 0
        while partialCount == 0 {
            await Task.yield()
            partialCount = try await store.status().first?.indexedCount ?? 0
        }
        let duringCrawl = try await store.search(query: "kick", limit: 5)
        XCTAssertEqual(duringCrawl.items.count, 5)
        crawl.cancel()
        do { try await crawl.value } catch is CancellationError {}
        let pending = try await store.nextDirectory()
        XCTAssertEqual(pending, root)
        let interrupted = try await store.status()
        XCTAssertLessThan(interrupted.first?.indexedCount ?? items.count, items.count)
        XCTAssertEqual(interrupted.first?.processedDirectoryCount, 0, "Committed chunks do not consume the directory checkpoint")
        let restored = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        let resumed = try await work(restored)
        XCTAssertEqual(resumed, root)
        try await restored.applyDirectory(resumed, items: items, childDirectories: [])
        let completed = try await restored.status()
        XCTAssertEqual(completed.first?.indexedCount, items.count)
        XCTAssertEqual(completed.first?.pendingDirectoryCount, 0)
        XCTAssertEqual(completed.first?.processedDirectoryCount, 1, "Resuming partial chunks must count the directory once")
    }

    func testOutsideSourceOrParentTraversalCannotBeInserted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try LocalSearchIndexStore(databaseURL: fixture.databaseURL)
        try await store.configureSources([fixture.source])
        let root = try await work(store)
        do {
            try await store.applyDirectory(root, items: [fixture.item("../outside.wav")], childDirectories: [])
            XCTFail("Parent traversal should fail")
        } catch {}
        do {
            try await store.applyDirectory(root, items: [], childDirectories: ["/unrelated"])
            XCTFail("An unrelated root should fail")
        } catch {}
        let pending = try await store.nextDirectory()
        XCTAssertEqual(pending, root, "Invalid batches must not remove their checkpoint")
    }

    private func work(_ store: LocalSearchIndexStore, now: Date = Date()) async throws -> LocalIndexDirectoryWork {
        let result = try await store.nextDirectory(now: now)
        return try XCTUnwrap(result)
    }

    private func exhaustFailure(_ store: LocalSearchIndexStore, work initial: LocalIndexDirectoryWork,
                                message: String, now initialDate: Date = Date(timeIntervalSince1970: 1_000)) async throws {
        var current = initial
        var now = initialDate
        while true {
            try await store.failDirectory(current, message: message, now: now)
            guard current.failureCount < 2 else { return }
            now = now.addingTimeInterval(current.failureCount == 0 ? 2 : 10)
            current = try await work(store, now: now)
            XCTAssertEqual(current.path, initial.path)
        }
    }

    private func schemaVersion(_ url: URL) throws -> Int32 {
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let connection else {
            throw NSError(domain: "LocalSearchIndexStoreTests", code: 3)
        }
        defer { sqlite3_close_v2(connection) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "LocalSearchIndexStoreTests", code: 4)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw NSError(domain: "LocalSearchIndexStoreTests", code: 5) }
        return sqlite3_column_int(statement, 0)
    }

    private func createLegacyDatabase(_ fixture: Fixture, rows: String, version: Int = 1) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(fixture.databaseURL.path, &connection) == SQLITE_OK, let connection else {
            throw NSError(domain: "LocalSearchIndexStoreTests", code: 1)
        }
        defer { sqlite3_close_v2(connection) }
        let sql = """
            CREATE TABLE sources(
                id TEXT PRIMARY KEY, path TEXT NOT NULL, name TEXT NOT NULL, generation INTEGER NOT NULL,
                had_errors INTEGER NOT NULL DEFAULT 0, last_completed_at REAL, error TEXT
            );
            CREATE TABLE items(
                id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL, is_directory INTEGER NOT NULL,
                searchable TEXT NOT NULL, folded_tags TEXT NOT NULL
            );
            CREATE TABLE source_items(
                source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE, seen_generation INTEGER NOT NULL,
                PRIMARY KEY(source_id, item_id)
            );
            CREATE TABLE pending_directories(
                id INTEGER PRIMARY KEY AUTOINCREMENT, source_id TEXT NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
                path TEXT NOT NULL, generation INTEGER NOT NULL, UNIQUE(source_id, path, generation)
            );
            INSERT INTO sources(id, path, name, generation, last_completed_at)
                VALUES ('\(fixture.source.id.uuidString)', '/library', 'Sample Library', 7, 1000);
            \(rows)
            PRAGMA user_version = \(version);
            """
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "LocalSearchIndexStoreTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(connection))])
        }
    }

    private struct Fixture {
        let directory: URL
        let databaseURL: URL
        let source: LocalIndexSource

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("sampleglide-index-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            databaseURL = directory.appendingPathComponent("index.sqlite")
            source = LocalIndexSource(id: UUID(), path: "/library", name: "Sample Library")
        }

        func item(_ relativePath: String, directory: Bool = false) -> LocalIndexItem {
            LocalIndexItem(path: source.path + "/" + relativePath, name: (relativePath as NSString).lastPathComponent,
                           isDirectory: directory, sourceID: source.id)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
