import AppKit
import SwiftUI

/// Browses the local search index without moving the folder browser's columns.
struct LocalLibrarySearchPane: View {
    @ObservedObject var search: LocalLibrarySearchModel
    @ObservedObject var folders: FolderBrowserModel
    let select: (FolderEntry?) -> Void
    let openLocation: (FolderEntry) -> Void
    let edit: (FolderEntry) -> Void
    @FocusState private var listFocused: Bool
    @State private var renaming: FolderFavorite?
    @State private var favoriteName = ""

    var body: some View {
        VStack(spacing: 0) {
            indexStatus
            if !search.errors.isEmpty { errorSummary }
            Rectangle().fill(StudioTheme.border).frame(height: 1)
            resultList
            Rectangle().fill(StudioTheme.border).frame(height: 1)
            footer
        }
        .foregroundStyle(StudioTheme.text)
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(StudioTheme.border))
        .background(FolderHierarchyKeyboardView { direction in
            guard listFocused else { return false }
            return move(direction)
        }.frame(width: 0, height: 0))
        // Index progress, paging and metadata updates keep the same selection.
        // Only an actual ID change may start or stop the selected preview.
        .onChange(of: search.selectedID) { _, id in
            select(id.flatMap { selectedID in search.results.first { $0.id == selectedID }?.entry })
        }
        .onDisappear { listFocused = false }
        .alert("お気に入りの名前を変更", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("表示名", text: $favoriteName)
            Button("キャンセル", role: .cancel) { renaming = nil }
            Button("保存") {
                if let favorite = renaming { folders.renameFavorite(favorite.id, name: favoriteName) }
                renaming = nil
            }
            .disabled(favoriteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("お気に入りの表示名を変更します。元のファイル名・フォルダ名は変わりません。")
        }
    }

