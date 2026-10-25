import SwiftUI
import AppKit
import SampleBrowserAssets

struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    @StateObject private var folders = FolderBrowserModel()
    @StateObject private var favoriteAliases = FavoriteAliasStore()
    @StateObject private var annotations = LocalAnnotationStore()
    @StateObject private var librarySearch = LocalLibrarySearchModel()
    @State private var destination: BrowserDestination = .folders
    @State private var folderQuery = ""
    @State private var searchAllSources = true
    @State private var indexedPreviewEntry: FolderEntry?
    @State private var setup = false
    @State private var remoteRenaming: Sample?
    @State private var remoteFavoriteName = ""
    @FocusState private var searchFocused: Bool
    @State private var browserFocusRequest = UUID()
    @State private var inspectorVisible = true
    @State private var compactInspector = false
    @State private var selectedFavoriteFolderID: UUID?
    @State private var showingFavoriteFolderEditor = false
    @State private var editingFavoriteFolderID: UUID?
    @State private var favoriteFolderName = ""
    @State private var deletingFavoriteFolder: FavoriteFolder?
    @State private var annotationEditing: FolderEntry?
    @State private var selectedTag: String?
    @State private var tagPreviewEntry: FolderEntry?

    var body: some View {
        presentationContent
        .alert("操作を完了できませんでした", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("閉じる") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("操作を完了できませんでした", isPresented: Binding(get: { folders.error != nil }, set: { if !$0 { folders.error = nil } })) {
            Button("閉じる") { folders.error = nil }
        } message: { Text(folders.error ?? "") }
        .alert("お気に入りの名前を変更", isPresented: Binding(get: { remoteRenaming != nil }, set: { if !$0 { remoteRenaming = nil } })) {
            TextField("表示名", text: $remoteFavoriteName)
            Button("キャンセル", role: .cancel) { remoteRenaming = nil }
            Button("保存") {
                if let sample = remoteRenaming { favoriteAliases.rename(key: model.favoriteAliasKey(sample.id), name: remoteFavoriteName) }
                remoteRenaming = nil
            }.disabled(remoteFavoriteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("この Mac での表示名を変更します。NAS 上のファイル名は変わりません。") }
        .alert(editingFavoriteFolderID == nil ? "お気に入りフォルダを作成" : "お気に入りフォルダ名を変更", isPresented: $showingFavoriteFolderEditor) {
            TextField("フォルダ名", text: $favoriteFolderName)
            Button("キャンセル", role: .cancel) { }
            Button(editingFavoriteFolderID == nil ? "作成" : "保存") {
                if let id = editingFavoriteFolderID { folders.renameFavoriteFolder(id, name: favoriteFolderName) }
                else if let id = folders.createFavoriteFolder(name: favoriteFolderName) { showFavoriteFolder(id) }
            }.disabled(!validFavoriteFolderName)
        } message: { Text("お気に入りを整理するフォルダの名前を入力してください。") }
        .alert("お気に入りフォルダを削除", isPresented: Binding(get: { deletingFavoriteFolder != nil }, set: { if !$0 { deletingFavoriteFolder = nil } })) {
            Button("キャンセル", role: .cancel) { deletingFavoriteFolder = nil }
            Button("削除", role: .destructive) {
                if let folder = deletingFavoriteFolder { folders.removeFavoriteFolder(folder.id) }
                deletingFavoriteFolder = nil
            }
        } message: { Text("「\(deletingFavoriteFolder?.name ?? "")」を削除します。中のお気に入りは「すべてのお気に入り」に残ります。") }
        .background(Button("") { searchFocused = true }.keyboardShortcut("f").hidden())
        .background(PlaybackKeyboardView(action: model.togglePlayback).frame(width: 0, height: 0))
    }

    private var presentationContent: some View {
        lifecycleContent
        .sheet(isPresented: $model.showSettings) {
            ConnectionView { model.showSettings = false; model.useSavedConnection() }
        }
        .sheet(isPresented: $model.showPlaybackSettings) {
            PlaybackSettingsView(model: model)
        }
        .sheet(item: $annotationEditing) { entry in
            LocalAnnotationEditor(entry: entry, store: annotations, sources: folders.sources,
                                  onSaved: { annotationEditing = nil }, onCancel: { annotationEditing = nil })
        }
        .sheet(isPresented: $compactInspector) {
            VStack(spacing: 0) {
                HStack { Text("素材の詳細").font(.system(size: 20, weight: .semibold)); Spacer(); Button("閉じる") { compactInspector = false }.buttonStyle(StudioButtonStyle()) }.padding(24)
                inspector
            }
            .frame(width: 440, height: 700)
            .background(StudioTheme.surface)
        }
    }

    private var lifecycleContent: some View {
        GeometryReader { geometry in
            browserLayout(wide: geometry.size.width >= 1420 && destination == .index)
        }
        .onAppear {
            guard !setup else { return }; setup = true
            folders.onSelectionChange = { entry in
                // openLocal clears the previous audio when a file is selected.
                // Avoid publishing the entire empty preview state twice per key.
                if !showsGlobalSearch, (destination == .folders || destination == .favorites), entry?.isDirectory != false {
                    model.clearSelectedAudio()
                }
            }
            folders.onSelectAudio = { url in
                if destination == .folders && !showsGlobalSearch { model.openLocal(url) }
            }
            folders.onPreviewFavoriteAudio = { url in
                if destination == .favorites { model.playLocal(url) }
            }
            folders.onSelectFavoriteAudio = { url in
                if destination == .favorites { model.openLocal(url) }
            }
            let args = CommandLine.arguments
            if args.contains("--shared-index") { destination = .index }
            if let index = args.firstIndex(of: "--browse-folder"), args.count > index + 1 {
                folders.addSource(URL(fileURLWithPath: args[index + 1], isDirectory: true))
            } else { folders.startup() }
            librarySearch.configure(sources: folders.sources, annotations: annotations.records)
        }
        .onChange(of: folders.sources) { _, sources in
            librarySearch.configure(sources: sources, annotations: annotations.records)
        }
        .onChange(of: annotations.records) { _, records in
            librarySearch.configure(sources: folders.sources, annotations: records)
        }
        .onChange(of: folderQuery) { _, query in
            if showsGlobalSearch { librarySearch.query = query }
        }
        .onChange(of: showsGlobalSearch) { _, visible in
            folders.cancelFavoritePreview()
            indexedPreviewEntry = nil
            librarySearch.selectedID = nil
            model.clearSelectedAudio()
            if visible { librarySearch.query = folderQuery }
        }
        .onChange(of: folders.columns.last?.id) { _, _ in
            if destination == .folders && !showsGlobalSearch { folderQuery = "" }
        }
        .onChange(of: destination) { _, destination in
            folders.cancelFavoritePreview()
            model.clearSelectedAudio()
            if destination == .folders, !showsGlobalSearch, let entry = folders.selectedEntry, !entry.isDirectory { model.openLocal(entry.url) }
        }
        .onChange(of: folders.favoriteFolders.map(\.id)) { _, ids in
            guard let id = selectedFavoriteFolderID, !ids.contains(id) else { return }
            if destination == .favorites { showFavoriteFolder(nil) }
            else { selectedFavoriteFolderID = nil }
        }
    }

    private func browserLayout(wide: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 236)
                VStack(spacing: 20) {
                    if destination == .index {
                        searchHeader(wide: wide)
                        results
                    } else {
                        folderHeader
                        if showsGlobalSearch {
                            LocalLibrarySearchPane(search: librarySearch, folders: folders,
                                select: selectIndexedEntry, openLocation: openIndexedLocation, edit: editAnnotation)
                        } else if destination == .folders {
                            FolderBrowserPane(folders: folders, annotations: annotations, query: $folderQuery, editAnnotation: editAnnotation)
                        } else if destination == .tags {
                            LocalTagSearchPane(store: annotations, folders: folders, query: folderQuery, selectedTag: $selectedTag,
                                activate: activateTaggedEntry, edit: editAnnotation, selectionChanged: selectTaggedEntry, focusRequest: browserFocusRequest)
                        } else {
                            FolderFavoritesPane(folders: folders, annotations: annotations, folderID: selectedFavoriteFolderID, query: folderQuery, activate: { id in
                                guard let favorite = folders.favorites.first(where: { $0.id == id }) else { return }
                                if favorite.isDirectory { showFavoriteLocation(id) }
                                else { folders.previewFavorite(id) }
                            }, openLocation: showFavoriteLocation, editAnnotation: editAnnotation, focusRequest: browserFocusRequest)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if wide && inspectorVisible {
                    inspector
                        .frame(width: 320)
                        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 22))
                        .padding(.trailing, 24)
                        .padding(.vertical, 24)
                }
            }
            .frame(maxHeight: .infinity)
            AudioPanel(model: model, preview: model.preview)
                .frame(height: model.inlinePlaybackError == nil ? 354 : 394)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(StudioTheme.border.opacity(0.7)))
                .padding(.horizontal, 20)
            statusBar
        }
        .background(StudioTheme.background)
        .foregroundStyle(StudioTheme.text)
        .tint(StudioTheme.accent)
    }

    private func showFavoriteLocation(_ id: UUID) {
        destination = .folders
        folderQuery = ""
        folders.openFavorite(id)
    }

    private var annotationEntry: FolderEntry? {
        if let url = model.localAudioSourceURL {
            if showsGlobalSearch, let entry = indexedPreviewEntry, entry.url == url { return entry }
            if let entry = folders.selectedEntry, !entry.isDirectory, entry.url == url { return entry }
            return FolderEntry(indexedPath: url.path, name: url.lastPathComponent, isDirectory: false)
        }
        if showsGlobalSearch { return indexedPreviewEntry }
        if destination == .favorites, let id = folders.selectedFavoriteID,
           let favorite = folders.favorites.first(where: { $0.id == id }) {
            return FolderEntry(indexedPath: favorite.savedPath, name: favorite.url.lastPathComponent, isDirectory: favorite.isDirectory)
        }
        if destination == .tags, let entry = tagPreviewEntry { return entry }
        if model.detail == nil, let audio = model.audio {
            return FolderEntry(indexedPath: audio.url.path, name: audio.url.lastPathComponent, isDirectory: false)
        }
        if destination == .folders, let entry = folders.selectedEntry { return entry }
        return nil
    }

    private func editAnnotation(_ entry: FolderEntry) { annotationEditing = entry }

    private var showsGlobalSearch: Bool {
        destination == .librarySearch || (destination == .folders && searchAllSources && !folderQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func selectIndexedEntry(_ entry: FolderEntry?) {
        guard showsGlobalSearch else { return }
        indexedPreviewEntry = entry
        if let entry, !entry.isDirectory { model.openLocal(entry.url) }
        else { model.clearSelectedAudio() }
    }

    private func openIndexedLocation(_ entry: FolderEntry) {
        searchFocused = false
        // The search List is about to disappear. Resign its AppKit responder
        // so macOS doesn't restore the old search field during the reveal.
        NSApp.keyWindow?.makeFirstResponder(nil)
        folderQuery = ""
        destination = .folders
        folders.openEntryLocation(entry)
    }

    private func activateTaggedEntry(_ entry: FolderEntry) {
        if entry.isDirectory {
            destination = .folders
            folderQuery = ""
            folders.openEntryLocation(entry)
        } else {
            tagPreviewEntry = entry
            model.playLocal(entry.url)
        }
    }

    private func selectTaggedEntry(_ entry: FolderEntry?) {
        guard destination == .tags else { return }
        tagPreviewEntry = entry
        if let entry, !entry.isDirectory { model.openLocal(entry.url) }
        else { model.clearSelectedAudio() }
    }

    private var localTitle: String {
        if showsGlobalSearch { return "全体検索" }
        switch destination {
        case .favorites: return favoriteFolderTitle
        case .tags: return "メモ・タグ検索"
        default: return "フォルダ"
        }
    }

    private var localSearchPrompt: String {
        switch destination {
        case .favorites: return "お気に入りの名前・メモ・タグを検索"
        case .tags: return "名前・メモ・タグを検索（#タグ）"
        default: return searchAllSources || destination == .librarySearch
                ? "すべての場所から名前・パス・メモ・タグを検索"
                : "右端のフォルダ内を名前・メモ・タグで絞り込み"
        }
    }

    private var favoriteFolderTitle: String {
        folders.favoriteFolders.first(where: { $0.id == selectedFavoriteFolderID })?.name ?? "すべてのお気に入り"
    }

    private var validFavoriteFolderName: Bool {
        let value = favoriteFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count <= 120 && !value.contains(where: \.isNewline) && !value.contains("\0")
    }

    private func editFavoriteFolder(_ folder: FavoriteFolder? = nil) {
        editingFavoriteFolderID = folder?.id
        favoriteFolderName = folder?.name ?? ""
        showingFavoriteFolderEditor = true
    }

    private func showFavoriteFolder(_ id: UUID?) {
        folders.cancelFavoritePreview()
        model.clearSelectedAudio()
        selectedFavoriteFolderID = id
        folderQuery = ""
        destination = .favorites
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: AppArtwork.logo)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 60)
                .accessibilityLabel("SampleGlide")
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 12).padding(.bottom, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionLabel("ライブラリ")
                    VStack(spacing: 8) {
                        navigation("フォルダ", icon: "rectangle.split.3x1", active: destination == .folders) { destination = .folders; folderQuery = "" }
                        navigation("全体検索", icon: "magnifyingglass", active: destination == .librarySearch) {
                            folderQuery = ""; destination = .librarySearch
                        }.help("登録したすべての場所と階層を検索")
                        navigation("お気に入り", icon: "star", active: destination == .favorites && selectedFavoriteFolderID == nil) { showFavoriteFolder(nil) }
                            .help("すべてのお気に入りを表示")
                        navigation("メモ・タグ検索", icon: "tag", active: destination == .tags) {
                            destination = .tags; folderQuery = ""; selectedTag = nil; tagPreviewEntry = nil
                        }
                        navigation("共有索引", icon: "externaldrive.connected.to.line.below", active: destination == .index) { destination = .index; model.refresh() }
                    }.padding(.top, 13)
                    Rectangle().fill(StudioTheme.border).frame(height: 1).padding(.vertical, 24)
                    HStack {
                        sectionLabel("お気に入りフォルダ")
                        Spacer()
                        Button { editFavoriteFolder() } label: { Image(systemName: "plus").font(.system(size: 15)) }
                            .buttonStyle(.plain).help("お気に入りフォルダを作成")
                            .accessibilityLabel("お気に入りフォルダを作成")
                    }
                    VStack(spacing: 5) {
                        ForEach(folders.favoriteFolders) { folder in
                            navigation(folder.name, icon: "folder", active: destination == .favorites && selectedFavoriteFolderID == folder.id) { showFavoriteFolder(folder.id) }
                                .help(folder.name)
                                .contextMenu {
                                    Button("開く") { showFavoriteFolder(folder.id) }
                                    Button("フォルダ名を変更…") { editFavoriteFolder(folder) }
                                    Divider()
                                    Button("フォルダを削除…") { deletingFavoriteFolder = folder }
                                }
                        }
                    }.padding(.top, 10)
                    Rectangle().fill(StudioTheme.border).frame(height: 1).padding(.vertical, 24)
                    HStack { sectionLabel("場所"); Spacer(); Button(action: folders.chooseSource) { Image(systemName: "plus").font(.system(size: 15)) }.buttonStyle(.plain).help("フォルダを追加") }
                    VStack(spacing: 5) {
                        ForEach(folders.sources) { source in
                            navigation(source.name, icon: source.url.path.hasPrefix("/Volumes/") ? "externaldrive" : "folder", active: destination == .folders && folders.selectedSourceID == source.id) {
                                destination = .folders; folderQuery = ""; folders.openSource(source.id)
                            }
                            .help(source.url.path)
                            .contextMenu {
                                Button("開く") { destination = .folders; folderQuery = ""; folders.openSource(source.id) }
                                Button(folders.isFavorite(source.url) ? "お気に入りから削除" : "お気に入りに追加") { folders.toggleFavorite(FolderEntry(url: source.url, name: source.name, isDirectory: true)) }
                                Button("場所から取り除く") { folders.removeSource(source.id) }
                            }
                        }
                    }.padding(.top, 10)
                    Rectangle().fill(StudioTheme.border).frame(height: 1).padding(.vertical, 24)
                    sectionLabel("ワークスペース")
                    VStack(spacing: 8) {
                        navigation("音声を開く", icon: "folder.badge.plus", active: false, action: model.openLocal)
                        navigation("試聴設定", icon: "slider.horizontal.3", active: false) { model.showPlaybackSettings = true }
                        navigation("書き出し", icon: "square.and.arrow.up", active: false) {
                            try? FileManager.default.createDirectory(at: model.exportDirectory, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(model.exportDirectory)
                        }
                    }.padding(.top, 13)
                }
            }
            .scrollIndicators(.hidden)
            .padding(.bottom, 16)
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 9) {
                    Image(systemName: "folder.badge.plus").foregroundStyle(StudioTheme.accent)
                    Text("Mac・接続済み NAS").font(.system(size: 14, weight: .semibold))
                }
                Button { destination = .folders; folders.chooseSource() } label: {
                    HStack { Text("フォルダを追加"); Spacer(); Image(systemName: "plus") }
                }.buttonStyle(StudioButtonStyle())
                Button("共有 API の接続設定…") { model.showSettings = true }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
            }
            .padding(16)
            .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 17))
        }
        .padding(20)
        .background(StudioTheme.sidebar)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(StudioTheme.secondary).padding(.leading, 12)
    }

    private func navigation(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            // A sidebar change ends text editing. The destination list can
            // then accept arrows instead of retaining the search field editor.
            searchFocused = false
            NSApp.keyWindow?.makeFirstResponder(nil)
            action()
            browserFocusRequest = UUID()
        } label: {
            HStack(spacing: 13) {
                Image(systemName: icon).font(.system(size: 18, weight: .medium)).frame(width: 24)
                Text(title).font(.system(size: 15, weight: active ? .semibold : .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if active { Capsule().fill(StudioTheme.accent).frame(width: 4, height: 20) }
            }
            .foregroundStyle(active ? StudioTheme.accent : StudioTheme.secondary)
            .padding(.horizontal, 13).frame(height: 52)
            .background(active ? StudioTheme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(.plain)
    }

    private var folderHeader: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(showsGlobalSearch ? "SEARCH YOUR LIBRARY" : destination == .favorites ? "YOUR COLLECTION" : destination == .tags ? "TAGS & NOTES" : "FOLDER BROWSER")
                        .font(.system(size: 12, weight: .semibold)).tracking(2).foregroundStyle(StudioTheme.accent)
                    Text(localTitle)
                        .font(.system(size: 32, weight: .bold))
                        .lineLimit(1).truncationMode(.middle)
                        .help(localTitle)
                }
                Spacer(minLength: 5)
                if destination == .favorites {
                    Button { editFavoriteFolder() } label: {
                        Label("新規フォルダ", systemImage: "folder.badge.plus")
                    }.buttonStyle(StudioButtonStyle())
                        .accessibilityLabel("お気に入りフォルダを作成")
                    if let folder = folders.favoriteFolders.first(where: { $0.id == selectedFavoriteFolderID }) {
                        Button { editFavoriteFolder(folder) } label: { Image(systemName: "pencil").font(.system(size: 17)) }
                            .buttonStyle(StudioButtonStyle()).help("お気に入りフォルダ名を変更")
                            .accessibilityLabel("お気に入りフォルダ名を変更")
                    }
                } else if destination == .folders {
                    Button { destination = .folders; folders.chooseSource() } label: {
                        Label("フォルダを追加", systemImage: "folder.badge.plus")
                    }.buttonStyle(StudioButtonStyle())
                    if !showsGlobalSearch {
                        Button(action: folders.refresh) { Image(systemName: "arrow.clockwise").font(.system(size: 17)) }
                            .buttonStyle(StudioButtonStyle()).help("表示中のフォルダを更新")
                    }
                }
                Button { if let entry = annotationEntry { editAnnotation(entry) } } label: {
                    Label("メモ・タグ", systemImage: "square.and.pencil")
                }.buttonStyle(StudioButtonStyle()).disabled(annotationEntry == nil)
                    .help("選択した項目のメモとタグを編集")
                    .accessibilityLabel("メモとタグを編集")
                Button { compactInspector = true } label: { Image(systemName: "sidebar.right").font(.system(size: 17)) }
                    .buttonStyle(StudioButtonStyle()).help("音声の詳細")
            }
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 19)).foregroundStyle(StudioTheme.secondary)
                TextField(localSearchPrompt, text: $folderQuery)
                    .font(.system(size: 16)).textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel("サンプルを検索")
                if destination == .folders {
                    Picker("検索範囲", selection: $searchAllSources) {
                        Text("すべての場所").tag(true)
                        Text("このフォルダ").tag(false)
                    }
                    .labelsHidden().pickerStyle(.menu).frame(width: 152)
                    .accessibilityLabel("検索範囲")
                }
                if !folderQuery.isEmpty {
                    Button { folderQuery = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("絞り込みをクリア")
                }
                Text("⌘ F").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(StudioTheme.secondary)
            }
            .padding(.horizontal, 16).frame(height: 48)
            .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(searchFocused ? StudioTheme.accent.opacity(0.7) : StudioTheme.border))
        }
    }

    private func searchHeader(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SOUND LIBRARY").font(.system(size: 12, weight: .semibold)).tracking(2.0).foregroundStyle(StudioTheme.accent)
                    Text(model.favoritesOnly ? "共有のお気に入り" : "共有索引").font(.system(size: 32, weight: .bold))
                }
                Spacer(minLength: 4)
                Button { model.favoritesOnly.toggle() } label: { Image(systemName: model.favoritesOnly ? "star.fill" : "star") }
                    .buttonStyle(StudioButtonStyle(prominent: model.favoritesOnly)).help("共有のお気に入りを絞り込み")
                Button(action: model.refresh) { Image(systemName: "arrow.clockwise").font(.system(size: 17)) }
                    .buttonStyle(StudioButtonStyle()).help("一覧を更新")
                Button {
                    if wide { inspectorVisible.toggle() } else { compactInspector = true }
                } label: { Image(systemName: "sidebar.right").font(.system(size: 17)) }
                    .buttonStyle(StudioButtonStyle()).help("素材の詳細を表示 / 非表示")
            }
            HStack(spacing: 13) {
                Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundStyle(StudioTheme.secondary)
                TextField("名前やフォルダからサンプルを検索", text: $model.query)
                    .font(.system(size: 17)).textFieldStyle(.plain).focused($searchFocused)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(StudioTheme.secondary) }.buttonStyle(.plain).help("検索をクリア")
                }
                Text("⌘ F").font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(StudioTheme.secondary).padding(.horizontal, 8).padding(.vertical, 5)
                    .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 17).frame(height: 55)
            .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(searchFocused ? StudioTheme.accent.opacity(0.7) : StudioTheme.border))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { kindMenu; bpmFilters; Spacer(minLength: 4); sortMenu }
                VStack(alignment: .leading, spacing: 10) { HStack { kindMenu; Spacer(); sortMenu }; bpmFilters }
            }
        }
    }

    private var kindMenu: some View {
        Menu {
            Picker("種別", selection: $model.kind) {
                Text("すべての種別").tag("all"); Text("ループ").tag("loop")
                Text("ワンショット").tag("one_shot"); Text("未分類").tag("unknown")
            }
        } label: {
            HStack(spacing: 8) { Image(systemName: "line.3.horizontal.decrease"); Text(["all":"すべての種別", "loop":"ループ", "one_shot":"ワンショット", "unknown":"未分類"][model.kind] ?? "種別"); Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)) }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .font(.system(size: 14, weight: .medium)).controlSize(.large)
        .padding(.horizontal, 14).frame(height: 44)
        .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 11)).fixedSize()
    }

    private var bpmFilters: some View {
        HStack(spacing: 9) {
            Text("BPM").font(.system(size: 13, weight: .semibold)).foregroundStyle(StudioTheme.secondary)
            TextField("下限", text: $model.bpmMin).studioField().frame(width: 66)
            Text("–").foregroundStyle(StudioTheme.secondary)
            TextField("上限", text: $model.bpmMax).studioField().frame(width: 66)
            Button("適用", action: model.searchSoon).buttonStyle(StudioButtonStyle())
        }.fixedSize()
    }

    private var sortMenu: some View {
        Menu {
            Picker("並び順", selection: $model.sort) {
                Text("名前順").tag("name"); Text("BPM 順").tag("bpm"); Text("長さ順").tag("duration_seconds")
            }
        } label: {
            HStack(spacing: 8) { Image(systemName: "arrow.up.arrow.down"); Text(["name":"名前順", "bpm":"BPM 順", "duration_seconds":"長さ順"][model.sort] ?? "名前順") }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .font(.system(size: 14, weight: .medium)).controlSize(.large)
        .padding(.horizontal, 12).frame(height: 44).fixedSize()
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack {
                Text("サンプル").frame(maxWidth: .infinity, alignment: .leading)
                Text("BPM").frame(width: 80)
                Text("キー").frame(width: 88)
                Text("長さ").frame(width: 72)
            }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(StudioTheme.secondary)
            .padding(.horizontal, 20).frame(height: 46)
            Rectangle().fill(StudioTheme.border.opacity(0.75)).frame(height: 1)
            if model.searching {
                ProgressView("サンプルを検索中…").font(.system(size: 16)).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.samples.isEmpty {
                GeometryReader { geometry in
                    ScrollView {
                        emptyLibrary.frame(minHeight: geometry.size.height)
                    }
                }
            } else {
                List(selection: $model.selectedID) {
                    ForEach(model.samples) { sample in
                        sampleRow(sample)
                            .tag(sample.id)
                            .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button(sample.favorite ? "お気に入りから削除" : "お気に入りに追加") {
                                    model.setRemoteFavorite(sampleID: sample.id, value: !sample.favorite)
                                }.disabled(model.saving || !model.connected)
                                if sample.favorite {
                                    Button("お気に入りの名前を変更…") {
                                        remoteFavoriteName = favoriteAliases.name(key: model.favoriteAliasKey(sample.id), fallback: sample.name)
                                        remoteRenaming = sample
                                    }
                                }
                            }
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 74)
            }
            Rectangle().fill(StudioTheme.border.opacity(0.75)).frame(height: 1)
            HStack(spacing: 13) {
                Text("\(model.samples.count) 件を表示").foregroundStyle(StudioTheme.secondary)
                Spacer()
                Button(action: model.previousPage) { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).frame(width: 34, height: 34).contentShape(Rectangle())
                    .disabled(model.pageNumber <= 1 || model.searching).help("前のページ")
                Text("\(model.pageNumber)").font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .frame(width: 34, height: 32).background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 8))
                Button(action: model.nextPage) { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain).frame(width: 34, height: 34).contentShape(Rectangle())
                    .disabled(!model.hasMore || model.searching).help("次のページ")
            }.font(.system(size: 13)).padding(.horizontal, 20).frame(height: 55)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 19))
        .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(StudioTheme.border.opacity(0.6)))
    }

    private func sampleRow(_ sample: Sample) -> some View {
        let selected = model.selectedID == sample.id
        return HStack(spacing: 12) {
            Image(systemName: sample.favorite ? "star.fill" : "waveform")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(sample.favorite ? StudioTheme.warning : StudioTheme.accent)
                .frame(width: 42, height: 44)
                .background((selected ? StudioTheme.accent : StudioTheme.secondary).opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 7) {
                Text(sample.favorite ? favoriteAliases.name(key: model.favoriteAliasKey(sample.id), fallback: sample.name) : sample.name)
                    .font(.system(size: 16, weight: .semibold)).lineLimit(1)
                Text(sampleSubtitle(sample)).font(.system(size: 13)).foregroundStyle(StudioTheme.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(sample.bpmLabel).frame(width: 80)
            Text(sample.keyLabel).frame(width: 88)
            Text(sample.durationSeconds.map { String(format: "%.2fs", $0) } ?? "—").frame(width: 72)
        }
        .font(.system(size: 14, weight: .medium, design: .monospaced))
        .padding(.horizontal, 8).frame(minHeight: 70)
        .contentShape(Rectangle())
        .background(selected ? StudioTheme.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 12))
    }

    private func sampleSubtitle(_ sample: Sample) -> String {
        if sample.favorite, favoriteAliases.name(key: model.favoriteAliasKey(sample.id), fallback: sample.name) != sample.name { return sample.name }
        if sample.sourceState != "present" || sample.rootState == "offline" { return stateLabel(sample) }
        if let path = sample.path, path != sample.name { return path }
        let format = URL(fileURLWithPath: sample.name).pathExtension.uppercased()
        let kind = ["loop":"ループ", "one_shot":"ワンショット"][sample.sampleKind ?? ""] ?? "未分類"
        return "\(format)  ·  \(kind)"
    }

    private var emptyLibrary: some View {
        VStack(spacing: 16) {
            Image(systemName: model.connected ? "magnifyingglass" : "waveform")
                .font(.system(size: 36, weight: .light)).foregroundStyle(StudioTheme.accent)
                .frame(width: 82, height: 82).background(StudioTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
            Text(model.connected ? "一致する素材がありません" : "サウンドを読み込もう")
                .font(.system(size: 22, weight: .semibold))
            Text(model.connected ? "検索条件を変えて、もう一度お試しください。" : "NAS のライブラリに接続するか、\nMac の音声ファイルを開いて始められます。")
                .font(.system(size: 14)).foregroundStyle(StudioTheme.secondary).lineSpacing(6).multilineTextAlignment(.center)
            Button(action: model.openLocal) { Label("音声ファイルを開く", systemImage: "plus") }
                .buttonStyle(StudioButtonStyle(prominent: true)).padding(.top, 3)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack { Text("インスペクター").font(.system(size: 14, weight: .semibold)).foregroundStyle(StudioTheme.secondary); Spacer(); Image(systemName: "slider.horizontal.3").foregroundStyle(StudioTheme.accent) }
                if let detail = model.detail {
                    detailContent(detail)
                } else if let audio = model.audio {
                    fileIdentity(audio.url.lastPathComponent, caption: "ローカル音声")
                    metadataGrid(bpm: "—", key: "—", rate: String(format: "%.0f Hz", audio.sampleRate), channels: "\(audio.channels) ch")
                    metadata("フレーム数", "\(audio.totalFrames)")
                    metadata("長さ", String(format: "%.3f 秒", audio.duration))
                    if let annotation = annotations.annotation(for: FolderEntry(url: audio.url, isDirectory: false), sources: folders.sources) {
                        Text("メモ・タグ").font(.system(size: 17, weight: .semibold))
                        if !annotation.tags.isEmpty {
                            Text(annotation.tags.map { "#" + $0 }.joined(separator: "  "))
                                .font(.system(size: 15, weight: .medium)).foregroundStyle(StudioTheme.accent)
                        }
                        if !annotation.notes.isEmpty {
                            Text(annotation.notes).font(.system(size: 15)).textSelection(.enabled)
                        }
                    }
                    preservationNote
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 32, weight: .light)).foregroundStyle(StudioTheme.accent)
                            .frame(width: 72, height: 72).background(StudioTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
                        Text("サンプルの詳細").font(.system(size: 20, weight: .semibold))
                        Text("一覧からサンプルを選択すると、\n情報やタグを編集できます。")
                            .font(.system(size: 14)).lineSpacing(6).foregroundStyle(StudioTheme.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 45)
                }
            }.padding(22)
        }
    }

    private func detailContent(_ detail: SampleDetail) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            fileIdentity(detail.sample.name, caption: URL(fileURLWithPath: detail.sample.name).pathExtension.uppercased() + " AUDIO")
            Button(action: model.toggleFavorite) {
                HStack { Image(systemName: detail.favoriteState.favorite ? "star.fill" : "star").foregroundStyle(StudioTheme.warning); Text(detail.favoriteState.favorite ? "お気に入り登録済み" : "お気に入りに追加"); Spacer(minLength: 0) }
            }.buttonStyle(StudioButtonStyle()).disabled(model.saving || !model.connected)
            metadataGrid(bpm: detail.sample.bpmLabel, key: detail.sample.keyLabel, rate: detail.sampleRate.map { "\($0) Hz" } ?? "未解析", channels: detail.channels.map { "\($0) ch" } ?? "未解析")
            HStack(spacing: 7) { Circle().fill(detail.sample.sourceState == "present" ? StudioTheme.success : StudioTheme.warning).frame(width: 6, height: 6); Text(stateLabel(detail.sample)).font(.system(size: 13)).foregroundStyle(StudioTheme.secondary) }
            if model.previewError != nil {
                Button("波形を再読み込み", action: model.loadRemoteAudio)
                    .buttonStyle(StudioButtonStyle(prominent: true)).disabled(model.loadingAudio || detail.sample.sourceState != "present")
            } else {
                Label(model.loadingAudio ? "波形を読み込み中…" : "選択した音声をプレビュー", systemImage: "waveform")
                    .font(.system(size: 14)).foregroundStyle(StudioTheme.accent)
            }
            Rectangle().fill(StudioTheme.border).frame(height: 1)
            Text("BPM・メモ").font(.system(size: 17, weight: .semibold))
            TextField("BPM（空欄で自動値）", text: $model.annotationBPM).studioField()
            TextEditor(text: $model.annotationNotes)
                .font(.system(size: 14)).scrollContentBackground(.hidden).padding(9).frame(height: 95)
                .background(StudioTheme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(StudioTheme.border))
            Button("変更を保存", action: model.saveAnnotation).buttonStyle(StudioButtonStyle()).disabled(model.saving || !model.connected)
            if !model.saveStatus.isEmpty { Label(model.saveStatus, systemImage: "checkmark.circle").font(.system(size: 13)).foregroundStyle(StudioTheme.success) }
            Rectangle().fill(StudioTheme.border).frame(height: 1)
            Text("タグ").font(.system(size: 17, weight: .semibold))
            if model.tags.isEmpty { Text("登録済みのタグがありません。")
                .font(.system(size: 14)).foregroundStyle(StudioTheme.secondary) }
            ForEach(model.tags) { tag in
                let applied = detail.sample.tagIds.contains(tag.id)
                Button { model.toggleTag(tag) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: applied ? "checkmark.circle.fill" : "plus.circle").font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 4) { Text(tag.name).font(.system(size: 15, weight: .medium)); Text(tag.namespace).font(.system(size: 12)).foregroundStyle(StudioTheme.secondary) }
                        Spacer()
                    }
                    .foregroundStyle(applied ? StudioTheme.accent : StudioTheme.secondary)
                    .padding(12).background(applied ? StudioTheme.accent.opacity(0.1) : StudioTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).disabled(model.saving || tag.archived || !model.connected)
            }
        }
    }

    private func fileIdentity(_ name: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Image(systemName: "waveform").font(.system(size: 25, weight: .medium)).foregroundStyle(StudioTheme.accent)
                .frame(width: 58, height: 58).background(StudioTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 17))
            Text(name).font(.system(size: 22, weight: .semibold)).lineLimit(3).textSelection(.enabled)
            Text(caption).font(.system(size: 12, weight: .semibold)).tracking(1).foregroundStyle(StudioTheme.secondary)
        }
    }

    private func metadataGrid(bpm: String, key: String, rate: String, channels: String) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 20) {
            metric("BPM", bpm); metric("キー", key); metric("サンプルレート", rate); metric("チャンネル", channels)
        }.padding(15).background(StudioTheme.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(StudioTheme.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .monospaced)).lineLimit(1)
        }
    }
    private func metadata(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(StudioTheme.secondary); Spacer(); Text(value) }.font(.system(size: 14))
    }
    private var preservationNote: some View {
        Label { Text("原音はそのまま。\n加工した WAV は書き出しフォルダに保存されます。") } icon: { Image(systemName: "checkmark.shield") }
            .font(.system(size: 14)).lineSpacing(6).foregroundStyle(StudioTheme.secondary)
    }
    private func stateLabel(_ sample: Sample) -> String {
        if sample.rootState == "offline" { return "原音領域がオフライン" }
        if sample.sourceState == "missing" { return "原音が見つかりません" }
        if sample.sourceState == "unreadable" { return "原音を読み取れません" }
        switch sample.analysis["header"] { case "ready": return "原音を利用できます"; case "failed": return "解析に失敗しました"; case "unsupported": return "未対応の音声形式"; case "running": return "情報を解析中"; default: return "情報の解析待ち" }
    }
    private var statusBar: some View {
        HStack(spacing: 9) {
            Circle().fill(destination == .index ? (model.connected ? StudioTheme.success : StudioTheme.warning) : StudioTheme.cyan).frame(width: 6, height: 6)
            Text(destination == .index ? model.status : (folders.loading ? "フォルダを読み込み中…" : "場所 \(folders.sources.count) か所 · お気に入り \(folders.favorites.count) 件 · 選択で波形プレビュー")).lineLimit(1)
            if destination != .index {
                Text("· \(librarySearch.statusText)").lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Image(systemName: "checkmark.shield")
            Text("原音を保護")
        }.font(.system(size: 12, weight: .medium)).foregroundStyle(StudioTheme.secondary).padding(.horizontal, 26).frame(height: 35)
    }
}

