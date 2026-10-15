import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The preview pipeline has independent I/O so delayed NAS responses can be
/// exercised without a live server or Keychain interaction.
struct BrowserPreviewIO: Sendable {
    var detail: @Sendable (UUID) async throws -> SampleDetail
    var download: @Sendable (Sample, URL) async throws -> URL
    var load: @Sendable (URL) throws -> AudioInfo
    var play: (@MainActor @Sendable (URL, Double, Bool) async throws -> Void)? = nil
    var stop: (@MainActor @Sendable () -> Void)? = nil
    var render: (@Sendable (AudioInfo, AudioSelection, URL) async throws -> URL)? = nil
    var seek: (@MainActor @Sendable (URL, Double, Bool, Int64) async throws -> Void)? = nil
    var header: (@Sendable (URL) throws -> AudioSourceMetadata)? = nil
}

@MainActor final class BrowserModel: ObservableObject {
    @Published var samples: [Sample] = []
    @Published var selectedID: UUID? { didSet { if oldValue != selectedID { selectRemote() } } }
    @Published var detail: SampleDetail?
    @Published var tags: [LibraryTag] = []
    @Published var query = "" { didSet { searchSoon() } }
    @Published var favoritesOnly = false { didSet { searchSoon() } }
    @Published var kind = "all" { didSet { searchSoon() } }
    @Published var sort = "name" { didSet { searchSoon() } }
    @Published var bpmMin = ""
    @Published var bpmMax = ""
    @Published var searching = false
    @Published var connected = false
    @Published var status = "NAS 未接続 · ローカル音声を開いて始められます"
    @Published var error: String?
    @Published var saveStatus = ""
    @Published var saving = false
    @Published var hasMore = false
    @Published var pageNumber = 1
    @Published var audio: AudioInfo?
    @Published var loadingAudio = false
    @Published var previewStatus = ""
    @Published var previewError: String?
    @Published private(set) var playbackPending = false
    @Published var selection = AudioSelection() { didSet { if oldValue != selection && !initializingAudio { invalidateRender() } } }
    @Published var loop = false { didSet { stopPlayback() } }
    @Published var volume = 0.75 { didSet { preview.setVolume(volume) } }
    @Published var rendering = false
    @Published var exportURL: URL?
    @Published var previewURL: URL?
    @Published private(set) var dragURL: URL?
    @Published private(set) var dragStatus = "サンプルを選択してください"
    @Published private(set) var preparingDrag = false
    @Published private(set) var dragError: String?
    @Published var autoPreview: Bool {
        didSet {
            preferences.set(autoPreview, forKey: Self.autoPreviewKey)
            if !autoPreview {
                autoplayGeneration = nil
                if playbackIsAutomatic { stopPlayback() }
            }
        }
    }
    @Published var showPlaybackSettings = false
    static let autoPreviewKey = "sampleBrowser.autoPreview"
    @Published var sourceBPMText = "" {
        didSet {
            let previous = selection
            selection.sourceBPM = Double(sourceBPMText)
            if sourceBPMText.isEmpty { targetBPMText = "" }
            if !initializingAudio && oldValue != sourceBPMText && previous == selection { invalidateRender() }
        }
    }
    @Published var targetBPMText = "" {
        didSet {
            let previous = selection
            selection.targetBPM = Double(targetBPMText)
            if !initializingAudio && oldValue != targetBPMText && previous == selection { invalidateRender() }
        }
    }
    @Published var annotationBPM = ""
    @Published var annotationNotes = ""
    @Published var showSettings = false
    var localAudioSourceURL: URL? { localAudioURL }
    var audioDisplayName: String {
        if let selectedID { return detail?.sample.name ?? samples.first(where: { $0.id == selectedID })?.name ?? "プレビュー" }
        return localAudioURL?.lastPathComponent ?? audio?.url.lastPathComponent ?? "プレビュー"
    }
    var canTogglePlayback: Bool { audio != nil || rawSourceURL != nil || playbackValidationTask != nil || preview.isPlaying }
    var canEditAudio: Bool { audio != nil }
    var inlinePlaybackError: String? { audio == nil ? nil : previewError }
    let preview = AudioPreview()
    let exportDirectory: URL
    let cacheDirectory: URL
    private var searchTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var loadTask: Task<AudioInfo, Error>?
    private var headerTask: Task<AudioSourceMetadata, Error>?
    private var originalDragTask: Task<Void, Never>?
    private var sourceWatchTask: Task<Void, Never>?
    private var sourceWatchGeneration = UUID()
    private var playbackValidationTask: Task<Void, Never>?
    private var renderTask: Task<URL, Error>?
    private var dragPreparationTask: Task<Void, Never>?
    private var auditionRenderTask: Task<URL, Error>?
    private var playbackGeneration = UUID()
    private var autoplayGeneration: UUID?
    private var playbackIsAutomatic = false
    private var initializingAudio = false
    private var rawSourceURL: URL?
    private var originalDragSource: AudioSourceMetadata?
    private let preferences: UserDefaults
    private var searchGeneration = UUID(), audioGeneration = UUID(), renderGeneration = UUID()
    private var startupHandled = false
    private var sessionConnection: ConnectionSettings?
    private var sessionConnectionRequested = false
    private var sessionConnectionLoader: Task<ConnectionSettings, Error>?
    private var connectionGeneration = UUID()
    private var nextCursor: String?
    private var cursors: [String?] = [nil]
    private let previewIO: BrowserPreviewIO?
    private var localAudioURL: URL?
    init(previewIO: BrowserPreviewIO? = nil, preferences: UserDefaults = .standard, exportDirectory: URL? = nil, cacheDirectory: URL? = nil) {
        self.previewIO = previewIO
        self.preferences = preferences
        autoPreview = preferences.object(forKey: Self.autoPreviewKey) as? Bool ?? true
        self.exportDirectory = exportDirectory ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("Sample Browser Exports", isDirectory: true)
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("jp.samplebrowser/preview", isDirectory: true)
    }
    func handleStartup() {
        guard !startupHandled else { return }; startupHandled = true
        let args = CommandLine.arguments
        sessionConnectionRequested = args.contains("--session-connection-file")
        Task {
            do {
                let persistentIndex = args.firstIndex(of: "--connection-file")
                let sessionIndex = args.firstIndex(of: "--session-connection-file")
                guard persistentIndex == nil || sessionIndex == nil else { throw APIError(status: 0, message: "接続ファイルの起動オプションは 1 つだけ指定してください。") }
                if let index = sessionIndex ?? persistentIndex {
                    guard args.count > index + 1, !args[index + 1].hasPrefix("--") else { throw APIError(status: 0, message: "接続ファイルのパスを指定してください。") }
                    let url = URL(fileURLWithPath: args[index + 1])
                    let loader = Task.detached(priority: .userInitiated) { try ConnectionSettings.fromFile(url) }
                    if sessionIndex != nil { sessionConnectionLoader = loader }
                    let settings = try await loader.value
                    if sessionIndex != nil { sessionConnection = settings; connectionGeneration = UUID() }
                    else { try await settings.save() }
                    refresh()
                } else if args.contains("--shared-index"), !ConnectionSettings().libraryID.isEmpty { refresh() }
            } catch { self.error = error.localizedDescription }
        }
        // Opening local audio must remain usable while Keychain awaits approval.
        if let index = args.firstIndex(of: "--open"), args.count > index + 1 { openLocal(URL(fileURLWithPath: args[index+1])) }
        else if let arg = args.dropFirst().first, !arg.hasPrefix("-"), FileManager.default.fileExists(atPath: arg) { openLocal(URL(fileURLWithPath: arg)) }
    }
    func useSavedConnection() {
        sessionConnectionRequested = false; sessionConnectionLoader = nil; sessionConnection = nil
        connectionGeneration = UUID(); refresh()
    }
    private func client() async throws -> APIClient {
        if sessionConnectionRequested {
            if let sessionConnection { return try await sessionConnection.client() }
            if let sessionConnectionLoader { return try await sessionConnectionLoader.value.client() }
            throw APIError(status: 0, message: "今回の起動用の接続ファイルを読み込めません。起動オプションを確認してください。")
        }
        return try await ConnectionSettings().client()
    }
    func searchSoon() {
        searchTask?.cancel()
        let generation = UUID(); searchGeneration = generation
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, generation == searchGeneration else { return }
            cursors = [nil]; pageNumber = 1
            await fetchPage(cursor: nil, generation: generation)
        }
    }
    func refresh() {
        searchSoon()
        let generation = connectionGeneration
        Task {
            do {
                let items = try await client().tags().items
                guard generation == connectionGeneration else { return }
                tags = items
            } catch { /* Search provides connection errors. */ }
        }
    }
    private func fetchPage(cursor: String?, generation: UUID) async {
        searching = true; defer { if generation == searchGeneration { searching = false } }
        do {
            let minimum = try APIClient.parseBPMBound(bpmMin), maximum = try APIClient.parseBPMBound(bpmMax)
            let client = try await client()
            let page = try await client.search(text: query, favorite: favoritesOnly, bpmMinimum: minimum, bpmMaximum: maximum, kind: kind, sort: sort, cursor: cursor)
            guard !Task.isCancelled, generation == searchGeneration else { return }
            samples = page.items; nextCursor = page.nextCursor; hasMore = page.hasMore; connected = true
            status = "NAS 接続済み · ページ \(pageNumber) · \(samples.count) 件表示"
        } catch is CancellationError { } catch {
            guard generation == searchGeneration else { return }
            connected = false; status = "NAS 接続エラー"; self.error = error.localizedDescription
        }
    }
    func nextPage() {
        guard hasMore, let nextCursor, !searching else { return }
        if cursors.count >= 30 { cursors.removeFirst() }
        cursors.append(nextCursor); pageNumber += 1
        let generation = UUID(); searchGeneration = generation
        searchTask = Task { await fetchPage(cursor: nextCursor, generation: generation) }
    }
    func previousPage() {
        guard cursors.count > 1, !searching else { return }
        cursors.removeLast(); pageNumber = max(1, pageNumber - 1)
        let cursor = cursors.last ?? nil, generation = UUID(); searchGeneration = generation
        searchTask = Task { await fetchPage(cursor: cursor, generation: generation) }
    }
    private func selectRemote() {
        detailTask?.cancel(); cancelAudio(); detail = nil; localAudioURL = nil; saveStatus = ""
        guard let id = selectedID else { return }
        let generation = audioGeneration
        autoplayGeneration = autoPreview ? generation : nil
        loadingAudio = true; previewStatus = "サンプル情報を取得中…"
        detailTask = Task {
            do {
                let value: SampleDetail
                if let previewIO { value = try await previewIO.detail(id) }
                else { value = try await client().detail(id) }
                guard !Task.isCancelled, selectedID == id, generation == audioGeneration else { return }
                detail = value; annotationBPM = value.sample.bpm.map { String($0) } ?? ""; annotationNotes = value.annotations.notes
                sourceBPMText = value.sample.bpm.map { String($0) } ?? ""
                downloadRemoteAudio(value.sample, generation: generation)
            } catch is CancellationError { } catch {
                guard !Task.isCancelled, selectedID == id, generation == audioGeneration else { return }
                failPreview(error)
            }
        }
    }
    func selectRemoteSample(_ id: UUID) {
        if selectedID == id { if audio == nil && !loadingAudio { selectRemote() } }
        else { selectedID = id }
    }
    func favoriteAliasKey(_ id: UUID) -> String {
        let settings = sessionConnection ?? ConnectionSettings()
        let server = settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(server)|\(settings.libraryID.lowercased())|\(id.uuidString.lowercased())"
    }
    /// Context menus act on their clicked row, even when a different row is selected.
    func setRemoteFavorite(sampleID: UUID, value: Bool) {
        guard connected, !saving else { return }
        saving = true; saveStatus = "保存中…"
        let generation = connectionGeneration
        Task {
            defer { saving = false }
            do {
                let client = try await client()
                let snapshot = try await client.detail(sampleID)
                guard generation == connectionGeneration else { return }
                _ = try await client.favorite(sampleID, value: value, version: snapshot.favoriteState.recordVersion)
                let updated = try await client.detail(sampleID)
                guard generation == connectionGeneration else { return }
                if selectedID == sampleID { detail = updated }
                if let index = samples.firstIndex(where: { $0.id == sampleID }) { samples[index] = updated.sample }
                saveStatus = "NAS に保存済み"
            } catch {
                guard generation == connectionGeneration else { return }
                saveStatus = "保存失敗"; self.error = error.localizedDescription
            }
        }
    }
    func toggleFavorite() { mutate { client, detail in _ = try await client.favorite(detail.sample.id, value: !detail.favoriteState.favorite, version: detail.favoriteState.recordVersion) } }
    func toggleTag(_ tag: LibraryTag) { mutate { client, detail in
        let exists = detail.sample.tagIds.contains(tag.id)
        _ = try await client.changeTags(detail.sample.id, add: exists ? [] : [tag.id], remove: exists ? [tag.id] : [], version: detail.sample.tagVersion)
    } }
    func saveAnnotation() {
        guard var value = detail?.annotations else { return }
        if !annotationBPM.isEmpty { guard let bpm = Double(annotationBPM), bpm.isFinite, bpm > 0 else { error = "BPM は正の数で入力してください。"; return }; value.bpmMode = "manual"; value.bpmValue = bpm }
        else { value.bpmMode = "auto"; value.bpmValue = nil }
        value.notes = annotationNotes
        mutate { client, detail in _ = try await client.annotate(detail.sample.id, value: value) }
    }
    private func mutate(_ operation: @escaping (APIClient, SampleDetail) async throws -> Void) {
        guard let snapshot = detail, !saving, connected else { return }
        saving = true; saveStatus = "保存中…"
        Task {
            do {
                let client = try await client()
                try await operation(client, snapshot)
                let updated = try await client.detail(snapshot.sample.id)
                if selectedID == snapshot.sample.id { detail = updated; saveStatus = "NAS に保存済み" }
                if let index = samples.firstIndex(where: { $0.id == snapshot.sample.id }) { samples[index] = updated.sample }
            } catch {
                if let api = error as? APIError, api.status == 412, let latest = try? await client().detail(snapshot.sample.id), selectedID == snapshot.sample.id { detail = latest }
                saveStatus = "保存失敗"; self.error = error.localizedDescription
            }
            saving = false
        }
    }
    func openLocal() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.wav, .aiff, UTType(filenameExtension: "flac") ?? .audio]; panel.allowsMultipleSelection = false
        panel.message = "原音は読み取り専用です。書き出しは別フォルダへ保存します。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openLocal(url)
    }
    func openLocal(_ url: URL) {
        clearSelectedAudio(); localAudioURL = url
        autoplayGeneration = autoPreview ? audioGeneration : nil
        beginLoad(url, bpm: nil)
    }
    /// A favorite's play action is explicit, independent of automatic selection playback.
    func playLocal(_ url: URL) {
        clearSelectedAudio(); localAudioURL = url
        beginLoad(url, bpm: nil)
        startPlayback(url, info: nil, automatic: false)
    }
    func clearSelectedAudio() {
        detailTask?.cancel(); detailTask = nil
        selectedID = nil; detail = nil; localAudioURL = nil; saveStatus = ""
        cancelAudio()
    }
    func loadRemoteAudio() {
        guard let sample = detail?.sample else { return }
        cancelAudio()
        autoplayGeneration = autoPreview ? audioGeneration : nil
        downloadRemoteAudio(sample, generation: audioGeneration)
    }
    private func downloadRemoteAudio(_ sample: Sample, generation: UUID) {
        loadingAudio = true; previewStatus = "NAS から音声を読み込み中…"
        audioTask = Task {
            do {
                let directory = cacheDirectory.appendingPathComponent("sources")
                let url: URL
                if let previewIO { url = try await previewIO.download(sample, directory) }
                else { url = try await client().download(sample, directory: directory) }
                guard !Task.isCancelled, generation == audioGeneration else { return }
                beginLoad(url, bpm: sample.bpm)
            } catch is CancellationError { } catch {
                guard !Task.isCancelled, generation == audioGeneration else { return }
                failPreview(error)
            }
        }
    }
    private func beginLoad(_ url: URL, bpm: Double?) {
        loadingAudio = true; previewStatus = "波形を作成中…"; previewError = nil
        let generation = audioGeneration
        rawSourceURL = url
        if autoplayGeneration == generation { startPlayback(url, info: nil, automatic: true) }
        let previewIO = previewIO
        // Dragging an untouched source needs only a validated header. Waveform
        // decoding and hashing may take much longer on a large NAS file.
        preparingDrag = true; dragStatus = "原音を確認中…"
        headerTask = Task.detached(priority: .userInitiated) { try previewIO?.header?(url) ?? AudioSourceMetadata.load(url) }
        let header = headerTask!
        originalDragTask = Task { [self] in
            do {
                let metadata = try await header.value
                guard !Task.isCancelled, generation == audioGeneration, rawSourceURL == url, audio == nil else { return }
                originalDragSource = metadata
                prepareDragSoon()
                watchSource(generation: generation) { try metadata.validateSource() }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, generation == audioGeneration, rawSourceURL == url, audio == nil else { return }
                preparingDrag = false; dragError = error.localizedDescription; dragStatus = "原音を確認できません"
            }
        }
        loadTask = Task.detached(priority: .userInitiated) { try previewIO?.load(url) ?? AudioInfo.load(url) }
        let task = loadTask!
        audioTask = Task { [self] in
            do {
                let info = try await task.value
                guard !Task.isCancelled, generation == audioGeneration else { return }
                originalDragTask?.cancel(); headerTask?.cancel()
                originalDragTask = nil; headerTask = nil; originalDragSource = nil
                // Waveform completion initializes editor values without stopping
                // the original-file playback that already started above.
                initializingAudio = true
                audio = info; selection = AudioSelection(startFrame: 0, endFrame: info.totalFrames)
                targetBPMText = ""; sourceBPMText = bpm.map { String($0) } ?? ""
                initializingAudio = false
                loadingAudio = false; previewStatus = "プレビュー準備完了"
                prepareDragSoon()
                watchSource(generation: generation) { try info.validateSource() }
            } catch is CancellationError { } catch {
                guard !Task.isCancelled, generation == audioGeneration else { return }
                failPreview(error)
            }
        }
    }
    private func watchSource(generation: UUID, validate: @escaping @Sendable () throws -> Void) {
        sourceWatchTask?.cancel()
        let watchToken = UUID(); sourceWatchGeneration = watchToken
        // Metadata reads on an unavailable SMB mount can block. Keep them
        // outside the main actor, including before the waveform is ready.
        sourceWatchTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)); try Task.checkCancellation(); try validate() }
                catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled else { return }
                    await self?.sourceDidChange(generation: generation, watchToken: watchToken, message: error.localizedDescription)
                    return
                }
            }
        }
    }
    private func failPreview(_ error: Error) {
        originalDragTask?.cancel(); headerTask?.cancel(); sourceWatchTask?.cancel()
        sourceWatchGeneration = UUID()
        originalDragTask = nil; headerTask = nil; sourceWatchTask = nil; originalDragSource = nil
        stopPlayback(); rawSourceURL = nil; audio = nil
        invalidateRender()
        loadingAudio = false; previewStatus = "プレビューを読み込めません"; previewError = error.localizedDescription
    }
    private func sourceDidChange(generation: UUID, watchToken: UUID, message: String) {
        guard audioGeneration == generation, sourceWatchGeneration == watchToken else { return }
        // Invalidate unfinished header/waveform work as well, so it cannot
        // republish a source after its early drag readiness was revoked.
        cancelAudio()
        previewStatus = "原音を確認してください"; previewError = message
    }
    func cancelAudio() {
        audioGeneration = UUID(); autoplayGeneration = nil
        sourceWatchGeneration = UUID()
        audioTask?.cancel(); loadTask?.cancel(); sourceWatchTask?.cancel(); headerTask?.cancel(); originalDragTask?.cancel()
        audioTask = nil; loadTask = nil; sourceWatchTask = nil; headerTask = nil; originalDragTask = nil; rawSourceURL = nil; originalDragSource = nil
        audio = nil; loadingAudio = false; previewStatus = ""; previewError = nil; invalidateRender()
    }
    func invalidateRender() {
        renderGeneration = UUID(); renderTask?.cancel(); renderTask = nil
        auditionRenderTask?.cancel(); auditionRenderTask = nil
        dragPreparationTask?.cancel(); dragPreparationTask = nil
        rendering = false; exportURL = nil; previewURL = nil
        dragURL = nil; preparingDrag = false; dragError = nil
        stopPlayback()
        prepareDragSoon()
    }
    /// An untouched selection can be played and dragged as the original file.
    /// Setting a source BPM alone is metadata, and does not change the audio.
    private func usesOriginal(_ info: AudioInfo, edit: AudioSelection) -> Bool {
        edit.startFrame == 0 && edit.endFrame == info.totalFrames && edit.rate == 1 && edit.pitchSemitones == 0 && edit.fadeInFrames == 0 && edit.fadeOutFrames == 0
    }
    private func validatedSelection(_ info: AudioInfo) throws {
        guard (sourceBPMText.isEmpty || Double(sourceBPMText) != nil), (targetBPMText.isEmpty || Double(targetBPMText) != nil) else { throw AudioError.invalid("BPM を数値で入力してください。") }
        try selection.validate(totalFrames: info.totalFrames, sampleRate: info.sampleRate)
    }
    private func prepareDragSoon() {
        guard let info = audio else {
            if let source = originalDragSource {
                dragURL = source.url; preparingDrag = false; dragError = nil; dragStatus = "原音を DAW へドラッグ"
            } else if loadingAudio, rawSourceURL != nil {
                preparingDrag = true; dragStatus = "原音を確認中…"
            } else { dragStatus = "サンプルを選択してください" }
            return
        }
        do { try validatedSelection(info) }
        catch { dragURL = nil; preparingDrag = false; dragError = error.localizedDescription; dragStatus = "編集内容を確認してください"; return }
        if usesOriginal(info, edit: selection) {
            dragURL = info.url; preparingDrag = false; dragError = nil; dragStatus = "原音を DAW へドラッグ"
            return
        }
        // Edited files are published in the durable export folder. A DAW may
        // keep a reference to this URL instead of immediately copying its bytes.
        let edit = selection, generation = renderGeneration
        dragURL = nil; preparingDrag = true; dragError = nil; dragStatus = "編集した音声を準備中…"
        dragPreparationTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(220))
                try Task.checkCancellation()
                _ = try await renderedAudio(info: info, edit: edit, generation: generation)
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, generation == renderGeneration else { return }
                renderTask = nil; preparingDrag = false; rendering = false; dragError = error.localizedDescription; dragStatus = "ドラッグ用音声を準備できません"
            }
        }
    }
    private func stopPlayback() {
        playbackGeneration = UUID(); playbackValidationTask?.cancel(); playbackValidationTask = nil
        playbackIsAutomatic = false; playbackPending = false
        preview.stop(); previewIO?.stop?()
    }
    private func startPlayback(_ url: URL, info: AudioInfo?, automatic: Bool, startingFrame: Int64? = nil) {
        stopPlayback()
        let generation = playbackGeneration, sourceGeneration = audioGeneration
        playbackIsAutomatic = automatic; playbackPending = true; previewError = nil
        playbackValidationTask = Task {
            do {
                if let info { try await Task.detached(priority: .userInitiated) { try info.validateSource() }.value }
                try Task.checkCancellation()
                guard generation == playbackGeneration, sourceGeneration == audioGeneration,
                      !automatic || (autoPreview && autoplayGeneration == sourceGeneration) else { return }
                if let startingFrame {
                    if let seek = previewIO?.seek { try await seek(url, volume, loop, startingFrame) }
                    else { try await preview.playFile(url, volume: volume, loop: loop, startingFrame: startingFrame) }
                } else if let play = previewIO?.play { try await play(url, volume, loop) }
                else { try await preview.playFile(url, volume: volume, loop: loop) }
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                playbackValidationTask = nil; playbackPending = false
            } catch is CancellationError {
                if generation == playbackGeneration { playbackValidationTask = nil; playbackPending = false; playbackIsAutomatic = false }
            }
            catch {
                guard !Task.isCancelled, generation == playbackGeneration else { return }
                playbackValidationTask = nil; playbackIsAutomatic = false; playbackPending = false
                previewError = error.localizedDescription
                if !automatic { self.error = error.localizedDescription }
            }
        }
    }
    func togglePlayback() {
        if playbackValidationTask != nil || preview.isPlaying { stopPlayback(); return }
        guard let info = audio else {
            if let rawSourceURL { startPlayback(rawSourceURL, info: nil, automatic: false) }
            return
        }
        do { try validatedSelection(info) } catch { self.error = error.localizedDescription; return }
        if usesOriginal(info, edit: selection) {
            startPlayback(info.url, info: info, automatic: false)
        } else if let url = previewURL ?? exportURL {
            startPlayback(url, info: info, automatic: false)
        } else {
            render(forExport: false, playWhenReady: true)
        }
    }
    /// Waveform clicks audition the source position; they never edit the trim
    /// handles or invalidate the file already prepared for a DAW.
    func playFromWaveform(frame requestedFrame: Int64) {
        guard let info = audio else { return }
        do { try validatedSelection(info) } catch { self.error = error.localizedDescription; return }
        let edit = selection
        let frame = min(info.totalFrames - 1, max(0, requestedFrame))
        if edit.rate == 1 && edit.pitchSemitones == 0 && edit.fadeInFrames == 0 && edit.fadeOutFrames == 0 {
            startPlayback(info.url, info: info, automatic: false, startingFrame: frame)
            return
        }

        stopPlayback()
        playbackPending = true; previewError = nil
        let playbackToken = playbackGeneration, sourceToken = audioGeneration, editToken = renderGeneration
        playbackValidationTask = Task {
            do {
                let url: URL, outputFrame: Int64
                if frame >= edit.startFrame && frame < edit.endFrame {
                    // Reuse the selected edit, including its fades. Tempo changes
                    // map source positions into the rendered file's time scale.
                    if let prepared = previewURL ?? exportURL { url = prepared }
                    else { url = try await renderedAudio(info: info, edit: edit, generation: editToken) }
                    outputFrame = min(edit.outputFrames - 1, Int64((Double(frame - edit.startFrame) / edit.rate).rounded()))
                } else {
                    // Clicking outside the trim still means the clicked source
                    // position. Keep this full-source audition out of DAW exports.
                    var audition = edit
                    audition.startFrame = 0; audition.endFrame = info.totalFrames
                    url = try await renderedAudition(info: info, edit: audition, generation: editToken)
                    outputFrame = min(audition.outputFrames - 1, Int64((Double(frame) / audition.rate).rounded()))
                }
                try Task.checkCancellation()
                guard playbackToken == playbackGeneration, sourceToken == audioGeneration, editToken == renderGeneration else { return }
                playbackValidationTask = nil
                startPlayback(url, info: info, automatic: false, startingFrame: outputFrame)
            } catch is CancellationError {
                if playbackToken == playbackGeneration { playbackValidationTask = nil; playbackPending = false }
            }
            catch {
                guard !Task.isCancelled, playbackToken == playbackGeneration, sourceToken == audioGeneration else { return }
                playbackValidationTask = nil; playbackPending = false; previewError = error.localizedDescription; self.error = error.localizedDescription
            }
        }
    }

    private func renderedAudition(info: AudioInfo, edit: AudioSelection, generation: UUID) async throws -> URL {
        guard generation == renderGeneration else { throw CancellationError() }
        if auditionRenderTask == nil {
            let directory = cacheDirectory.appendingPathComponent("waveform-audition", isDirectory: true), renderer = previewIO?.render
            auditionRenderTask = Task.detached(priority: .userInitiated) {
                if let renderer { return try await renderer(info, edit, directory) }
                return try AudioRenderer.export(info: info, selection: edit, directory: directory)
            }
        }
        do {
            let result = try await auditionRenderTask!.value
            try Task.checkCancellation()
            guard generation == renderGeneration else { throw CancellationError() }
            return result
        } catch {
            if generation == renderGeneration, !(error is CancellationError), !Task.isCancelled { auditionRenderTask = nil }
            throw error
        }
    }
    /// Concurrent manual preview and drag preparation share one render, so no
    /// second writer can race to publish the same processed file.
    private func renderedAudio(info: AudioInfo, edit: AudioSelection, generation: UUID) async throws -> URL {
        guard generation == renderGeneration, edit == selection else { throw CancellationError() }
        if renderTask == nil {
            let directory = exportDirectory, renderer = previewIO?.render
            rendering = true
            renderTask = Task.detached(priority: .userInitiated) {
                if let renderer { return try await renderer(info, edit, directory) }
                return try AudioRenderer.export(info: info, selection: edit, directory: directory)
            }
        }
        let result = try await renderTask!.value
        try Task.checkCancellation()
        guard generation == renderGeneration, edit == selection else { throw CancellationError() }
        rendering = false; exportURL = result; previewURL = result
        dragURL = usesOriginal(info, edit: edit) ? info.url : result
        preparingDrag = false; dragError = nil; dragStatus = usesOriginal(info, edit: edit) ? "原音を DAW へドラッグ" : "編集した音声を DAW へドラッグ"
        return result
    }
    func render(forExport: Bool, playWhenReady: Bool = false) {
        guard let info = audio else { return }
        do { try validatedSelection(info) } catch { self.error = error.localizedDescription; return }
        // A normal preview never needs a WAV copy of an untouched source.
        if playWhenReady && usesOriginal(info, edit: selection) {
            startPlayback(info.url, info: info, automatic: false)
            return
        }
        let edit = selection, generation = renderGeneration
        if playWhenReady { stopPlayback(); playbackPending = true; previewError = nil }
        let playbackToken = playbackGeneration
        let operation = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await renderedAudio(info: info, edit: edit, generation: generation)
                guard !Task.isCancelled, generation == renderGeneration else { return }
                if playWhenReady { playbackValidationTask = nil; startPlayback(result, info: info, automatic: false) }
            } catch is CancellationError {
                if playWhenReady, playbackToken == playbackGeneration { playbackValidationTask = nil; playbackPending = false }
            }
            catch {
                guard !Task.isCancelled, generation == renderGeneration else { return }
                if playWhenReady, playbackToken == playbackGeneration { playbackValidationTask = nil; playbackPending = false; previewError = error.localizedDescription }
                renderTask = nil; rendering = false; preparingDrag = false
                dragError = error.localizedDescription; self.error = error.localizedDescription
            }
        }
        if playWhenReady { playbackValidationTask = operation }
    }
}