    private var indexStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 23)).foregroundStyle(StudioTheme.accent)
                    .frame(width: 46, height: 46)
                    .background(StudioTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text("ライブラリを検索").font(.system(size: 19, weight: .semibold))
                    Text("\(search.indexedCount.formatted()) 件を検索可能")
                        .font(.system(size: 14)).monospacedDigit().foregroundStyle(StudioTheme.secondary)
                }
                Spacer(minLength: 8)
                if search.isPaused {
                    Button(action: search.resume) { Label("再開", systemImage: "play.fill") }
                        .buttonStyle(StudioButtonStyle())
                        .help("フォルダの読み込みを再開します")
                } else if search.isIndexing {
                    Button(action: search.pause) { Label("一時停止", systemImage: "pause.fill") }
                        .buttonStyle(StudioButtonStyle())
                        .help("検索できる素材を残して、フォルダの読み込みを一時停止します")
                }
                Button(action: search.refreshIndex) { Label("全体を更新", systemImage: "arrow.clockwise") }
                    .buttonStyle(StudioButtonStyle())
                    .disabled(search.isIndexing && !search.isPaused)
                    .help("登録した場所を先頭から再走査して変更を検索に反映します")
            }
            HStack(spacing: 8) {
                Image(systemName: search.isPaused ? "pause.circle" : (!search.errors.isEmpty ? "exclamationmark.triangle" : (search.isIndexing ? "arrow.triangle.2.circlepath" : "checkmark.circle")))
                    .foregroundStyle(search.isPaused || !search.errors.isEmpty ? StudioTheme.warning : StudioTheme.accent)
                Text(search.statusText).font(.system(size: 13)).foregroundStyle(StudioTheme.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !folders.sources.isEmpty {
                // Traversal has no known total. Show activity only while it
                // runs; an exhausted queue with failures is finished work,
                // not a new 0% scan waiting to start.
                if search.isIndexing && !search.isPaused {
                    ProgressView()
                        .progressViewStyle(.linear).controlSize(.large)
                        .tint(StudioTheme.accent)
                        .scaleEffect(x: 1, y: 1.5).frame(height: 10)
                        .accessibilityLabel("検索インデックスの進捗")
                        .accessibilityValue("総数を確認しながら作成中")
                }
                HStack(spacing: 12) {
                    Text("処理済み \(search.processedDirectoryCount.formatted()) フォルダ")
                    Text("待機中 \(search.pendingDirectoryCount.formatted()) フォルダ")
                    Spacer(minLength: 0)
                    if search.isIndexing && !search.isPaused {
                        Text("全体数を確認中").foregroundStyle(StudioTheme.accent)
                    }
                }
                .font(.system(size: 13)).monospacedDigit().foregroundStyle(StudioTheme.secondary)
            }
        }.padding(18)
    }

    private var errorSummary: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StudioTheme.warning)
                .font(.system(size: 17)).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text("一部の場所を取得できませんでした").font(.system(size: 14, weight: .semibold))
                Text("取得済みの素材は検索できます。再確認するには「全体を更新」を押してください。")
                    .font(.system(size: 13)).foregroundStyle(StudioTheme.secondary)
                ForEach(Array(search.errors.prefix(2).enumerated()), id: \.offset) { _, error in
                    Text(error).font(.system(size: 13)).foregroundStyle(StudioTheme.secondary)
                        .lineLimit(2).truncationMode(.middle)
                }
                if search.errors.count > 2 {
                    Text("ほか \(search.errors.count - 2) 件")
                        .font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(StudioTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 18).padding(.bottom, 14)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            List(selection: Binding<String?>(
                get: { search.selectedID },
                set: { id in
                    guard id != search.selectedID else { return }
                    listFocused = true
                    search.selectedID = id
                }
            )) {
                ForEach(search.results) { result in
                    resultRow(result)
                        .id(result.id).tag(result.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 84)
            .focused($listFocused)
            // A row-level double-tap recognizer consumes AppKit's normal
            // single-click selection. Use the List's native primary action.
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let result = search.results.first(where: { $0.id == id }) {
                    resultMenu(result)
                }
            } primaryAction: { ids in
                guard let id = ids.first, let result = search.results.first(where: { $0.id == id }),
                      result.isDirectory else { return }
                openLocation(result.entry)
            }
            .onMoveCommand { direction in
                if listFocused { _ = move(direction) }
            }
            .onKeyPress(.return) {
                guard listFocused, let result = selectedResult, result.isDirectory else { return .ignored }
                openLocation(result.entry)
                return .handled
            }
            .onChange(of: search.selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .overlay {
            if search.results.isEmpty { emptyState }
        }
    }

    private func resultRow(_ result: LocalSearchResult) -> some View {
        let selected = search.selectedID == result.id
        let entry = result.entry
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: result.isDirectory ? "folder.fill" : "waveform")
                .font(.system(size: 22))
                .foregroundStyle(result.isDirectory ? StudioTheme.accent : StudioTheme.cyan)
                .frame(width: 46, height: 46)
                .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                Text(result.name).font(.system(size: 17, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text("\(result.sourceName) · \(result.path)")
                    .font(.system(size: 13)).foregroundStyle(StudioTheme.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if !result.notes.isEmpty {
                    Text(result.notes).font(.system(size: 14)).foregroundStyle(StudioTheme.secondary).lineLimit(1)
                }
                if !result.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(result.tags.prefix(3)), id: \.self) { tag in
                            Text("#\(tag)").font(.system(size: 12, weight: .medium)).lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .foregroundStyle(StudioTheme.accent)
                                .background(StudioTheme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
                        }
                        if result.tags.count > 3 {
                            Text("+\(result.tags.count - 3)").font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if folders.isFavorite(entry) {
                Image(systemName: "star.fill").font(.system(size: 15)).foregroundStyle(StudioTheme.warning)
                    .accessibilityLabel("お気に入り").padding(.top, 13)
            }
            Image(systemName: result.isDirectory ? "chevron.right" : "play.circle")
                .font(.system(size: result.isDirectory ? 14 : 23)).foregroundStyle(StudioTheme.accent)
                .frame(width: 25).padding(.top, 11)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(selected ? StudioTheme.accent.opacity(0.12) : StudioTheme.sidebar.opacity(0.5), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(selected ? StudioTheme.accent.opacity(0.45) : .clear))
        .help(result.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(result.name + (result.isDirectory ? "、フォルダ" : "、音声"))
        .accessibilityValue(selected ? "選択中" : "")
    }

    @ViewBuilder private func resultMenu(_ result: LocalSearchResult) -> some View {
        let entry = result.entry
        let favorite = folders.favorites.first { $0.savedPath == result.path }
        Button("メモとタグを編集…") { edit(entry) }
        Divider()
        Button(folders.isFavorite(entry) ? "お気に入りから削除" : "お気に入りに追加") { folders.toggleFavorite(entry) }
        FavoriteFolderMembershipMenu(folders: folders, entry: entry)
        if let favorite {
            Button("お気に入りの名前を変更…") { favoriteName = favorite.name; renaming = favorite }
        }
        Divider()
        Button(result.isDirectory ? "フォルダを開く" : "フォルダで表示") { openLocation(entry) }
        Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if search.isSearching {
                ProgressView().controlSize(.small)
                Text("検索中…").font(.system(size: 13)).foregroundStyle(StudioTheme.secondary)
            } else {
                Text("\(search.resultCount.formatted()) 件を表示")
                    .font(.system(size: 13)).monospacedDigit().foregroundStyle(StudioTheme.secondary)
            }
            Spacer(minLength: 8)
            if search.hasMore {
                Button("さらに読み込む", action: search.loadMore)
                    .buttonStyle(StudioButtonStyle()).disabled(search.isSearching)
            } else if !search.results.isEmpty {
                Text("↑↓ で選択 · フォルダは → / Return で開く")
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.secondary).lineLimit(1)
            }
        }.padding(.horizontal, 18).frame(minHeight: 64)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if search.isSearching || (search.isIndexing && !search.isPaused) {
                ProgressView().controlSize(.large).tint(StudioTheme.accent)
            } else {
                Image(systemName: folders.sources.isEmpty ? "folder.badge.plus" : "magnifyingglass")
                    .font(.system(size: 38, weight: .light)).foregroundStyle(StudioTheme.accent)
            }
            Text(emptyTitle).font(.system(size: 23, weight: .semibold))
            Text(emptyMessage).font(.system(size: 15)).foregroundStyle(StudioTheme.secondary)
                .lineSpacing(6).multilineTextAlignment(.center)
            if folders.sources.isEmpty {
                Button(action: folders.chooseSource) { Label("フォルダを追加", systemImage: "folder.badge.plus") }
                    .buttonStyle(StudioButtonStyle(prominent: true))
            } else if search.isPaused {
                Button("読み込みを再開", action: search.resume).buttonStyle(StudioButtonStyle(prominent: true))
            }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if folders.sources.isEmpty { return "ライブラリに素材フォルダを追加" }
        if search.isSearching { return "サンプルを検索中…" }
        if search.isPaused { return "ライブラリの読み込みを一時停止中" }
        if search.isIndexing { return "ライブラリを読み込み中" }
        return search.query.isEmpty ? "検索できる素材はありません" : "一致する素材はありません"
    }

    private var emptyMessage: String {
        if folders.sources.isEmpty { return "Mac や接続済み NAS の素材フォルダを追加すると、\n複数の場所をまとめて検索できます。" }
        if search.isSearching { return "名前・メモ・タグから一致する素材を探しています。" }
        if search.isPaused { return "読み込み済みの素材は引き続き検索できます。\n続きを探すには読み込みを再開してください。" }
        if search.isIndexing { return "読み込めた素材から順に検索できます。\nNAS の大きなフォルダは時間がかかる場合があります。" }
        if !search.errors.isEmpty { return "上のエラーを確認し、NAS に再接続して再試行してください。" }
        return search.query.isEmpty ? "登録した場所と対応音声を確認し、更新してください。" : "検索する言葉やタグを変えてください。"
    }

    private var selectedResult: LocalSearchResult? {
        guard let selectedID = search.selectedID else { return nil }
        return search.results.first { $0.id == selectedID }
    }

    @discardableResult private func move(_ direction: MoveCommandDirection) -> Bool {
        switch direction {
        case .up, .down:
            guard let id = FolderColumnKeyboardNavigation.nextID(
                in: search.results.map(\.id), selectedID: search.selectedID, movingDown: direction == .down
            ) else { return true }
            search.selectedID = id
            return true
        case .right:
            guard let result = selectedResult, result.isDirectory else { return false }
            openLocation(result.entry)
            return true
        default:
            return false
        }
    }
}