struct ConnectionView: View {
    @State private var settings = ConnectionSettings()
    @State private var error: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack(spacing: 15) {
                Image(systemName: "externaldrive.connected.to.line.below").font(.system(size: 25)).foregroundStyle(StudioTheme.accent)
                    .frame(width: 58, height: 58).background(StudioTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 17))
                VStack(alignment: .leading, spacing: 6) { Text("共有 API に接続").font(.system(size: 28, weight: .bold)); Text("共通索引と分類を、複数の Mac で共有。")
                    .font(.system(size: 15)).foregroundStyle(StudioTheme.secondary) }
            }
            VStack(alignment: .leading, spacing: 20) {
                fieldLabel("サーバー URL") { TextField("https://nas.local", text: $settings.baseURL).studioField() }
                fieldLabel("ライブラリ ID") { TextField("ライブラリの UUID", text: $settings.libraryID).studioField() }
                fieldLabel("アクセストークン") { SecureField("空欄の場合は保存済みのトークンを使用", text: $settings.token).studioField() }
            }
            Label("トークンは、この Mac の Keychain に安全に保存します。", systemImage: "lock.shield")
                .font(.system(size: 14)).foregroundStyle(StudioTheme.secondary)
            if let error { Text(error).font(.system(size: 14)).foregroundStyle(StudioTheme.warning) }
            HStack {
                Button("キャンセル") { dismiss() }.buttonStyle(StudioButtonStyle()).disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(saving ? "接続情報を保存中…" : "保存して接続") {
                    saving = true; error = nil
                    Task {
                        do { try await settings.save(); onSave() }
                        catch { self.error = error.localizedDescription }
                        saving = false
                    }
                }.buttonStyle(StudioButtonStyle(prominent: true)).disabled(saving)
            }
        }
        .padding(34).frame(width: 620).background(StudioTheme.surface).foregroundStyle(StudioTheme.text).tint(StudioTheme.accent)
    }
    private func fieldLabel<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) { Text(label).font(.system(size: 14, weight: .semibold)); content() }
    }
}
