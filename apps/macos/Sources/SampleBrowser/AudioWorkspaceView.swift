import SwiftUI
import AppKit

struct AudioPanel: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var preview: AudioPreview

    var body: some View {
        VStack(spacing: 12) {
            header
            WaveformView(info: model.audio, selection: $model.selection, status: model.previewStatus, error: model.previewError, onSeek: model.playFromWaveform)
                .frame(height: 140)
            if let error = model.inlinePlaybackError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13)).foregroundStyle(StudioTheme.warning)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    .help(error)
            }
            HStack(alignment: .bottom, spacing: 20) {
                transport
                Rectangle().fill(StudioTheme.border).frame(width: 1, height: 48)
                processing
                    .disabled(!model.canEditAudio)
                    .opacity(model.canEditAudio ? 1 : 0.45)
                Spacer(minLength: 0)
                export
            }
            range
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .foregroundStyle(StudioTheme.text)
        .background(StudioTheme.surface)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(StudioTheme.cyan)
            Text(model.audioDisplayName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(StudioTheme.text)
                .lineLimit(1)
            Spacer(minLength: 20)
            Toggle("自動試聴", isOn: $model.autoPreview)
                .toggleStyle(.switch)
                .fixedSize()
                .help("上下キーやクリックで選んだサンプルをすぐに再生します。設定は自動保存されます")
            Rectangle().fill(StudioTheme.border).frame(width: 1, height: 18)
            if model.loadingAudio {
                ProgressView().controlSize(.small)
                Text("音声を読み込み中…")
            } else if let audio = model.audio {
                Text(String(format: "%.1f kHz", audio.sampleRate / 1_000))
                Circle().fill(StudioTheme.secondary.opacity(0.5)).frame(width: 3, height: 3)
                Text(audio.channels == 1 ? "MONO" : "\(audio.channels) CH")
                Circle().fill(StudioTheme.secondary.opacity(0.5)).frame(width: 3, height: 3)
                Text(String(format: "%.3f 秒", audio.duration)).monospacedDigit()
            } else {
                Text("試聴・範囲選択・サウンドの調整")
            }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(StudioTheme.secondary)
        .frame(height: 24)
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button(action: model.togglePlayback) {
                ZStack {
                    if model.playbackPending {
                        ProgressView().controlSize(.small).tint(StudioTheme.background).scaleEffect(1.5)
                            .accessibilityHidden(true)
                    }
                    Image(systemName: preview.isPlaying || model.playbackPending ? "stop.fill" : "play.fill")
                        .font(.system(size: model.playbackPending ? 13 : 22, weight: .semibold))
                }
                    .foregroundStyle(StudioTheme.background)
                    .frame(width: 56, height: 56)
                    .background(StudioTheme.accent, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .opacity(model.canTogglePlayback ? 1 : 0.38)
            .disabled(!model.canTogglePlayback)
            .help(model.playbackPending ? "試聴の準備をキャンセル（スペース）" : preview.isPlaying ? "停止（スペース）" : "選択範囲を再生（スペース）")
            .accessibilityLabel(model.playbackPending ? "試聴の準備をキャンセル" : preview.isPlaying ? "停止" : "選択範囲を再生")

            Button { model.loop.toggle() } label: {
                Image(systemName: "repeat")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(model.loop ? StudioTheme.accent : StudioTheme.secondary)
                    .frame(width: 44, height: 44)
                    .background(model.loop ? StudioTheme.accent.opacity(0.13) : StudioTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(model.loop ? StudioTheme.accent.opacity(0.45) : StudioTheme.border))
            }
            .buttonStyle(.plain)
            .help("選択範囲を繰り返し再生")
            .accessibilityLabel("リピート再生")
            .accessibilityValue(model.loop ? "オン" : "オフ")

            VStack(alignment: .leading, spacing: 8) {
                Label("音量", systemImage: "speaker.wave.2")
                    .font(.system(size: 14))
                    .foregroundStyle(StudioTheme.secondary)
                Slider(value: $model.volume, in: 0...1)
                    .tint(StudioTheme.secondary)
                    .accessibilityLabel("音量")
            }
            .frame(width: 82)
            .padding(.leading, 2)
        }
        .frame(height: 66)
    }

    private var processing: some View {
        HStack(alignment: .bottom, spacing: 12) {
            bpmField("元 BPM", text: $model.sourceBPMText)
            bpmField("目標 BPM", text: $model.targetBPMText)
                .disabled(model.selection.sourceBPM == nil)
                .opacity(model.selection.sourceBPM == nil ? 0.45 : 1)
            VStack(alignment: .leading, spacing: 6) {
                Text("移調 / 半音").font(.system(size: 14)).foregroundStyle(StudioTheme.secondary)
                HStack(spacing: 0) {
                    pitchButton("minus", label: "1 半音下げる", delta: -1)
                    Text(String(format: "%+.0f", model.selection.pitchSemitones))
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .frame(width: 39)
                    pitchButton("plus", label: "1 半音上げる", delta: 1)
                }
                .frame(height: 42)
                .background(StudioTheme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(StudioTheme.border))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("出力の長さ").font(.system(size: 14)).foregroundStyle(StudioTheme.secondary)
                Text(model.audio.map { String(format: "%.3f s", Double(model.selection.outputFrames) / $0.sampleRate) } ?? "—")
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .frame(height: 42, alignment: .leading)
                    .lineLimit(1)
            }
            .frame(width: 96, alignment: .leading)
            .padding(.leading, 4)
        }
    }

    private var export: some View {
        HStack(spacing: 10) {
            Menu {
                Button { model.render(forExport: true) } label: {
                    Label("WAV として書き出す", systemImage: "square.and.arrow.up")
                }
                .disabled(model.audio == nil || model.rendering)
                if let url = model.exportURL {
                    Button("書き出した WAV を Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold))
                    .frame(width: 28, height: 44)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("書き出しの操作")
            .accessibilityLabel("書き出しの操作")
            FileDragView(url: model.dragURL, status: model.dragStatus)
                .frame(width: 224, height: 56)
                .help(model.dragError ?? (model.preparingDrag ? (model.loadingAudio ? "原音を確認しています" : "現在の加工を準備しています") : "DAW にドラッグして追加できます"))
        }
        .frame(height: 66)
    }

    private var range: some View {
        HStack(spacing: 12) {
            Image(systemName: "selection.pin.in.out")
                .font(.system(size: 16))
                .foregroundStyle(StudioTheme.cyan)
            Text("選択範囲").font(.system(size: 14, weight: .medium)).foregroundStyle(StudioTheme.secondary)
            frameField("開始", value: $model.selection.startFrame)
                .disabled(!model.canEditAudio)
            Text("→").font(.system(size: 15)).foregroundStyle(StudioTheme.secondary)
            frameField("終了", value: $model.selection.endFrame)
                .disabled(!model.canEditAudio)
            Text("frames").font(.system(size: 14)).foregroundStyle(StudioTheme.secondary)
            Spacer(minLength: 12)
            if let error = model.dragError {
                Text(error).lineLimit(1).font(.system(size: 13)).foregroundStyle(StudioTheme.warning).help(error)
                Button("再試行") { model.render(forExport: true) }
                    .buttonStyle(.plain).foregroundStyle(StudioTheme.accent)
            } else if let url = model.dragURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label("Finder で表示", systemImage: "folder")
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(StudioTheme.accent)
            } else {
                Text(model.preparingDrag ? (model.loadingAudio ? "原音を確認しています" : "加工した音声を自動で準備しています") : "サンプルを選ぶとドラッグできます")
                    .font(.system(size: 14))
                    .foregroundStyle(StudioTheme.secondary)
            }
        }
        .frame(height: 36)
        .help("開始フレームから、終了フレームの直前までを選択します")
    }

    private func bpmField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 14)).foregroundStyle(StudioTheme.secondary)
            TextField("—", text: text)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .frame(width: 76, height: 42)
                .background(StudioTheme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(StudioTheme.border))
                .accessibilityLabel(label)
        }
    }

    private func pitchButton(_ symbol: String, label: String, delta: Double) -> some View {
        Button { model.selection.pitchSemitones = min(24, max(-24, model.selection.pitchSemitones + delta)) } label: {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 42)
        }
        .buttonStyle(.plain)
        .foregroundStyle(StudioTheme.secondary)
        .disabled(delta < 0 ? model.selection.pitchSemitones <= -24 : model.selection.pitchSemitones >= 24)
        .accessibilityLabel(label)
    }

    private func frameField(_ label: String, value: Binding<Int64>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 14)).foregroundStyle(StudioTheme.secondary)
            TextField(label, value: value, format: .number.grouping(.never))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(width: 104)
                .accessibilityLabel("選択範囲の\(label)フレーム")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(StudioTheme.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(StudioTheme.border))
    }
}

