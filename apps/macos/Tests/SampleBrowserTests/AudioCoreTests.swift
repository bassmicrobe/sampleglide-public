import XCTest
import AVFoundation
@testable import SampleBrowser

final class AudioCoreTests: XCTestCase {
    func testHalfOpenRangeAndTempoMath() throws {
        var edit = AudioSelection(startFrame: 12000, endFrame: 60000, sourceBPM: 120, targetBPM: 180)
        try edit.validate(totalFrames: 96000, sampleRate: 48000)
        XCTAssertEqual(edit.rate, 1.5)
        XCTAssertEqual(edit.outputFrames, 32000)
        edit.startFrame = edit.endFrame
        XCTAssertThrowsError(try edit.validate(totalFrames: 96000, sampleRate: 48000))
        edit = AudioSelection(startFrame: 0, endFrame: 48000, targetBPM: 120)
        XCTAssertThrowsError(try edit.validate(totalFrames: 48000, sampleRate: 48000))
        edit = AudioSelection(startFrame: 0, endFrame: 48000, sourceBPM: 120, targetBPM: 600)
        XCTAssertThrowsError(try edit.validate(totalFrames: 48000, sampleRate: 48000))
    }
    func testLongOriginalSelectionIsValidWithoutCreatingAWAV() throws {
        let frames = Int64(UInt32.max) + 1
        let edit = AudioSelection(startFrame: 0, endFrame: frames)
        XCTAssertNoThrow(try edit.validate(totalFrames: frames, sampleRate: 48000))
        XCTAssertEqual(edit.outputFrames, frames)
        XCTAssertThrowsError(try edit.validateWAVExport(totalFrames: frames, sampleRate: 48000, channels: 1))
    }
    func testWAVExportLimitIncludesAllChannels() throws {
        let frames = Int64(UInt32.max - 4096) / 8 + 1
        let edit = AudioSelection(startFrame: 0, endFrame: frames)
        XCTAssertNoThrow(try edit.validateWAVExport(totalFrames: frames, sampleRate: 48000, channels: 1))
        XCTAssertThrowsError(try edit.validateWAVExport(totalFrames: frames, sampleRate: 48000, channels: 2))
    }
    func testStreamedStereoPeaksAndRenderedFrames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("source.wav")
        try fixture(input)
        let info = try AudioInfo.load(input)
        XCTAssertEqual(info.totalFrames, 96000)
        XCTAssertEqual(info.channels, 2)
        XCTAssertLessThanOrEqual(info.peaks[0].count, 1024)
        XCTAssertGreaterThan(info.peaks[0].map(\.maximum).max()!, 0.49)
        XCTAssertLessThan(info.peaks[1].map(\.minimum).min()!, -0.49)
        let original = try Data(contentsOf: input)
        for rate in [1.0, 0.25, 0.5, 1.5, 2.0, 4.0] {
            let selection = AudioSelection(startFrame: 12000, endFrame: 84000, sourceBPM: 120, targetBPM: 120 * rate)
            let output = try AudioRenderer.export(info: info, selection: selection, directory: folder.appendingPathComponent("exports"))
            let file = try AVAudioFile(forReading: output)
            XCTAssertEqual(file.length, selection.outputFrames, "rate \(rate)")
            XCTAssertEqual(file.processingFormat.channelCount, 2)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let left = buffer.floatChannelData![0], right = buffer.floatChannelData![1]
            let total = Int(buffer.frameLength)
            let power = (0..<total).reduce(0.0) { $0 + Double(left[$1] * left[$1]) } / Double(total)
            XCTAssertGreaterThan(power, 0.07, "signal power rate \(rate)")
            let firstPower = (0..<4800).reduce(0.0) { $0 + Double(left[$1] * left[$1]) } / 4800
            let lastPower = (total-4800..<total).reduce(0.0) { $0 + Double(left[$1] * left[$1]) } / 4800
            XCTAssertGreaterThan(firstPower, 0.04, "no inserted silence at start rate \(rate)")
            XCTAssertGreaterThan(lastPower, 0.04, "no truncated tail rate \(rate)")
            let stereoError = (4800..<min(total,14400)).reduce(0.0) { $0 + abs(Double(left[$1] + right[$1])) } / Double(min(total,14400)-4800)
            XCTAssertLessThan(stereoError, 0.005, "opposite phase stereo preserved")
            // Count zero crossings away from boundaries; tempo changes must preserve 440 Hz.
            let lo = 4800, hi = min(total - 4800, 24000)
            let crossings = (lo+1..<hi).filter { left[$0-1] <= 0 && left[$0] > 0 }.count
            let frequency = Double(crossings) * 48000 / Double(hi-lo)
            XCTAssertEqual(frequency, 440, accuracy: 8, "tempo preserves pitch")
            XCTAssertEqual(try AudioRenderer.export(info: info, selection: selection, directory: folder.appendingPathComponent("exports")), output)
        }
        let shifted = try AudioRenderer.export(info: info, selection: AudioSelection(startFrame: 0, endFrame: 96000, pitchSemitones: 12), directory: folder.appendingPathComponent("exports"))
        let file = try AVAudioFile(forReading: shifted)
        XCTAssertEqual(file.length, 96000)
        file.framePosition = 24000
        let block = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 24000)!
        try file.read(into: block)
        let values = block.floatChannelData![0]
        let crossings = (1..<Int(block.frameLength)).filter { values[$0-1] <= 0 && values[$0] > 0 }.count
        XCTAssertEqual(Double(crossings) * 2, 880, accuracy: 10)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }
    func testSourceChangeInvalidatesExistingRenderAndUnityTrimIsExact() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("source.wav")
        try fixture(input)
        let info = try AudioInfo.load(input)
        let edit = AudioSelection(startFrame: 101, endFrame: 8197)
        let output = try AudioRenderer.export(info: info, selection: edit, directory: folder.appendingPathComponent("exports"))
        let original = try AVAudioFile(forReading: input), rendered = try AVAudioFile(forReading: output)
        original.framePosition = 101
        let a = AVAudioPCMBuffer(pcmFormat: original.processingFormat, frameCapacity: 8096)!, b = AVAudioPCMBuffer(pcmFormat: rendered.processingFormat, frameCapacity: 8096)!
        try original.read(into: a); try rendered.read(into: b)
        XCTAssertEqual(b.frameLength, 8096)
        for ch in 0..<2 { for frame in 0..<8096 { XCTAssertEqual(a.floatChannelData![ch][frame], b.floatChannelData![ch][frame]) } }
        try FileManager.default.setAttributes([.modificationDate: info.sourceStamp.modified.addingTimeInterval(1)], ofItemAtPath: input.path)
        XCTAssertThrowsError(try AudioRenderer.export(info: info, selection: edit, directory: folder.appendingPathComponent("exports")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "previous published export is preserved")
    }
    func testStereoDistinctTonesAndBoundaryFades() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("stereo.wav")
        try fixture(input, distinctRight: true)
        let info = try AudioInfo.load(input)
        for rate in [0.5, 1.5, 2.0] {
            let edit = AudioSelection(startFrame: 0, endFrame: 96000, sourceBPM: 120, targetBPM: 120*rate, fadeInFrames: 100, fadeOutFrames: 100)
            let output = try AudioRenderer.export(info: info, selection: edit, directory: folder.appendingPathComponent("exports"))
            let file = try AVAudioFile(forReading: output)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            for ch in 0..<2 {
                let values = buffer.floatChannelData![ch]
                XCTAssertEqual(values[0], 0)
                XCTAssertEqual(values[Int(buffer.frameLength)-1], 0)
                let start = 6000, count = min(24000,Int(buffer.frameLength)-12000)
                func amplitude(_ frequency: Double) -> Double {
                    var sine = 0.0, cosine = 0.0
                    for frame in start..<start+count {
                        let phase = Double(frame) * 2 * Double.pi * frequency / 48000
                        sine += Double(values[frame])*sin(phase); cosine += Double(values[frame])*cos(phase)
                    }
                    return hypot(sine,cosine)*2/Double(count)
                }
                // Finite-window Fourier magnitude uses a small band to avoid
                // phase-vocoder/window drift being mistaken for channel loss.
                func bandAmplitude(_ center: Double) -> Double { stride(from: center-8, through: center+8, by: 2).map(amplitude).max()! }
                let wanted = bandAmplitude(ch == 0 ? 440 : 660), other = bandAmplitude(ch == 0 ? 660 : 440)
                XCTAssertGreaterThan(wanted, 0.3, "channel tone retained at rate \(rate)")
                XCTAssertLessThan(other, 0.1, "stereo separation at rate \(rate)")
            }
        }
    }
    private func fixture(_ url: URL, distinctRight: Bool = false) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        var offset = 0
        while offset < 96000 {
            buffer.frameLength = AVAudioFrameCount(min(4096,96000-offset))
            for frame in 0..<Int(buffer.frameLength) {
                let value = Float(0.5 * sin(Double(offset+frame) * 2 * .pi * 440 / 48000))
                buffer.floatChannelData![0][frame] = value
                buffer.floatChannelData![1][frame] = distinctRight ? Float(0.5 * sin(Double(offset+frame) * 2 * .pi * 660 / 48000)) : -value
            }
            try file.write(from: buffer); offset += Int(buffer.frameLength)
        }
    }
}
