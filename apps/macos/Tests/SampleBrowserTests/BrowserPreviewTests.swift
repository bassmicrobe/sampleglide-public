import XCTest
import AVFoundation
@testable import SampleBrowser

private actor DeferredPreviewValue<Value: Sendable> {
    private var pending: [UUID: CheckedContinuation<Value, Error>] = [:]
    func value(for id: UUID) async throws -> Value {
        try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    func contains(_ id: UUID) -> Bool { pending[id] != nil }
    func finish(_ id: UUID, with result: Result<Value, Error>) { pending.removeValue(forKey: id)?.resume(with: result) }
}

@MainActor final class BrowserPreviewTests: XCTestCase {
    func testDisabledAutoPreviewLoadsWaveformWithoutStartingPlayback() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let sample = detail(name: "Remote kick.wav", bpm: 125)
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in sample }, download: { _, _ in url }, load: { try AudioInfo.load($0) }
        ), preferences: preferences())
        defer { model.clearSelectedAudio() }
        model.selectedID = sample.sample.id
        XCTAssertTrue(model.loadingAudio)
        XCTAssertNil(model.audio)
        try await eventually { model.audio != nil }
        XCTAssertEqual(model.audioDisplayName, "Remote kick.wav")
        XCTAssertEqual(model.selection.endFrame, 1024)
        XCTAssertEqual(model.selection.sourceBPM, 125)
        XCTAssertFalse(model.audio!.peaks[0].isEmpty)
        XCTAssertFalse(model.preview.isPlaying, "Selecting a sample displays its waveform silently")
        XCTAssertFalse(model.loadingAudio)
        XCTAssertNil(model.previewError)
        XCTAssertNil(model.error)
    }

    func testLateRemoteDetailCannotReplaceLocalFileOrDisplayAnAlert() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let remote = detail(name: "Remote.wav")
        let deferred = DeferredPreviewValue<SampleDetail>()
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { try await deferred.value(for: $0) }, download: { _, _ in url }, load: { try AudioInfo.load($0) }
        ), preferences: preferences())
        defer { model.clearSelectedAudio() }
        model.selectedID = remote.sample.id
        try await eventually { await deferred.contains(remote.sample.id) }
        model.openLocal(url)
        try await eventually { model.audio != nil }
        await deferred.finish(remote.sample.id, with: .failure(APIError(status: 503, message: "Old NAS request failed")))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.detail)
        XCTAssertEqual(model.audio?.url, url)
        XCTAssertEqual(model.audioDisplayName, url.lastPathComponent)
        XCTAssertNil(model.error)
        XCTAssertNil(model.previewError)
    }

    func testLateDownloadCannotOverwriteNewSelection() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let first = detail(name: "First.wav", bpm: 110), second = detail(name: "Second.wav", bpm: 140)
        let deferred = DeferredPreviewValue<URL>()
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { $0 == first.sample.id ? first : second },
            download: { sample, _ in try await deferred.value(for: sample.id) }, load: { try AudioInfo.load($0) }
        ), preferences: preferences())
        defer { model.clearSelectedAudio() }
        model.selectedID = first.sample.id
        try await eventually { await deferred.contains(first.sample.id) }
        model.selectedID = second.sample.id
        try await eventually { await deferred.contains(second.sample.id) }
        await deferred.finish(second.sample.id, with: .success(url))
        try await eventually { model.audio != nil }
        await deferred.finish(first.sample.id, with: .success(url))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.detail?.sample.id, second.sample.id)
        XCTAssertEqual(model.audioDisplayName, "Second.wav")
        XCTAssertEqual(model.selection.sourceBPM, 140)
        XCTAssertFalse(model.loadingAudio)
        XCTAssertNil(model.error)
        XCTAssertNil(model.previewError)
    }

    func testFolderSelectionClearsPendingAudioAndIgnoresLateFailure() async throws {
        let sample = detail(name: "Pending.wav")
        let deferred = DeferredPreviewValue<URL>()
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in sample }, download: { sample, _ in try await deferred.value(for: sample.id) }, load: { try AudioInfo.load($0) }
        ), preferences: preferences())
        model.selectedID = sample.sample.id
        try await eventually { await deferred.contains(sample.sample.id) }
        model.clearSelectedAudio()
        await deferred.finish(sample.sample.id, with: .failure(APIError(status: 503, message: "Old download failed")))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(model.selectedID)
        XCTAssertNil(model.audio)
        XCTAssertNil(model.detail)
        XCTAssertFalse(model.loadingAudio)
        XCTAssertEqual(model.previewStatus, "")
        XCTAssertNil(model.error)
        XCTAssertNil(model.previewError)
    }

    func testCurrentLoadFailureIsInlineAndRetryable() async throws {
        let sample = detail(name: "Unavailable.wav")
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in sample }, download: { _, _ in throw APIError(status: 503, message: "NAS is unavailable") }, load: { try AudioInfo.load($0) }
        ), preferences: preferences())
        defer { model.clearSelectedAudio() }
        model.selectedID = sample.sample.id
        try await eventually { model.previewError != nil }
        XCTAssertFalse(model.loadingAudio)
        XCTAssertNil(model.audio)
        XCTAssertNil(model.error, "Browsing failures should not interrupt each selection with a modal")
        XCTAssertEqual(model.previewError, "NAS is unavailable")
        model.selectRemoteSample(sample.sample.id)
        XCTAssertTrue(model.loadingAudio, "Clicking the current failed sample retries its preview")
        XCTAssertNil(model.previewError)
    }

    func testAutoPreviewDefaultsOnAndPersistsWithoutChangingStandardPreferences() {
        let settings = preferences(autoPreview: nil)
        let first = BrowserModel(preferences: settings)
        XCTAssertTrue(first.autoPreview)
        first.autoPreview = false
        XCTAssertFalse(BrowserModel(preferences: settings).autoPreview)
        first.autoPreview = true
        XCTAssertTrue(BrowserModel(preferences: settings).autoPreview)
    }

    func testOriginalStartsBeforeWaveformAndInitializationDoesNotStopIt() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let waveform = BlockingWaveform()
        let playback = PreviewRecorder()
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in throw CancellationError() }, download: { _, _ in url },
            load: { waveform.wait(); return try AudioInfo.load($0) },
            play: { url, _, _ in playback.play(url) }, stop: { playback.stop() }
        ), preferences: preferences(autoPreview: true))
        defer { waveform.release(); model.clearSelectedAudio() }
        model.openLocal(url)
        try await eventually { playback.urls == [url] }
        XCTAssertNil(model.audio, "Raw playback starts before waveform decoding completes")
        try await eventually { model.dragURL == url }
        XCTAssertTrue(model.loadingAudio)
        XCTAssertFalse(model.canEditAudio, "Editor controls stay unavailable until the waveform metadata is initialized")
        XCTAssertNil(model.exportURL, "Header-only original drag readiness must not generate a WAV")
        let stopCount = playback.stopCount
        waveform.release()
        try await eventually { model.audio != nil }
        XCTAssertTrue(model.canEditAudio)
        XCTAssertEqual(playback.stopCount, stopCount, "Waveform setup must not stop the early preview")
        XCTAssertEqual(model.dragURL, url)
        XCTAssertNil(model.exportURL)
        model.autoPreview = false
        XCTAssertEqual(playback.stopCount, stopCount + 1)
    }

    func testExplicitFavoritePlaybackStartsWithAutoPreviewOffWithoutChangingPreference() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let waveform = BlockingWaveform(), playback = PreviewRecorder()
        let settings = preferences(autoPreview: false)
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in throw CancellationError() }, download: { _, _ in url },
            load: { waveform.wait(); return try AudioInfo.load($0) },
            play: { url, _, _ in playback.play(url) }, stop: { playback.stop() }
        ), preferences: settings)
        defer { waveform.release(); model.clearSelectedAudio() }
        model.playLocal(url)
        try await eventually { playback.urls == [url] }
        XCTAssertNil(model.audio, "Favorite playback must not wait for waveform analysis")
        XCTAssertFalse(model.autoPreview)
        XCTAssertFalse(settings.bool(forKey: BrowserModel.autoPreviewKey))
        let stopCount = playback.stopCount
        waveform.release()
        try await eventually { model.audio != nil }
        XCTAssertEqual(playback.stopCount, stopCount)
        XCTAssertEqual(model.dragURL, url)
    }

    func testLateOriginalHeaderCannotReplaceANewSelection() async throws {
        let first = try fixture(), second = try fixture(), header = BlockingWaveform(), waveform = BlockingWaveform()
        defer { header.release(); waveform.release(); try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in throw CancellationError() }, download: { _, _ in first },
            load: { url in if url == first { waveform.wait() }; return try AudioInfo.load(url) },
            header: { url in
                let metadata = try AudioSourceMetadata.load(url)
                if url == first { header.wait() }
                return metadata
            }
        ), preferences: preferences())
        defer { model.clearSelectedAudio() }
        model.openLocal(first)
        try await eventually { header.isWaiting && waveform.isWaiting }
        XCTAssertNil(model.dragURL)
        model.openLocal(second)
        try await eventually { model.audio?.url == second && model.dragURL == second }
        header.release(); waveform.release()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.dragURL, second)
        XCTAssertEqual(model.audio?.url, second)
        XCTAssertNil(model.dragError)
    }

    func testHeaderFailureDoesNotAdvertiseOriginalDragBeforeWaveformCompletes() async throws {
        let url = try fixture(), waveform = BlockingWaveform()
        defer { waveform.release(); try? FileManager.default.removeItem(at: url) }
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in throw CancellationError() }, download: { _, _ in url },
            load: { waveform.wait(); return try AudioInfo.load($0) },
            header: { _ in throw AudioError.invalid("Header is unavailable") }
        ), preferences: preferences())
        defer { model.clearSelectedAudio() }
        model.openLocal(url)
        try await eventually { model.dragError != nil }
        XCTAssertNil(model.audio)
        XCTAssertNil(model.dragURL)
        XCTAssertFalse(model.preparingDrag)
        waveform.release()
        try await eventually { model.audio != nil }
        XCTAssertEqual(model.dragURL, url, "Full waveform validation can recover from an earlier temporary header failure")
        XCTAssertNil(model.dragError)
    }

    func testSourceChangeRevokesEarlyOriginalDragAndCancelsUnfinishedWaveform() async throws {
        let url = try fixture(), waveform = BlockingWaveform(), stamp = try SourceStamp.read(url)
        defer { waveform.release(); try? FileManager.default.removeItem(at: url) }
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in throw CancellationError() }, download: { _, _ in url },
            load: { waveform.wait(); return try AudioInfo.load($0) }
        ), preferences: preferences())
        defer { model.clearSelectedAudio() }
        model.openLocal(url)
        try await eventually { waveform.isWaiting && model.dragURL == url }
        try FileManager.default.setAttributes([.modificationDate: stamp.modified.addingTimeInterval(1)], ofItemAtPath: url.path)
        try await eventually { model.previewError != nil }
        XCTAssertNil(model.dragURL)
        XCTAssertNil(model.audio)
        XCTAssertFalse(model.loadingAudio)
        waveform.release()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(model.dragURL, "A late waveform result cannot republish a source whose early drag was revoked")
        XCTAssertNil(model.audio)
    }

    func testLongUntouchedSourceSupportsManualPlaybackSeekAndDragButRejectsWAVExport() async throws {
        let url = try fixture(), directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: directory) }
        let original = try AudioInfo.load(url), frames = Int64(UInt32.max) + 1
        let longInfo = AudioInfo(url: url, totalFrames: frames, sampleRate: original.sampleRate, channels: original.channels, peaks: original.peaks, fingerprint: original.fingerprint, sourceStamp: original.sourceStamp)
        let playback = PreviewRecorder(), seek = PreviewSeekRecorder()
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in throw CancellationError() }, download: { _, _ in url }, load: { _ in longInfo },
            play: { url, _, _ in playback.play(url) },
            seek: { url, _, _, frame in seek.record(url, frame: frame) }
        ), preferences: preferences(), exportDirectory: directory)
        defer { model.clearSelectedAudio() }
        model.openLocal(url)
        try await eventually { model.audio != nil }
        XCTAssertEqual(model.dragURL, url)
        XCTAssertNil(model.dragError)
        model.togglePlayback()
        try await eventually { playback.urls == [url] }
        model.playFromWaveform(frame: frames - 2)
        try await eventually { seek.calls.count == 1 }
        XCTAssertEqual(seek.calls.first, PreviewSeekRecorder.Call(url: url, frame: frames - 2))
        XCTAssertNil(model.error)
        XCTAssertNil(model.exportURL)
        model.render(forExport: true)
        try await eventually { model.error != nil }
        XCTAssertNil(model.exportURL)
        XCTAssertEqual(model.dragURL, url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "WAV limit rejection must happen before any output is created")
    }

    func testPendingPlaybackCanBeCancelledWhileWaveformIsAvailable() async throws {
        let url = try fixture(), deferred = DeferredPreviewValue<URL>(), request = UUID()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in throw CancellationError() }, download: { _, _ in url }, load: { try AudioInfo.load($0) },
            play: { _, _, _ in _ = try await deferred.value(for: request) }
        ), preferences: preferences())
        defer { model.clearSelectedAudio() }
        model.openLocal(url)
        try await eventually { model.audio != nil }
        model.togglePlayback()
        XCTAssertTrue(model.playbackPending)
        try await eventually { await deferred.contains(request) }
        model.togglePlayback()
        XCTAssertFalse(model.playbackPending)
        await deferred.finish(request, with: .failure(AudioError.invalid("A cancelled old open failed")))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(model.playbackPending)
        XCTAssertNil(model.previewError)
        XCTAssertNil(model.error)
    }

    func testAutomaticPlaybackFailureRemainsVisibleWithALoadedWaveformAndClearsOnRetry() async throws {
        let url = try fixture(), calls = RenderCallCounter()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in throw CancellationError() }, download: { _, _ in url }, load: { try AudioInfo.load($0) },
            play: { _, _, _ in if await calls.increment() == 1 { throw AudioError.invalid("Preview device is unavailable") } }
        ), preferences: preferences(autoPreview: true))
        defer { model.clearSelectedAudio() }
        model.openLocal(url)
        try await eventually { model.audio != nil && model.previewError != nil }
        XCTAssertEqual(model.inlinePlaybackError, "Preview device is unavailable")
        XCTAssertFalse(model.playbackPending)
        XCTAssertNil(model.error, "Automatic preview failure stays inline")
        model.togglePlayback()
        XCTAssertTrue(model.playbackPending)
        XCTAssertNil(model.inlinePlaybackError)
        try await eventually { await calls.value == 2 && !model.playbackPending }
        XCTAssertNil(model.previewError)
    }

    func testDisablingAutoPreviewWhileDownloadingPreventsDelayedSoundEvenIfReenabled() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let remote = detail(name: "Delayed.wav")
        let deferred = DeferredPreviewValue<URL>(), playback = PreviewRecorder()
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in remote }, download: { sample, _ in try await deferred.value(for: sample.id) },
            load: { try AudioInfo.load($0) }, play: { url, _, _ in playback.play(url) }
        ), preferences: preferences(autoPreview: true))
        defer { model.clearSelectedAudio() }
        model.selectedID = remote.sample.id
        try await eventually { await deferred.contains(remote.sample.id) }
        model.autoPreview = false
        model.autoPreview = true
        await deferred.finish(remote.sample.id, with: .success(url))
        try await eventually { model.audio != nil }
        XCTAssertTrue(playback.urls.isEmpty, "Reenabling affects the next selection, not pending audio")
        model.openLocal(url)
        try await eventually { playback.urls == [url] }
    }

    func testRapidRemoteSelectionOnlyPlaysMostRecentFile() async throws {
        let firstURL = try fixture(), secondURL = try fixture()
        defer { try? FileManager.default.removeItem(at: firstURL); try? FileManager.default.removeItem(at: secondURL) }
        let first = detail(name: "First.wav"), second = detail(name: "Second.wav")
        let deferred = DeferredPreviewValue<URL>(), playback = PreviewRecorder()
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { $0 == first.sample.id ? first : second },
            download: { sample, _ in try await deferred.value(for: sample.id) }, load: { try AudioInfo.load($0) },
            play: { url, _, _ in playback.play(url) }
        ), preferences: preferences(autoPreview: true))
        defer { model.clearSelectedAudio() }
        model.selectedID = first.sample.id
        try await eventually { await deferred.contains(first.sample.id) }
        model.selectedID = second.sample.id
        try await eventually { await deferred.contains(second.sample.id) }
        await deferred.finish(second.sample.id, with: .success(secondURL))
        try await eventually { model.audio != nil && playback.urls.count == 1 }
        await deferred.finish(first.sample.id, with: .success(firstURL))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(playback.urls, [secondURL])
        XCTAssertEqual(model.dragURL, secondURL)
    }

    func testUntouchedManualPreviewAndDragUseOriginalWithoutRendering() async throws {
        let url = try fixture(), directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: directory) }
        let playback = PreviewRecorder()
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in throw CancellationError() }, download: { _, _ in url }, load: { try AudioInfo.load($0) },
            play: { url, _, _ in playback.play(url) },
            render: { _, _, _ in throw AudioError.invalid("Untouched audio should never render") }
        ), preferences: preferences(), exportDirectory: directory)
        defer { model.clearSelectedAudio() }
        model.openLocal(url)
        try await eventually { model.audio != nil }
        model.sourceBPMText = "125"
        XCTAssertEqual(model.dragURL, url, "Source BPM alone does not edit sound")
        model.togglePlayback()
        try await eventually { playback.urls == [url] }
        XCTAssertFalse(model.rendering)
        XCTAssertNil(model.exportURL)
        XCTAssertNil(model.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testEditedDragAutomaticallyPreparesCorrectPersistentFileAndClearsOldURL() async throws {
        let url = try fixture(), directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: directory) }
        let model = BrowserModel(preferences: preferences(), exportDirectory: directory)
        defer { model.clearSelectedAudio() }
        model.openLocal(url)
        try await eventually { model.audio != nil }
        XCTAssertEqual(model.dragURL, url)
        model.selection = AudioSelection(startFrame: 256, endFrame: 768, fadeInFrames: 32, fadeOutFrames: 32)
        XCTAssertNil(model.dragURL, "An edited selection must never hand the original to a DAW")
        XCTAssertTrue(model.preparingDrag)
        try await eventually { model.dragURL != nil }
        let editedURL = try XCTUnwrap(model.dragURL)
        XCTAssertNotEqual(editedURL, url)
        XCTAssertEqual(editedURL.deletingLastPathComponent(), directory)
        let file = try AVAudioFile(forReading: editedURL)
        XCTAssertEqual(file.length, 512)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 512)!
        try file.read(into: buffer)
        XCTAssertEqual(buffer.floatChannelData![0][0], 0, accuracy: 0.000001)
        XCTAssertEqual(buffer.floatChannelData![0][511], 0, accuracy: 0.000001)
        XCTAssertEqual(buffer.floatChannelData![0][64], Float(sin(Double(320) * 0.05) * 0.5), accuracy: 0.000001)
        model.selection = AudioSelection(startFrame: 0, endFrame: 1024)
        XCTAssertEqual(model.dragURL, url)
        XCTAssertNil(model.exportURL)
        model.clearSelectedAudio()
        XCTAssertTrue(FileManager.default.fileExists(atPath: editedURL.path), "DAW-referenced files must outlive selection changes")
        XCTAssertNil(model.dragURL)
    }

    func testLateEditedRenderCannotReplaceOriginalFromNewSelection() async throws {
        let url = try fixture(), nextURL = try fixture(), directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: nextURL) }
        let deferred = DeferredPreviewValue<URL>(), renderID = UUID()
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in throw CancellationError() }, download: { _, _ in url }, load: { try AudioInfo.load($0) },
            render: { _, _, _ in try await deferred.value(for: renderID) }
        ), preferences: preferences(), exportDirectory: directory)
        defer { model.clearSelectedAudio() }
        model.openLocal(url)
        try await eventually { model.audio != nil }
        model.selection.endFrame = 512
        try await eventually { await deferred.contains(renderID) }
        model.openLocal(nextURL)
        try await eventually { model.audio?.url == nextURL }
        await deferred.finish(renderID, with: .success(directory.appendingPathComponent("stale.wav")))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(model.dragURL, nextURL)
        XCTAssertNil(model.exportURL)
        XCTAssertFalse(model.preparingDrag)
        XCTAssertNil(model.dragError)
    }

    func testInvalidBPMDoesNotLeaveOriginalDragEnabled() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let model = BrowserModel(preferences: preferences())
        defer { model.clearSelectedAudio() }
        model.openLocal(url)
        try await eventually { model.audio != nil }
        model.sourceBPMText = "invalid"
        XCTAssertNil(model.dragURL)
        XCTAssertNotNil(model.dragError)
        model.sourceBPMText = ""
        XCTAssertEqual(model.dragURL, url)
        XCTAssertNil(model.dragError)
    }

    func testManualPreviewSharesPendingDragRenderAndCanCancelItsPendingPlayback() async throws {
        let url = try fixture(), directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        let deferred = DeferredPreviewValue<URL>(), renderID = UUID(), calls = RenderCallCounter(), playback = PreviewRecorder()
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in throw CancellationError() }, download: { _, _ in url }, load: { try AudioInfo.load($0) },
            play: { url, _, _ in playback.play(url) },
            render: { _, _, _ in
                await calls.increment()
                return try await deferred.value(for: renderID)
            }
        ), preferences: preferences(), exportDirectory: directory)
        defer { model.clearSelectedAudio() }
        model.openLocal(url)
        try await eventually { model.audio != nil }
        model.selection.endFrame = 512
        try await eventually { await deferred.contains(renderID) }
        model.togglePlayback()
        XCTAssertTrue(model.playbackPending, "Waiting for an edited render must be shown as cancellable playback preparation")
        try await Task.sleep(for: .milliseconds(20))
        model.togglePlayback()
        XCTAssertFalse(model.playbackPending)
        let editedURL = directory.appendingPathComponent("edited.wav")
        await deferred.finish(renderID, with: .success(editedURL))
        try await eventually { model.dragURL == editedURL }
        let renderCount = await calls.value
        XCTAssertEqual(renderCount, 1, "Manual preview and background drag preparation must not race duplicate writers")
        XCTAssertTrue(playback.urls.isEmpty, "A second Space press cancels queued playback while retaining the drag result")
        model.togglePlayback()
        try await eventually { playback.urls == [editedURL] }
    }

    func testFailedAutomaticDragRenderCanBeRetried() async throws {
        let url = try fixture(), directory = temporaryDirectory(), calls = RenderCallCounter()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: directory) }
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in throw CancellationError() }, download: { _, _ in url }, load: { try AudioInfo.load($0) },
            render: { info, selection, directory in
                if await calls.increment() == 1 { throw AudioError.invalid("A temporary render error") }
                return try AudioRenderer.export(info: info, selection: selection, directory: directory)
            }
        ), preferences: preferences(), exportDirectory: directory)
        defer { model.clearSelectedAudio() }
        model.openLocal(url)
        try await eventually { model.audio != nil }
        model.selection.endFrame = 512
        try await eventually { model.dragError != nil }
        XCTAssertNil(model.dragURL)
        XCTAssertNil(model.error, "Background preparation errors remain inline")
        model.render(forExport: true)
        try await eventually { model.dragURL != nil }
        XCTAssertNil(model.dragError)
        XCTAssertFalse(model.preparingDrag)
        XCTAssertEqual(try AVAudioFile(forReading: XCTUnwrap(model.dragURL)).length, 512)
        let renderCount = await calls.value
        XCTAssertEqual(renderCount, 2)
    }

    func testWaveformSeekPlaysOriginalWithoutEditingOrRenderingWithAutoPreviewOff() async throws {
        let url = try fixture(), playback = PreviewSeekRecorder()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in throw CancellationError() }, download: { _, _ in url }, load: { try AudioInfo.load($0) },
            render: { _, _, _ in throw AudioError.invalid("Waveform seek must not render untouched audio") },
            seek: { url, _, _, frame in playback.record(url, frame: frame) }
        ), preferences: preferences())
        defer { model.clearSelectedAudio() }
        model.openLocal(url)
        try await eventually { model.audio != nil }
        let edit = model.selection
        model.playFromWaveform(frame: 640)
        try await eventually { playback.calls.count == 1 }
        XCTAssertEqual(playback.calls.first, PreviewSeekRecorder.Call(url: url, frame: 640))
        XCTAssertFalse(model.autoPreview)
        XCTAssertEqual(model.selection, edit)
        XCTAssertEqual(model.dragURL, url)
        XCTAssertNil(model.exportURL)
        XCTAssertNil(model.previewURL)
        XCTAssertFalse(model.rendering)
        XCTAssertNil(model.error)
        model.playFromWaveform(frame: Int64.max)
        try await eventually { playback.calls.count == 2 }
        XCTAssertEqual(playback.calls.last?.frame, 1023, "The far right edge remains a playable source frame")
    }

    func testWaveformSeekOutsideUnprocessedTrimUsesExactOriginalPositionAndKeepsDrag() async throws {
        let url = try fixture(), directory = temporaryDirectory(), playback = PreviewSeekRecorder(), renders = RenderCallCounter()
        defer { try? FileManager.default.removeItem(at: url) }
        let editedURL = directory.appendingPathComponent("trim.wav")
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in throw CancellationError() }, download: { _, _ in url }, load: { try AudioInfo.load($0) },
            render: { _, _, _ in await renders.increment(); return editedURL },
            seek: { url, _, _, frame in playback.record(url, frame: frame) }
        ), preferences: preferences(), exportDirectory: directory)
        defer { model.clearSelectedAudio() }
        model.openLocal(url)
        try await eventually { model.audio != nil }
        model.selection = AudioSelection(startFrame: 256, endFrame: 768)
        try await eventually { model.dragURL == editedURL }
        let edit = model.selection
        model.playFromWaveform(frame: 900)
        try await eventually { playback.calls.count == 1 }
        XCTAssertEqual(playback.calls.first, PreviewSeekRecorder.Call(url: url, frame: 900))
        XCTAssertEqual(model.selection, edit)
        XCTAssertEqual(model.dragURL, editedURL)
        XCTAssertEqual(model.exportURL, editedURL)
        XCTAssertFalse(model.preparingDrag)
        let count = await renders.value
        XCTAssertEqual(count, 1, "Only the existing trim export was rendered")
    }

    func testWaveformSeekMapsEditedTempoAndReusesPreparedAudio() async throws {
        let url = try fixture(), directory = temporaryDirectory(), playback = PreviewSeekRecorder(), renders = RenderCallCounter()
        defer { try? FileManager.default.removeItem(at: url) }
        let editedURL = directory.appendingPathComponent("processed.wav")
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in throw CancellationError() }, download: { _, _ in url }, load: { try AudioInfo.load($0) },
            render: { _, _, _ in await renders.increment(); return editedURL },
            seek: { url, _, _, frame in playback.record(url, frame: frame) }
        ), preferences: preferences(), exportDirectory: directory)
        defer { model.clearSelectedAudio() }
        model.openLocal(url)
        try await eventually { model.audio != nil }
        model.selection = AudioSelection(startFrame: 256, endFrame: 768, sourceBPM: 120, targetBPM: 240, pitchSemitones: 3, fadeInFrames: 16, fadeOutFrames: 20)
        try await eventually { model.dragURL == editedURL }
        let edit = model.selection
        model.playFromWaveform(frame: 512)
        try await eventually { playback.calls.count == 1 }
        XCTAssertEqual(playback.calls.first, PreviewSeekRecorder.Call(url: editedURL, frame: 128))
        XCTAssertEqual(model.selection, edit)
        XCTAssertEqual(model.exportURL, editedURL)
        XCTAssertEqual(model.dragURL, editedURL)
        let count = await renders.value
        XCTAssertEqual(count, 1, "Seeking a prepared edit must reuse its tempo, pitch, and fades")
    }

    func testWaveformSeekOutsideProcessedTrimUsesSeparateCachedAuditionAndLatestClick() async throws {
        let url = try fixture(), directory = temporaryDirectory(), cache = temporaryDirectory(), playback = PreviewSeekRecorder()
        defer { try? FileManager.default.removeItem(at: url) }
        let editedURL = directory.appendingPathComponent("processed.wav"), auditionURL = cache.appendingPathComponent("audition.wav")
        let renders = AuditionRenderRecorder(), deferred = DeferredPreviewValue<URL>(), auditionID = UUID()
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in throw CancellationError() }, download: { _, _ in url }, load: { try AudioInfo.load($0) },
            render: { _, edit, destination in
                await renders.record(edit, directory: destination)
                if edit.startFrame == 0 { return try await deferred.value(for: auditionID) }
                return editedURL
            },
            seek: { url, _, _, frame in playback.record(url, frame: frame) }
        ), preferences: preferences(), exportDirectory: directory, cacheDirectory: cache)
        defer { model.clearSelectedAudio() }
        model.openLocal(url)
        try await eventually { model.audio != nil }
        model.selection = AudioSelection(startFrame: 256, endFrame: 768, sourceBPM: 120, targetBPM: 240, pitchSemitones: 3, fadeInFrames: 16, fadeOutFrames: 20)
        try await eventually { model.dragURL == editedURL }
        let edit = model.selection
        model.playFromWaveform(frame: 128)
        try await eventually { await deferred.contains(auditionID) }
        XCTAssertTrue(model.playbackPending, "A processed waveform audition may require preparation before its seek starts")
        model.playFromWaveform(frame: 900)
        await deferred.finish(auditionID, with: .success(auditionURL))
        try await eventually { playback.calls.count == 1 }
        XCTAssertFalse(model.playbackPending)
        XCTAssertEqual(playback.calls.first, PreviewSeekRecorder.Call(url: auditionURL, frame: 450), "Only the latest pending click may begin playback")
        model.playFromWaveform(frame: 64)
        try await eventually { playback.calls.count == 2 }
        XCTAssertEqual(playback.calls.last?.frame, 32)
        XCTAssertEqual(model.selection, edit)
        XCTAssertEqual(model.exportURL, editedURL)
        XCTAssertEqual(model.dragURL, editedURL)
        XCTAssertFalse(model.preparingDrag)
        let records = await renders.records
        XCTAssertEqual(records.count, 2, "Repeated outside-trim clicks share a cached audition")
        XCTAssertEqual(records.last?.directory, cache.appendingPathComponent("waveform-audition", isDirectory: true))
        XCTAssertEqual(records.last?.edit.startFrame, 0)
        XCTAssertEqual(records.last?.edit.endFrame, 1024)
        XCTAssertEqual(records.last?.edit.rate, 2)
        XCTAssertEqual(records.last?.edit.pitchSemitones, 3)
        XCTAssertEqual(records.last?.edit.fadeInFrames, 16)
        XCTAssertEqual(records.last?.edit.fadeOutFrames, 20)
    }

    func testLateWaveformAuditionCannotPlayAfterSelectingAnotherSample() async throws {
        let url = try fixture(), nextURL = try fixture(), directory = temporaryDirectory(), playback = PreviewSeekRecorder()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: nextURL) }
        let editedURL = directory.appendingPathComponent("processed.wav")
        let deferred = DeferredPreviewValue<URL>(), auditionID = UUID()
        let model = BrowserModel(previewIO: BrowserPreviewIO(
            detail: { _ in throw CancellationError() }, download: { _, _ in url }, load: { try AudioInfo.load($0) },
            render: { _, edit, _ in
                if edit.startFrame == 0 { return try await deferred.value(for: auditionID) }
                return editedURL
            },
            seek: { url, _, _, frame in playback.record(url, frame: frame) }
        ), preferences: preferences(), exportDirectory: directory)
        defer { model.clearSelectedAudio() }
        model.openLocal(url)
        try await eventually { model.audio != nil }
        model.selection = AudioSelection(startFrame: 256, endFrame: 768, pitchSemitones: 3)
        try await eventually { model.dragURL == editedURL }
        model.playFromWaveform(frame: 900)
        try await eventually { await deferred.contains(auditionID) }
        model.openLocal(nextURL)
        try await eventually { model.audio?.url == nextURL }
        await deferred.finish(auditionID, with: .success(directory.appendingPathComponent("stale.wav")))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(playback.calls.isEmpty)
        XCTAssertEqual(model.dragURL, nextURL)
        XCTAssertNil(model.exportURL)
        XCTAssertNil(model.error)
    }

    private func preferences(autoPreview: Bool? = false) -> UserDefaults {
        let suite = "SampleBrowserTests.preview.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        if let autoPreview { preferences.set(autoPreview, forKey: BrowserModel.autoPreviewKey) }
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return preferences
    }
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("preview-exports-\(UUID().uuidString)", isDirectory: true)
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Preview state did not settle within two seconds")
        throw APIError(status: 0, message: "Timed out")
    }

    private func detail(name: String, bpm: Double? = nil) -> SampleDetail {
        let sample = Sample(id: UUID(), sourceRevision: 1, name: name, path: name, sourceState: "present", rootState: "online", bpm: bpm, keyState: "unknown", key: nil, durationSeconds: 1, sampleKind: "one_shot", favorite: false, tagIds: [], tagVersion: 1, analysis: [:])
        return SampleDetail(sample: sample, annotations: Annotations(bpmMode: "auto", bpmValue: nil, keyMode: "auto", keyValue: nil, keyNoneReason: "", sampleKind: "one_shot", beatOffsetFrames: nil, notes: "", recordVersion: 1), favoriteState: FavoriteState(favorite: false, recordVersion: 1), sampleRate: 48000, channels: 1, totalFrames: 1024)
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID()).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        for frame in 0..<1024 { buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 0.05) * 0.5) }
        try file.write(from: buffer)
        return url
    }
}

@MainActor private final class PreviewRecorder {
    var urls: [URL] = []
    var stopCount = 0
    func play(_ url: URL) { urls.append(url) }
    func stop() { stopCount += 1 }
}

private final class BlockingWaveform: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var started = false
    var isWaiting: Bool {
        condition.lock(); defer { condition.unlock() }
        return started && !released
    }
    func wait() {
        condition.lock(); defer { condition.unlock() }
        started = true
        while !released { condition.wait() }
    }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

private actor RenderCallCounter {
    private(set) var value = 0
    @discardableResult func increment() -> Int { value += 1; return value }
}

@MainActor private final class PreviewSeekRecorder {
    struct Call: Equatable { let url: URL; let frame: Int64 }
    private(set) var calls: [Call] = []
    func record(_ url: URL, frame: Int64) { calls.append(Call(url: url, frame: frame)) }
}

private actor AuditionRenderRecorder {
    struct Record: Sendable { let edit: AudioSelection; let directory: URL }
    private(set) var records: [Record] = []
    func record(_ edit: AudioSelection, directory: URL) { records.append(Record(edit: edit, directory: directory)) }
}