struct WaveformView: View {
    private enum DragTarget: Equatable {
        case handle(isStart: Bool, offset: CGFloat)
        case audition
    }
    @State private var dragTarget: DragTarget?
    @State private var movedHandle = false
    @State private var gestureSourceURL: URL?
    @State private var gestureCancelled = false
    @GestureState private var gestureActive = false
    let info: AudioInfo?
    @Binding var selection: AudioSelection
    var status = ""
    var error: String?
    var onSeek: (Int64) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(StudioTheme.background)
                Canvas { context, size in
                    let waveHeight = max(1, size.height - 26)
                    drawGrid(context: &context, size: size, waveHeight: waveHeight)
                    guard let info, info.totalFrames > 0 else { return }
                    let start = xPosition(selection.startFrame, total: info.totalFrames, width: size.width)
                    let end = xPosition(selection.endFrame, total: info.totalFrames, width: size.width)
                    context.fill(Path(CGRect(x: start, y: 0, width: max(0, end - start), height: waveHeight)), with: .color(StudioTheme.accent.opacity(0.075)))
                    let channelHeight = waveHeight / CGFloat(max(1, info.channels))
                    for (channel, peaks) in info.peaks.enumerated() {
                        let mid = (CGFloat(channel) + 0.5) * channelHeight
                        var center = Path()
                        center.move(to: CGPoint(x: 0, y: mid))
                        center.addLine(to: CGPoint(x: size.width, y: mid))
                        context.stroke(center, with: .color(StudioTheme.cyan.opacity(0.1)), lineWidth: 1)
                        var path = Path()
                        for (index, peak) in peaks.enumerated() {
                            let x = CGFloat(index) / CGFloat(max(1, peaks.count)) * size.width
                            path.move(to: CGPoint(x: x, y: mid - CGFloat(peak.maximum) * channelHeight * 0.40))
                            path.addLine(to: CGPoint(x: x, y: mid - CGFloat(peak.minimum) * channelHeight * 0.40))
                        }
                        context.stroke(path, with: .color(StudioTheme.cyan.opacity(0.9)), lineWidth: max(1, size.width / 1100))
                        if channel > 0 {
                            var separator = Path()
                            separator.move(to: CGPoint(x: 0, y: CGFloat(channel) * channelHeight))
                            separator.addLine(to: CGPoint(x: size.width, y: CGFloat(channel) * channelHeight))
                            context.stroke(separator, with: .color(StudioTheme.border.opacity(0.7)), lineWidth: 1)
                        }
                    }
                    context.fill(Path(CGRect(x: 0, y: 0, width: start, height: waveHeight)), with: .color(StudioTheme.background.opacity(0.63)))
                    context.fill(Path(CGRect(x: end, y: 0, width: max(0, size.width - end), height: waveHeight)), with: .color(StudioTheme.background.opacity(0.63)))
                    drawHandle(context: &context, x: start, size: size, height: waveHeight, isStart: true)
                    drawHandle(context: &context, x: end, size: size, height: waveHeight, isStart: false)
                    for channel in 0..<info.channels {
                        let label = info.channels == 1 ? "M" : info.channels == 2 ? (channel == 0 ? "L" : "R") : "\(channel + 1)"
                        let point = CGPoint(x: 23, y: (CGFloat(channel) + 0.5) * channelHeight)
                        if info.channels < 6 {
                            context.fill(Path(roundedRect: CGRect(x: 12, y: point.y - 10, width: 22, height: 20), cornerRadius: 5), with: .color(StudioTheme.surface.opacity(0.94)))
                        }
                        context.draw(Text(label).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundColor(StudioTheme.secondary), at: point)
                    }
                    for tick in 0...4 {
                        let fraction = CGFloat(tick) / 4
                        let label = String(format: "%.2f s", info.duration * Double(fraction))
                        let x = max(12, min(size.width - 12, fraction * size.width))
                        context.draw(Text(label).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundColor(StudioTheme.secondary), at: CGPoint(x: x, y: waveHeight + 13), anchor: tick == 0 ? .leading : tick == 4 ? .trailing : .center)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                if info == nil {
                    HStack(spacing: 14) {
                        Image(systemName: error == nil ? "waveform.path" : "exclamationmark.triangle").font(.system(size: 30, weight: .light)).foregroundStyle(error == nil ? StudioTheme.cyan.opacity(0.7) : StudioTheme.warning)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(error == nil ? (status.isEmpty ? "サウンドを選ぶと、波形をプレビュー" : status) : "音声を読み込めませんでした")
                                .font(.system(size: 16, weight: .medium)).foregroundStyle(StudioTheme.text)
                            Text(error ?? "クリックでその位置から試聴。ハンドルのドラッグで範囲を選択できます")
                                .font(.system(size: 14)).foregroundStyle(StudioTheme.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudioTheme.border))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).updating($gestureActive) { _, active, _ in active = true }.onChanged { value in
                guard !gestureCancelled else { return }
                guard let info, info.totalFrames > 0, geometry.size.width > 0 else { gestureCancelled = true; return }
                if dragTarget == nil {
                    gestureSourceURL = info.url
                    let startX = xPosition(selection.startFrame, total: info.totalFrames, width: geometry.size.width)
                    let endX = xPosition(selection.endFrame, total: info.totalFrames, width: geometry.size.width)
                    let waveHeight = max(1, geometry.size.height - 26)
                    let startHandle = handlePosition(x: startX, width: geometry.size.width, height: waveHeight, isStart: true)
                    let endHandle = handlePosition(x: endX, width: geometry.size.width, height: waveHeight, isStart: false)
                    let startDistance = hypot(value.startLocation.x - startHandle.x, value.startLocation.y - startHandle.y)
                    let endDistance = hypot(value.startLocation.x - endHandle.x, value.startLocation.y - endHandle.y)
                    if min(startDistance, endDistance) <= 28 {
                        let isStart = startDistance < endDistance
                        // Keep the frame stationary when grabbing a handle inset from an edge.
                        dragTarget = .handle(isStart: isStart, offset: (isStart ? startX : endX) - value.startLocation.x)
                    } else {
                        dragTarget = .audition
                    }
                }
                // A press/click never edits the selection, including on a handle.
                // Only a gesture that started on a handle can resize the range.
                guard gestureSourceURL == info.url,
                      hypot(value.translation.width, value.translation.height) >= 4,
                      case let .handle(isStart, offset) = dragTarget else { return }
                movedHandle = true
                let fraction = max(0, min(1, (value.location.x + offset) / geometry.size.width))
                let frame = min(info.totalFrames, Int64(fraction * Double(info.totalFrames)))
                if isStart {
                    let end = max(1, min(info.totalFrames, selection.endFrame))
                    selection.startFrame = min(frame, end - 1)
                } else {
                    let start = max(0, min(info.totalFrames - 1, selection.startFrame))
                    selection.endFrame = max(frame, start + 1)
                }
            }.onEnded { value in
                defer { resetGesture() }
                guard !gestureCancelled, !movedHandle, hypot(value.translation.width, value.translation.height) < 4,
                      let info, gestureSourceURL == info.url, info.totalFrames > 0, geometry.size.width > 0 else { return }
                let fraction = max(0, min(1, value.location.x / geometry.size.width))
                onSeek(min(info.totalFrames - 1, Int64(fraction * Double(info.totalFrames))))
            })
            .onChange(of: info?.url) { _, _ in if gestureActive { gestureCancelled = true } }
            .onChange(of: info?.fingerprint) { _, _ in if gestureActive { gestureCancelled = true } }
            .onChange(of: gestureActive) { _, active in if !active { resetGesture() } }
            .help("クリックした位置から再生します。開始・終了ハンドルをドラッグすると範囲を変更できます")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("音声波形。クリックした位置から再生。選択範囲はハンドルのドラッグ、または下の開始・終了フレーム欄で変更できます")
        }
    }

    private func resetGesture() {
        dragTarget = nil; movedHandle = false; gestureSourceURL = nil; gestureCancelled = false
    }

    private func xPosition(_ frame: Int64, total: Int64, width: CGFloat) -> CGFloat {
        CGFloat(max(0, min(total, frame))) / CGFloat(total) * width
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize, waveHeight: CGFloat) {
        for tick in 0...16 {
            let x = CGFloat(tick) / 16 * size.width
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: waveHeight))
            context.stroke(line, with: .color(StudioTheme.border.opacity(tick.isMultiple(of: 4) ? 0.65 : 0.25)), lineWidth: 1)
        }
        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: waveHeight))
        baseline.addLine(to: CGPoint(x: size.width, y: waveHeight))
        context.stroke(baseline, with: .color(StudioTheme.border), lineWidth: 1)
    }

    private func handlePosition(x: CGFloat, width: CGFloat, height: CGFloat, isStart: Bool) -> CGPoint {
        CGPoint(x: max(12, min(width - 12, x)), y: isStart ? 16 : height - 16)
    }

    private func drawHandle(context: inout GraphicsContext, x: CGFloat, size: CGSize, height: CGFloat, isStart: Bool) {
        let lineX = max(1, min(size.width - 1, x))
        context.fill(Path(CGRect(x: lineX - 1, y: 0, width: 2, height: height)), with: .color(StudioTheme.accent))
        let position = handlePosition(x: x, width: size.width, height: height, isStart: isStart)
        let handleX = position.x
        let handleY = position.y
        context.fill(Path(roundedRect: CGRect(x: handleX - 10, y: handleY - 12, width: 20, height: 24), cornerRadius: 6), with: .color(StudioTheme.accent))
        for offset in [-2.0, 2.0] {
            context.fill(Path(roundedRect: CGRect(x: handleX + offset - 0.7, y: handleY - 5, width: 1.4, height: 10), cornerRadius: 0.7), with: .color(StudioTheme.background.opacity(0.7)))
        }
    }
}

