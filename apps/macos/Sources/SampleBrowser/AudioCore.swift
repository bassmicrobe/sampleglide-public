import Foundation
import AVFoundation
import CryptoKit

enum AudioError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

struct AudioSelection: Codable, Hashable, Sendable {
    var startFrame: Int64 = 0
    var endFrame: Int64 = 1
    var sourceBPM: Double? = nil
    var targetBPM: Double? = nil
    var pitchSemitones: Double = 0
    var fadeInFrames: Int64 = 0
    var fadeOutFrames: Int64 = 0
    var rate: Double { guard let sourceBPM, let targetBPM else { return 1 }; return targetBPM / sourceBPM }
    func validate(totalFrames: Int64, sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate > 0, startFrame >= 0, startFrame < endFrame, endFrame <= totalFrames else { throw AudioError.invalid("範囲は 0 ≤ 開始 < 終了 ≤ 原音フレーム数で指定してください。") }
        guard sourceBPM == nil || (sourceBPM!.isFinite && sourceBPM! > 0), targetBPM == nil || (sourceBPM != nil && targetBPM!.isFinite && targetBPM! > 0) else { throw AudioError.invalid("目標 BPM には正しい元 BPM が必要です。") }
        guard (0.25...4).contains(rate), pitchSemitones.isFinite, (-24...24).contains(pitchSemitones) else { throw AudioError.invalid("対応範囲: テンポ倍率 0.25–4、移調 ±24 半音。") }
        guard fadeInFrames >= 0, fadeOutFrames >= 0, fadeInFrames <= outputFrames, fadeOutFrames <= outputFrames else { throw AudioError.invalid("フェードが書き出し範囲を超えています。") }
        guard outputFrames > 0 else { throw AudioError.invalid("処理後のフレーム数が有効な範囲を超えています。") }
    }
    /// Streaming and original-file drags do not create a WAV container. Apply
    /// its channel-aware size limit only when a processed WAV is requested.
    func validateWAVExport(totalFrames: Int64, sampleRate: Double, channels: Int) throws {
        try validate(totalFrames: totalFrames, sampleRate: sampleRate)
        guard (1...8).contains(channels), Double(outputFrames) * Double(channels) * 4 < Double(UInt32.max - 4096) else { throw AudioError.invalid("標準 WAV の 4 GB 上限を超えます。範囲を短くしてください。") }
    }
    var outputFrames: Int64 { let (length, overflow) = endFrame.subtractingReportingOverflow(startFrame); guard !overflow else { return 0 }; let value = Double(length) / rate; return value.isFinite && value > 0 && value < Double(Int64.max) ? Int64(value.rounded()) : 0 }
}
struct SourceStamp: Equatable, Sendable {
    let size: UInt64
    let modified: Date
    let inode: UInt64
    static func read(_ url: URL) throws -> SourceStamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date, let inode = attributes[.systemFileNumber] as? NSNumber else { throw AudioError.invalid("原音の変更情報を取得できません。") }
        return SourceStamp(size: size.uint64Value, modified: modified, inode: inode.uint64Value)
    }
}
/// Header and source identity only; no PCM decoding or whole-file hashing.
struct AudioSourceMetadata: Sendable {
    let url: URL
    let sourceStamp: SourceStamp
    static func load(_ url: URL) throws -> AudioSourceMetadata {
        try Task.checkCancellation()
        let stamp = try SourceStamp.read(url)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, (1...8).contains(format.channelCount), format.sampleRate.isFinite, format.sampleRate > 0 else { throw AudioError.invalid("空の音声、または 8 ch を超える形式は未対応です。") }
        try Task.checkCancellation()
        guard try SourceStamp.read(url) == stamp else { throw AudioError.invalid("読み取り中に原音が変更されました。選び直してください。") }
        return AudioSourceMetadata(url: url, sourceStamp: stamp)
    }
    func validateSource() throws { guard try SourceStamp.read(url) == sourceStamp else { throw AudioError.invalid("原音が変更されました。選び直してください。") } }
}
struct Peak: Sendable { var minimum: Float; var maximum: Float }
struct AudioInfo: Sendable {
    let url: URL
    let totalFrames: Int64
    let sampleRate: Double
    let channels: Int
    let peaks: [[Peak]]
    let fingerprint: String
    let sourceStamp: SourceStamp
    func validateSource() throws { guard try SourceStamp.read(url) == sourceStamp else { throw AudioError.invalid("原音が変更されました。選び直してください。") } }
    var duration: Double { Double(totalFrames) / sampleRate }
    static func load(_ url: URL) throws -> AudioInfo {
        let stamp = try SourceStamp.read(url)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.channelCount > 0, format.channelCount <= 8, file.length > 0 else { throw AudioError.invalid("空の音声、または 8 ch を超える形式は未対応です。") }
        let width = max(Int64(1), (file.length + 1023) / 1024)
        let count = Int((file.length + width - 1) / width)
        var peaks = Array(repeating: Array(repeating: Peak(minimum: 0, maximum: 0), count: count), count: Int(format.channelCount))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw AudioError.invalid("音声バッファを作成できません。") }
        var position: Int64 = 0
        var hasher = SHA256()
        while position < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, file.length - position)))
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { throw AudioError.invalid("この符号化方式はデコードできません。") }
            for channel in 0..<Int(format.channelCount) {
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: data[channel], count: Int(buffer.frameLength) * 4))
                for frame in 0..<Int(buffer.frameLength) {
                    let index = Int((position + Int64(frame)) / width)
                    let value = data[channel][frame]
                    guard value.isFinite else { throw AudioError.invalid("非有限の音声サンプルを検出しました。") }
                    peaks[channel][index].minimum = min(peaks[channel][index].minimum, value)
                    peaks[channel][index].maximum = max(peaks[channel][index].maximum, value)
                }
            }
            position += Int64(buffer.frameLength)
        }
        let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard try SourceStamp.read(url) == stamp else { throw AudioError.invalid("読み取り中に原音が変更されました。選び直してください。") }
        return AudioInfo(url: url, totalFrames: file.length, sampleRate: format.sampleRate, channels: Int(format.channelCount), peaks: peaks, fingerprint: fingerprint, sourceStamp: stamp)
    }
}

