import XCTest
import AVFoundation
@testable import SampleBrowser

private actor PreviewOpenGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor final class AudioPreviewTests: XCTestCase {
    func testOriginalFileStreamsWithoutAnExportAndFinishesNaturally() async throws {
        let fixture = try makeFixture(duration: 0.08)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let preview = AudioPreview()
        defer { preview.stop() }
        try await preview.playFile(fixture, volume: 0, loop: false)
        XCTAssertTrue(preview.isPlaying)
        XCTAssertEqual(preview.currentURL, fixture)
        XCTAssertEqual(preview.currentStartFrame, 0)
        try await eventually { !preview.isPlaying }
        XCTAssertNil(preview.currentURL)
        XCTAssertNil(preview.currentStartFrame)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.deletingLastPathComponent().path), [fixture.lastPathComponent])
    }

    func testSlowPreviousOpenCannotReplaceCurrentPlayback() async throws {
        let fixture = try makeFixture(duration: 0.5)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let first = fixture.deletingLastPathComponent().appendingPathComponent("first.wav")
        try FileManager.default.copyItem(at: fixture, to: first)
        let gate = PreviewOpenGate()
        let preview = AudioPreview(openFile: { url in
            if url == first { await gate.wait() }
            return PreparedPreviewFile(file: try AVAudioFile(forReading: url))
        })
        defer { preview.stop() }
        let stale = Task { try await preview.playFile(first, volume: 0, loop: false, startingFrame: 100) }
        try await eventually { await gate.started }
        try await preview.playFile(fixture, volume: 0, loop: false, startingFrame: 4800)
        await gate.release()
        do {
            try await stale.value
            XCTFail("Replaced open should be cancelled")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(preview.isPlaying)
        XCTAssertEqual(preview.currentURL, fixture)
        XCTAssertEqual(preview.currentStartFrame, 4800)
    }

    func testCancelledPendingOpenNeverStartsPlayback() async throws {
        let fixture = try makeFixture(duration: 0.1)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let gate = PreviewOpenGate()
        let preview = AudioPreview(openFile: { url in
            await gate.wait()
            return PreparedPreviewFile(file: try AVAudioFile(forReading: url))
        })
        defer { preview.stop() }
        let pending = Task { try await preview.playFile(fixture, volume: 0, loop: false) }
        try await eventually { await gate.started }
        pending.cancel()
        await gate.release()
        do {
            try await pending.value
            XCTFail("Cancelled open should fail")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(preview.isPlaying)
        XCTAssertNil(preview.currentURL)
    }

    func testVolumeChangeWhileHeaderIsOpeningAppliesWhenPlaybackStarts() async throws {
        let fixture = try makeFixture(duration: 0.2)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let gate = PreviewOpenGate()
        let preview = AudioPreview(openFile: { url in
            await gate.wait()
            return PreparedPreviewFile(file: try AVAudioFile(forReading: url))
        })
        defer { preview.stop() }
        let pending = Task { try await preview.playFile(fixture, volume: 0.75, loop: false, startingFrame: 4800) }
        try await eventually { await gate.started }
        preview.setVolume(0)
        await gate.release()
        try await pending.value
        XCTAssertTrue(preview.isPlaying)
        XCTAssertEqual(preview.outputVolume, 0, "The engine must use the new mute value instead of the initial volume")
        XCTAssertEqual(preview.currentStartFrame, 4800)
    }

    func testCompletionOfStoppedFileCannotStopTheNewFile() async throws {
        let first = try makeFixture(duration: 0.05)
        let second = try makeFixture(duration: 0.8)
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        let preview = AudioPreview()
        defer { preview.stop() }
        try await preview.playFile(first, volume: 0, loop: false)
        try await preview.playFile(second, volume: 0, loop: false)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(preview.isPlaying)
        XCTAssertEqual(preview.currentURL, second)
    }

    func testLoopKeepsPlayingAndStopInvalidatesItsCompletion() async throws {
        let fixture = try makeFixture(duration: 0.06)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let preview = AudioPreview()
        defer { preview.stop() }
        try await preview.playFile(fixture, volume: 0, loop: true, startingFrame: 1440)
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertTrue(preview.isPlaying)
        XCTAssertEqual(preview.currentURL, fixture)
        XCTAssertEqual(preview.currentStartFrame, 1440)
        preview.stop()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(preview.isPlaying)
        XCTAssertNil(preview.currentURL)
    }

    func testSeekPlaysOnlyTheRemainingFramesWithoutExporting() async throws {
        let fixture = try makeFixture(duration: 1.6)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let preview = AudioPreview()
        defer { preview.stop() }
        try await preview.playFile(fixture, volume: 0, loop: false, startingFrame: 64800)
        XCTAssertTrue(preview.isPlaying)
        XCTAssertEqual(preview.currentStartFrame, 64800)
        // The remaining 0.25 seconds should finish well before the full 1.6 s.
        // This also checks scheduleSegment, rather than just bookkeeping state.
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(preview.isPlaying)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.deletingLastPathComponent().path), [fixture.lastPathComponent])
    }

    func testSeekClampsOutsideTheFileToAPlayableFrame() async throws {
        let fixture = try makeFixture(duration: 0.1)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let preview = AudioPreview()
        defer { preview.stop() }
        try await preview.playFile(fixture, volume: 0, loop: false, startingFrame: .min)
        XCTAssertEqual(preview.currentStartFrame, 0)
        try await preview.playFile(fixture, volume: 0, loop: false, startingFrame: .max)
        XCTAssertEqual(preview.currentStartFrame, 4799)
        try await eventually { !preview.isPlaying }
    }

    func testLongFileSegmentsRetain64BitSeekOffsetsWithoutOverflow() {
        let largestSegment = Int64(AVAudioFrameCount.max)
        XCTAssertEqual(AudioPreview.segmentFrameCount(startingAt: 10, fileLength: largestSegment + 100), .max)
        XCTAssertEqual(AudioPreview.segmentFrameCount(startingAt: largestSegment + 10, fileLength: largestSegment + 100), 90)
        XCTAssertEqual(AudioPreview.segmentFrameCount(startingAt: Int64.max - 100, fileLength: .max), 100)
        XCTAssertEqual(AudioPreview.segmentFrameCount(startingAt: -1, fileLength: 100), 0)
        XCTAssertEqual(AudioPreview.segmentFrameCount(startingAt: 100, fileLength: 100), 0)
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Playback state did not settle within three seconds")
        throw AudioError.invalid("Test timed out")
    }

    private func makeFixture(duration: Double) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("audio-preview-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let count = AVAudioFrameCount(duration * 48000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        // Silent fixtures and volume zero keep verification inaudible.
        for frame in 0..<Int(count) { buffer.floatChannelData![0][frame] = 0 }
        try file.write(from: buffer)
        return url
    }
}