struct FileDragView: NSViewRepresentable {
    let url: URL?
    let status: String
    func makeNSView(context: Context) -> FileDragNSView { FileDragNSView() }
    func updateNSView(_ view: FileDragNSView, context: Context) {
        view.fileURL = url
        view.status = status
        view.needsDisplay = true
        view.toolTip = url == nil ? status : "DAW にドラッグして追加。クリックすると Finder で表示します"
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel("DAW へドラッグ")
        view.setAccessibilityValue(status)
        view.setAccessibilityHelp("この領域から DAW へドラッグします。クリックすると対象の音声を Finder で表示します")
        view.setAccessibilityRole(.button)
        view.setAccessibilityEnabled(url != nil)
    }
}

final class FileDragNSView: NSView, NSDraggingSource {
    var fileURL: URL? { didSet { window?.invalidateCursorRects(for: self) } }
    var status = "サンプルを選択してください"
    private var startedDrag = false
    private var mouseDownURL: URL?

    override var acceptsFirstResponder: Bool { fileURL != nil }

    override func resetCursorRects() {
        if fileURL != nil { addCursorRect(bounds, cursor: .openHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let ready = fileURL != nil
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        StudioTheme.accentNS.withAlphaComponent(ready ? 0.13 : 0.04).setFill()
        path.fill()
        StudioTheme.accentNS.withAlphaComponent(ready ? 0.55 : 0.22).setStroke()
        path.lineWidth = 1
        if !ready { path.setLineDash([4, 4], count: 2, phase: 0) }
        path.stroke()
        let main = "DAW へドラッグ"
        let subtitle = status
        let color = ready ? StudioTheme.accentNS : NSColor(calibratedRed: 0.65, green: 0.66, blue: 0.73, alpha: 1)
        let mainAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: color]
        let subAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .regular), .foregroundColor: color.withAlphaComponent(0.8)]
        let mainSize = main.size(withAttributes: mainAttributes)
        let subSize = subtitle.size(withAttributes: subAttributes)
        main.draw(at: NSPoint(x: (bounds.width - mainSize.width) / 2 + 9, y: bounds.height / 2 + 1), withAttributes: mainAttributes)
        subtitle.draw(at: NSPoint(x: (bounds.width - subSize.width) / 2, y: bounds.height / 2 - 18), withAttributes: subAttributes)
        if let symbol = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)) {
            let tinted = symbol.copy() as! NSImage
            tinted.lockFocus()
            color.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(x: (bounds.width - mainSize.width) / 2 - 13, y: bounds.height / 2 + 3, width: 15, height: 15))
        }
    }

    override func mouseDown(with event: NSEvent) {
        startedDrag = false
        mouseDownURL = fileURL
    }

    override func mouseUp(with event: NSEvent) {
        guard !startedDrag, mouseDownURL == fileURL, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        _ = accessibilityPerformPress()
    }

    override func accessibilityPerformPress() -> Bool {
        guard let url = fileURL else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            _ = accessibilityPerformPress()
        } else {
            super.keyDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !startedDrag, let url = mouseDownURL, url == fileURL else { return }
        startedDrag = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: NSImage(systemSymbolName: "waveform", accessibilityDescription: "音声ファイル"))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