/// Reads only bounded blocks. Edited previews and export consume the same rendered WAV.
/// Unedited previews stream the source directly through AudioPreview.
/// Export has no I/O or allocations in a custom realtime callback.
enum AudioRenderer {
    static let implementation = "avaudio-timepitch-polarity-normalized-v4"
    static func export(info: AudioInfo, selection: AudioSelection, directory: URL) throws -> URL {
        try info.validateSource()
        try selection.validateWAVExport(totalFrames: info.totalFrames, sampleRate: info.sampleRate, channels: info.channels)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var key = Data((info.fingerprint + implementation + "float32-\(info.sampleRate)-\(info.channels)").utf8)
        key.append(try encoder.encode(selection))
        let digest = SHA256.hash(data: key).prefix(12).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("sample-\(digest).wav")
        if FileManager.default.fileExists(atPath: output.path) {
            let existing = try AVAudioFile(forReading: output)
            guard existing.length == selection.outputFrames, existing.processingFormat.channelCount == info.channels else { throw AudioError.invalid("既存の書き出し WAV が破損しています。Finder で確認してください。") }
            return output
        }
        let scratch = directory.appendingPathComponent(".render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let partial = scratch.appendingPathComponent("output.wav")
        let input = try AVAudioFile(forReading: info.url)
        guard input.length == info.totalFrames, input.processingFormat.sampleRate == info.sampleRate else { throw AudioError.invalid("原音が変更されました。選び直してください。") }
        // Unity processing is an exact streamed copy. Native stereo TimePitch
        // can cancel antiphase signals. A reversible right-channel polarity
        // normalization keeps its phase reference non-canceling; channel layout
        // stays stereo throughout DSP and the original polarity is restored.
        if selection.rate == 1 && selection.pitchSemitones == 0 {
            try copyRange(input: input, selection: selection, output: partial)
        } else {
            guard info.channels <= 2 else { throw AudioError.invalid("テンポ・移調は mono / stereo に対応しています。多チャンネル素材は範囲書き出しのみ利用できます。") }
            let prepared = scratch.appendingPathComponent("input.wav")
            let invertRight = try prepareRange(input: input, selection: selection, output: prepared)
            try renderProcessed(inputURL: prepared, selection: selection, output: partial, invertRight: invertRight)
        }
        // Every AVAudioFile writer has left its helper scope before publication.
        try Task.checkCancellation(); try info.validateSource()
        let verification = try AVAudioFile(forReading: partial)
        guard verification.length == selection.outputFrames else { throw AudioError.invalid("出力フレーム数が一致しません。") }
        try FileManager.default.moveItem(at: partial, to: output)
        return output
    }
    private static func settings(sampleRate: Double, channels: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    }
    private static func applyFades(_ buffer: AVAudioPCMBuffer, offset: Int64, selection: AudioSelection) {
        guard selection.fadeInFrames > 0 || selection.fadeOutFrames > 0, let channels = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) { for frame in 0..<Int(buffer.frameLength) {
            let position = offset + Int64(frame)
            var gain = 1.0
            if selection.fadeInFrames > 0 { gain = min(gain, Double(position) / Double(selection.fadeInFrames)) }
            if selection.fadeOutFrames > 0 { gain = min(gain, Double(selection.outputFrames - 1 - position) / Double(selection.fadeOutFrames)) }
            channels[channel][frame] *= Float(max(0, gain))
        } }
    }
    private static func copyRange(input: AVAudioFile, selection: AudioSelection, output: URL) throws {
        let writer = try AVAudioFile(forWriting: output, settings: settings(sampleRate: input.processingFormat.sampleRate, channels: Int(input.processingFormat.channelCount)))
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192)!
        input.framePosition = selection.startFrame
        var offset: Int64 = 0
        while offset < selection.outputFrames {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, selection.outputFrames-offset)))
            guard buffer.frameLength > 0 else { throw AudioError.invalid("原音の読み取りが途中で終了しました。") }
            applyFades(buffer, offset: offset, selection: selection)
            try writer.write(from: buffer); offset += Int64(buffer.frameLength)
        }
    }
    private static func prepareRange(input: AVAudioFile, selection: AudioSelection, output: URL) throws -> Bool {
        let format = input.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        var cross = 0.0, leftPower = 0.0, rightPower = 0.0
        if format.channelCount == 2 {
            input.framePosition = selection.startFrame
            var remaining = selection.endFrame-selection.startFrame
            while remaining > 0 {
                try Task.checkCancellation()
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(8192,remaining)))
                guard buffer.frameLength > 0 else { throw AudioError.invalid("原音の読み取りが途中で終了しました。") }
                for frame in 0..<Int(buffer.frameLength) {
                    let left = Double(buffer.floatChannelData![0][frame]), right = Double(buffer.floatChannelData![1][frame])
                    cross += left*right; leftPower += left*left; rightPower += right*right
                }
                remaining -= Int64(buffer.frameLength)
            }
        }
        let invertRight = cross < -0.01 * sqrt(leftPower*rightPower)
        let writer = try AVAudioFile(forWriting: output, settings: settings(sampleRate: format.sampleRate, channels: Int(format.channelCount)))
        input.framePosition = selection.startFrame
        var remaining = selection.endFrame-selection.startFrame
        while remaining > 0 {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(8192,remaining)))
            guard buffer.frameLength > 0 else { throw AudioError.invalid("原音の読み取りが途中で終了しました。") }
            if invertRight { for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![1][frame] *= -1 } }
            try writer.write(from: buffer); remaining -= Int64(buffer.frameLength)
        }
        return invertRight
    }
    private static func renderProcessed(inputURL: URL, selection: AudioSelection, output: URL, invertRight: Bool) throws {
        let input = try AVAudioFile(forReading: inputURL), engine = AVAudioEngine(), player = AVAudioPlayerNode(), pitch = AVAudioUnitTimePitch()
        let format = input.processingFormat
        let writer = try AVAudioFile(forWriting: output, settings: settings(sampleRate: format.sampleRate, channels: Int(format.channelCount)))
        engine.attach(player); engine.attach(pitch)
        engine.connect(player, to: pitch, format: format); engine.connect(pitch, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        player.scheduleFile(input, at: nil)
        pitch.rate = Float(selection.rate); pitch.pitch = Float(selection.pitchSemitones * 100)
        try engine.start(); player.play()
        defer { player.stop(); engine.stop(); engine.disableManualRenderingMode() }
        var written: Int64 = 0, retries = 0
        while written < selection.outputFrames {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(Int64(buffer.frameCapacity),selection.outputFrames-written))
            switch try engine.renderOffline(count, to: buffer) {
            case .success:
                guard buffer.frameLength > 0 else { throw AudioError.invalid("書き出し音声が空です。") }
                if invertRight { for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![1][frame] *= -1 } }
                applyFades(buffer, offset: written, selection: selection)
                retries = 0; try writer.write(from: buffer); written += Int64(buffer.frameLength)
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                retries += 1; if retries > 64 { throw AudioError.invalid("音声エンジンから十分なデータを取得できません。") }
            case .error: throw AudioError.invalid("音声エンジンの書き出しに失敗しました。")
            @unknown default: throw AudioError.invalid("未対応の書き出し状態です。")
            }
        }
    }
}

/// Ownership transfers from the file-opening task to the main actor before use.
/// The file is never read or mutated concurrently by application code.
struct PreparedPreviewFile: @unchecked Sendable {
    let file: AVAudioFile
}

@MainActor final class AudioPreview: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentURL: URL?
    @Published private(set) var currentStartFrame: Int64?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var activeFile: AVAudioFile?
    private var openingTask: Task<PreparedPreviewFile, Error>?
    private var generation = UUID()
    private var requestedVolume: Float = 0.75
    private var nextFrameToSchedule: Int64 = 0
    var outputVolume: Float { engine?.mainMixerNode.outputVolume ?? requestedVolume }
    private let openFile: @Sendable (URL) async throws -> PreparedPreviewFile

    init(openFile: @escaping @Sendable (URL) async throws -> PreparedPreviewFile = { url in
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url)
        try Task.checkCancellation()
        return PreparedPreviewFile(file: file)
    }) {
        self.openFile = openFile
    }

    /// Opens just the audio header off the UI thread and schedules the source file.
    /// It does not wait for waveform analysis, read a whole PCM buffer, or render a WAV.
    func playFile(_ url: URL, volume: Double, loop: Bool, startingFrame: Int64 = 0) async throws {
        stop()
        requestedVolume = Self.safeVolume(volume)
        let token = generation
        let opener = openFile
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let prepared = try await opener(url)
            try Task.checkCancellation()
            return prepared
        }
        openingTask = work
        do {
            let prepared = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            openingTask = nil
            try start(prepared.file, url: url, loop: loop, startingFrame: startingFrame, token: token)
        } catch {
            // A late open/error must never stop a newer selection.
            if generation == token { stop() }
            throw error
        }
    }

    private func start(_ file: AVAudioFile, url: URL, loop: Bool, startingFrame: Int64, token: UUID) throws {
        let format = file.processingFormat
        guard file.length > 0, (1...8).contains(format.channelCount), format.sampleRate.isFinite, format.sampleRate > 0 else {
            throw AudioError.invalid("空の音声、または 8 ch を超える形式は未対応です。")
        }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = requestedVolume
        self.engine = engine
        self.player = player
        activeFile = file
        currentURL = url
        currentStartFrame = min(max(0, startingFrame), file.length - 1)
        scheduleCycle(file, on: player, loop: loop, token: token)
        try engine.start()
        player.play()
        isPlaying = true
    }

    private func scheduleCycle(_ file: AVAudioFile, on player: AVAudioPlayerNode, loop: Bool, token: UUID) {
        nextFrameToSchedule = currentStartFrame ?? 0
        // Keep at most two segments queued. AVAudioFrameCount is UInt32, while
        // a long source and its seek offset can have more than UInt32.max frames.
        scheduleNextSegment(file, on: player, loop: loop, token: token)
        scheduleNextSegment(file, on: player, loop: loop, token: token)
    }

    static func segmentFrameCount(startingAt frame: Int64, fileLength: Int64) -> AVAudioFrameCount {
        guard frame >= 0, fileLength > frame else { return 0 }
        return AVAudioFrameCount(min(Int64(AVAudioFrameCount.max), fileLength - frame))
    }

    private func scheduleNextSegment(_ file: AVAudioFile, on player: AVAudioPlayerNode, loop: Bool, token: UUID) {
        let startFrame = nextFrameToSchedule
        let count = Self.segmentFrameCount(startingAt: startFrame, fileLength: file.length)
        guard count > 0 else { return }
        nextFrameToSchedule += Int64(count)
        let isLastSegment = nextFrameToSchedule == file.length
        // Refill before the queued audio runs out; only the final segment can
        // finish playback or loop, after its audio has actually reached output.
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: count, at: nil,
                               completionCallbackType: isLastSegment ? .dataPlayedBack : .dataConsumed) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token,
                      let player = self.player, let file = self.activeFile else { return }
                if !isLastSegment {
                    self.scheduleNextSegment(file, on: player, loop: loop, token: token)
                } else if loop {
                    // Reuse the open source and engine, preserving current volume.
                    self.scheduleCycle(file, on: player, loop: true, token: token)
                } else {
                    self.stop()
                }
            }
        }
    }

    private static func safeVolume(_ value: Double) -> Float {
        value.isFinite ? Float(min(1, max(0, value))) : 0
    }

    func setVolume(_ value: Double) {
        // A slider/mute change while a NAS header is opening must apply to the
        // eventual engine as well as any engine that is currently running.
        requestedVolume = Self.safeVolume(value)
        engine?.mainMixerNode.outputVolume = requestedVolume
    }

    func stop() {
        generation = UUID()
        openingTask?.cancel()
        openingTask = nil
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        activeFile = nil
        currentURL = nil
        currentStartFrame = nil
        nextFrameToSchedule = 0
        isPlaying = false
    }
}
