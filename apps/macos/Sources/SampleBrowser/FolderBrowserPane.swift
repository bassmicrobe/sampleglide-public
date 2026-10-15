import SwiftUI
import AppKit

struct FolderBrowserPane: View {
    @ObservedObject var folders: FolderBrowserModel
    @ObservedObject var annotations: LocalAnnotationStore
    @Binding var query: String
    let editAnnotation: (FolderEntry) -> Void
    @FocusState private var focusedColumn: Int?
    @State private var renaming: FolderFavorite?
    @State private var favoriteName = ""
    @State private var pendingEnter: PendingColumnEnter?

    private struct PendingColumnEnter {
        let parentID: String
        let childID: String
    }

    var body: some View {
        VStack(spacing: 0) {
            if folders.columns.isEmpty {
                VStack(spacing: 18) {
                    Image(systemName: "rectangle.split.3x1").font(.system(size: 42, weight: .light)).foregroundStyle(StudioTheme.accent)
                    Text("フォルダから、音を探す").font(.system(size: 25, weight: .semibold))
                    Text("Mac や接続済み NAS のフォルダを追加。\n階層をたどり、サンプルを選ぶと波形を表示します。")
                        .font(.system(size: 15)).foregroundStyle(StudioTheme.secondary).lineSpacing(6).multilineTextAlignment(.center)
                    Button(action: folders.chooseSource) { Label("フォルダを追加", systemImage: "folder.badge.plus") }.buttonStyle(StudioButtonStyle(prominent: true))
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(spacing: 0) {
                                ForEach(Array(folders.columns.enumerated()), id: \.element.id) { index, column in
                                    columnView(column, index: index)
                                        .frame(width: max(275, min(360, geometry.size.width / 3)))
                                        .id(column.id)
                                    Rectangle().fill(StudioTheme.border).frame(width: 1)
                                }
                            }.frame(height: geometry.size.height)
                        }
                        .onChange(of: folders.columns.last?.id) { _, _ in
                            if let last = folders.columns.last { proxy.scrollTo(last.id, anchor: .trailing) }
                        }
                        .onChange(of: focusedColumn) { _, index in
                            guard let index, folders.columns.indices.contains(index) else { return }
                            proxy.scrollTo(folders.columns[index].id)
                        }
                    }
                }
            }
            Rectangle().fill(StudioTheme.border).frame(height: 1)
            HStack(spacing: 9) {
                Image(systemName: folders.selectedEntry?.isDirectory == false ? "waveform" : "folder")
                    .foregroundStyle(StudioTheme.accent)
                Text(folders.selectedEntry?.url.path ?? folders.columns.last?.directoryURL.path ?? "読み取り専用でフォルダを参照します")
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 0)
            }.font(.system(size: 13)).foregroundStyle(StudioTheme.secondary).padding(.horizontal, 16).frame(height: 42)
        }
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(StudioTheme.border))
        .background(FolderHierarchyKeyboardView { direction in
            guard let index = focusedColumn, folders.columns.indices.contains(index) else { return false }
            move(direction, inColumn: index)
            return true
        }.frame(width: 0, height: 0))
        .onAppear { focusSelectedColumn() }
        .onChange(of: folders.columns.first?.id) { _, _ in
            pendingEnter = nil
            focusedColumn = folders.columns.isEmpty ? nil : 0
        }
        .onChange(of: folders.columns.map { $0.isLoading ? nil : $0.id }) { _, _ in finishEnteringColumn() }
        .onChange(of: focusedColumn) { _, index in
            guard let request = pendingEnter else { return }
            guard let index, folders.columns.indices.contains(index), folders.columns[index].id == request.childID else { pendingEnter = nil; return }
            finishEnteringColumn()
        }
        .onChange(of: folders.selectedEntry?.id) { _, _ in
            if let pendingEnter, folders.selectedEntry?.id != pendingEnter.childID { self.pendingEnter = nil }
            // Search and favorites can reveal either kind of entry several
            // levels down. Keep arrows on its column after the async reveal.
            // AppKit may temporarily restore the now-empty search field when
            // the result List disappears. Transfer that focus, but preserve
            // a query the user has started typing while the NAS is loading.
            let window = NSApp.keyWindow
            let responder = window?.firstResponder
            let isEditingQuery = !query.isEmpty && (responder is NSTextView || responder is NSTextField)
            if folders.selectedEntry != nil, !isEditingQuery, window?.sheetParent == nil, window?.attachedSheet == nil {
                focusSelectedColumn()
            }
        }
        .onDisappear { pendingEnter = nil }
        .alert("お気に入りの名前を変更", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("表示名", text: $favoriteName)
            Button("キャンセル", role: .cancel) { renaming = nil }
            Button("保存") { if let favorite = renaming { folders.renameFavorite(favorite.id, name: favoriteName) }; renaming = nil }
                .disabled(favoriteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("お気に入りの表示名を変更します。元のファイル名・フォルダ名は変わりません。") }
    }

    private func columnView(_ column: FolderColumn, index: Int) -> some View {
        let entries = visibleEntries(in: index)
        return VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "folder.fill").foregroundStyle(StudioTheme.accent)
                Text(column.title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Text("\(entries.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(StudioTheme.secondary)
            }
            .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 16).frame(height: 48)
            .contextMenu {
                let entry = FolderEntry(url: column.directoryURL, name: column.title, isDirectory: true)
                favoriteMenu(entry)
            }
            Rectangle().fill(StudioTheme.border.opacity(0.7)).frame(height: 1)
            // Keep the same focusable List even while its directory is empty or
            // loading, so Left always has a keyboard target to return from.
            ScrollViewReader { proxy in
                List(selection: Binding<String?>(get: { column.selectedEntryID }, set: { id in
                    guard id != column.selectedEntryID,
                          let entry = entries.first(where: { $0.id == id }) else { return }
                    pendingEnter = nil
                    focusedColumn = index
                    folders.select(entry, inColumn: index)
                })) {
                    ForEach(entries) { entry in
                        entryRow(entry, selected: column.selectedEntryID == entry.id)
                            .id(entry.id)
                            .tag(entry.id)
                            .listRowInsets(EdgeInsets(top: 2, leading: 7, bottom: 2, trailing: 7))
                            .listRowSeparator(.hidden)
                            .contextMenu { favoriteMenu(entry) }
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 48)
                .focused($focusedColumn, equals: index)
                .onMoveCommand { move($0, inColumn: index) }
                .onChange(of: column.selectedEntryID, initial: true) { _, id in
                    if let id, entries.contains(where: { $0.id == id }) { proxy.scrollTo(id) }
                }
            }
            .overlay {
                if column.isLoading {
                    ProgressView("フォルダを読み込み中…").font(.system(size: 14))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                } else if let error = column.error {
                    VStack(spacing: 14) {
                        Image(systemName: "externaldrive.badge.exclamationmark").font(.system(size: 27)).foregroundStyle(StudioTheme.warning)
                        Text(error).font(.system(size: 14)).foregroundStyle(StudioTheme.secondary).multilineTextAlignment(.center)
                        Button("再読み込み") { folders.retryColumn(index) }.buttonStyle(StudioButtonStyle())
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if entries.isEmpty {
                    Text(query.isEmpty ? "フォルダ・対応音声はありません" : "一致する項目はありません")
                        .font(.system(size: 14)).foregroundStyle(StudioTheme.secondary).padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                }
            }
        }
        .background(index == folders.columns.count - 1 ? StudioTheme.surface : StudioTheme.sidebar.opacity(0.4))
    }

    private func visibleEntries(in index: Int) -> [FolderEntry] {
        guard folders.columns.indices.contains(index) else { return [] }
        let column = folders.columns[index]
        guard !column.isLoading, column.error == nil else { return [] }
        return index == folders.columns.count - 1 && !query.isEmpty
            ? annotations.matchingEntries(column.entries, query: query, sources: folders.sources) : column.entries
    }

    private func move(_ direction: MoveCommandDirection, inColumn index: Int) {
        guard folders.columns.indices.contains(index) else { return }
        switch direction {
        case .up, .down:
            pendingEnter = nil
            let entries = visibleEntries(in: index)
            guard let id = FolderColumnKeyboardNavigation.nextID(in: entries.map(\.id), selectedID: folders.columns[index].selectedEntryID, movingDown: direction == .down),
                  let entry = entries.first(where: { $0.id == id }) else { return }
            folders.select(entry, inColumn: index)
        case .left:
            pendingEnter = nil
            guard let parent = folders.navigateToParent(fromColumn: index) else { return }
            query = ""
            focusedColumn = parent
        case .right:
            guard let child = folders.navigateIntoDirectory(fromColumn: index) else { return }
            query = ""
            pendingEnter = PendingColumnEnter(parentID: folders.columns[index].id, childID: folders.columns[child].id)
            focusedColumn = child
            finishEnteringColumn()
        default: break
        }
    }

    private func finishEnteringColumn() {
        guard let request = pendingEnter else { return }
        guard let index = folders.columns.firstIndex(where: { $0.id == request.childID }), index > 0,
              folders.columns[index - 1].id == request.parentID,
              folders.columns[index - 1].selectedEntryID == request.childID else { pendingEnter = nil; return }
        guard !folders.columns[index].isLoading else { return }
        guard focusedColumn == index else { return }
        pendingEnter = nil
        let entries = visibleEntries(in: index)
        guard let entry = entries.first(where: { $0.id == folders.columns[index].selectedEntryID }) ?? entries.first else { return }
        if folders.selectedEntry?.id != entry.id { folders.select(entry, inColumn: index) }
    }

    private func focusSelectedColumn() {
        focusedColumn = folders.columns.firstIndex { $0.selectedEntryID == folders.selectedEntry?.id && $0.selectedEntryID != nil }
            ?? folders.columns.indices.last
    }

    private func entryRow(_ entry: FolderEntry, selected: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "waveform")
                .font(.system(size: 18)).foregroundStyle(entry.isDirectory ? StudioTheme.accent : StudioTheme.cyan).frame(width: 23)
            Text(entry.name).font(.system(size: 15, weight: selected ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if let annotation = annotations.annotation(for: entry, sources: folders.sources) {
                Image(systemName: annotation.tags.isEmpty ? "note.text" : "tag.fill")
                    .font(.system(size: 12)).foregroundStyle(StudioTheme.cyan)
                    .help(annotation.tags.map { "#" + $0 }.joined(separator: " ") + (annotation.notes.isEmpty ? "" : "\n" + annotation.notes))
            }
            if folders.isFavorite(entry) { Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(StudioTheme.warning) }
            if entry.isDirectory { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(StudioTheme.secondary) }
        }
        .padding(.horizontal, 7).frame(height: 44).contentShape(Rectangle())
        .help(entry.url.path)
        .accessibilityLabel(entry.name + (entry.isDirectory ? "、フォルダ" : "、音声") + (folders.isFavorite(entry) ? "、お気に入り" : ""))
    }

    @ViewBuilder private func favoriteMenu(_ entry: FolderEntry) -> some View {
        let favorite = folders.favorites.first { folders.entry(for: $0).id == entry.id }
        Button("メモとタグを編集…") { editAnnotation(entry) }
        Divider()
        Button { folders.toggleFavorite(entry) } label: {
            Label(favorite == nil ? "お気に入りに追加" : "お気に入りから削除", systemImage: favorite == nil ? "star" : "star.slash")
        }
        if let favorite {
            Button("お気に入りの名前を変更…") { favoriteName = favorite.name; renaming = favorite }
        }
        FavoriteFolderMembershipMenu(folders: folders, entry: entry)
        Divider()
        Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
    }
}

enum FolderColumnKeyboardNavigation {
    /// A held arrow key stops at the edge without reselecting/restarting the same sample.
    static func nextID<ID: Equatable>(in visibleIDs: [ID], selectedID: ID?, movingDown: Bool) -> ID? {
        guard !visibleIDs.isEmpty else { return nil }
        guard let selectedID, let index = visibleIDs.firstIndex(of: selectedID) else {
            return movingDown ? visibleIDs.first : visibleIDs.last
        }
        let next = index + (movingDown ? 1 : -1)
        return visibleIDs.indices.contains(next) ? visibleIDs[next] : nil
    }
}

struct FolderFavoritesPane: View {
    @ObservedObject var folders: FolderBrowserModel
    @ObservedObject var annotations: LocalAnnotationStore
    let folderID: UUID?
    let query: String
    let activate: (UUID) -> Void
    let openLocation: (UUID) -> Void
    let editAnnotation: (FolderEntry) -> Void
    let focusRequest: UUID
    @State private var renaming: FolderFavorite?
    @State private var favoriteName = ""
    @State private var selectedID: UUID?
    @FocusState private var resultsFocused: Bool
    private var favoriteFolder: FavoriteFolder? { folders.favoriteFolders.first { $0.id == folderID } }
    private var favorites: [FolderFavorite] {
        annotations.matchingFavorites(folders.favorites(in: folderID), query: query, folders: folders)
    }

    var body: some View {
        let favorites = self.favorites
        VStack(spacing: 0) {
            HStack { Text(favoriteFolder?.name ?? "すべてのお気に入り").lineLimit(1); Spacer(); Text("\(favorites.count) 件") }
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(StudioTheme.secondary).padding(18)
            Divider().overlay(StudioTheme.border)
            if favorites.isEmpty {
                VStack(spacing: 15) {
                    Image(systemName: query.isEmpty ? "star" : "magnifyingglass").font(.system(size: 38, weight: .light)).foregroundStyle(StudioTheme.accent)
                    Text(query.isEmpty ? "よく使う音を、すぐそばに" : "一致するお気に入りはありません").font(.system(size: 23, weight: .semibold))
                    Text(emptyMessage)
                        .font(.system(size: 15)).lineSpacing(6).foregroundStyle(StudioTheme.secondary).multilineTextAlignment(.center)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(favorites) { favorite in favoriteRow(favorite) }
                        }.padding(14)
                    }
                .focusable().focusEffectDisabled().focused($resultsFocused)
                    .onMoveCommand { move($0, in: favorites) }
                    .onKeyPress(.return) {
                        guard let favorite = favorites.first(where: { $0.id == selectedID }) else { return .ignored }
                        select(favorite, activateDirectory: true)
                        return .handled
                    }
                    .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
            Text("お気に入り・メモ・タグはこの Mac に保存されます")
                .font(.system(size: 13)).foregroundStyle(StudioTheme.secondary).padding(14)
        }
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(StudioTheme.border))
        .background(FolderHierarchyKeyboardView { direction in
            guard resultsFocused, direction == .up || direction == .down else { return false }
            move(direction, in: favorites)
            return true
        }.frame(width: 0, height: 0))
        .onAppear { selectedID = folders.selectedFavoriteID }
        .task(id: focusRequest) { @MainActor in
            // Request once when entering the pane, after registration and the
            // previous pane's teardown. Filtering must not steal text focus.
            await Task.yield()
            guard !Task.isCancelled, !favorites.isEmpty, NSApp.keyWindow?.attachedSheet == nil else { return }
            resultsFocused = true
        }
        .onChange(of: favorites.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) {
                self.selectedID = nil
                folders.clearFavoriteSelection()
            }
        }
        .alert("お気に入りの名前を変更", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("表示名", text: $favoriteName)
            Button("キャンセル", role: .cancel) { renaming = nil }
            Button("保存") { if let favorite = renaming { folders.renameFavorite(favorite.id, name: favoriteName) }; renaming = nil }
                .disabled(favoriteName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("元のファイル名・フォルダ名は変わりません。") }
    }

    private func favoriteRow(_ favorite: FolderFavorite) -> some View {
        let entry = folders.entry(for: favorite)
        let selected = selectedID == favorite.id
        return Button { select(favorite, activateDirectory: true) } label: {
            favoriteCard(favorite, entry: entry, selected: selected)
        }
        .buttonStyle(.plain).id(favorite.id)
        .help(favorite.isDirectory ? "フォルダを開きます" : "お気に入り一覧でこのサンプルを試聴します")
        .accessibilityLabel(favorite.name + (favorite.isDirectory ? "、フォルダを開く" : "、試聴"))
        .accessibilityValue(selected ? "選択中" : "")
        .contextMenu { favoriteContextMenu(favorite, entry: entry) }
    }

    private func favoriteCard(_ favorite: FolderFavorite, entry: FolderEntry, selected: Bool) -> some View {
        HStack(spacing: 16) {
            Image(systemName: favorite.isDirectory ? "folder.fill" : "waveform")
                .font(.system(size: 23)).foregroundStyle(favorite.isDirectory ? StudioTheme.accent : StudioTheme.cyan)
                .frame(width: 48, height: 48).background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 7) {
                Text(favorite.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text(entry.id).font(.system(size: 13)).foregroundStyle(StudioTheme.secondary).lineLimit(1).truncationMode(.middle)
                favoriteAnnotation(entry)
            }
            Spacer(minLength: 10)
            Text(favorite.isDirectory ? "フォルダ" : "音声").font(.system(size: 13)).foregroundStyle(StudioTheme.secondary)
            Image(systemName: favorite.isDirectory ? "chevron.right" : "play.circle.fill")
                .font(.system(size: favorite.isDirectory ? 15 : 24)).foregroundStyle(StudioTheme.accent)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        .background(selected ? StudioTheme.accent.opacity(0.12) : StudioTheme.sidebar.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? StudioTheme.accent.opacity(0.45) : .clear))
    }

    @ViewBuilder private func favoriteAnnotation(_ entry: FolderEntry) -> some View {
        if let annotation = annotations.annotation(for: entry, sources: folders.sources) {
            if !annotation.tags.isEmpty {
                Text(annotation.tags.map { "#" + $0 }.joined(separator: "  "))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(StudioTheme.accent).lineLimit(1)
            }
            if !annotation.notes.isEmpty {
                Text(annotation.notes).font(.system(size: 13)).foregroundStyle(StudioTheme.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder private func favoriteContextMenu(_ favorite: FolderFavorite, entry: FolderEntry) -> some View {
        Button("メモとタグを編集…") { editAnnotation(entry) }
        Divider()
        Button(favorite.isDirectory ? "開く" : "試聴") { select(favorite, activateDirectory: true) }
        if !favorite.isDirectory { Button("フォルダで表示") { openLocation(favorite.id) } }
        Button("お気に入りの名前を変更…") { favoriteName = favorite.name; renaming = favorite }
        FavoriteFolderMembershipMenu(folders: folders, entry: entry)
        if let folderID {
            Button("このフォルダから外す") { folders.setFavoriteMembership(favorite.id, folderID: folderID, included: false) }
        }
        Divider()
        Button("すべてのお気に入りから削除") { folders.removeFavorite(favorite.id) }
        Divider()
        Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
    }

    private func select(_ favorite: FolderFavorite, activateDirectory: Bool) {
        resultsFocused = true
        selectedID = favorite.id
        if activateDirectory { activate(favorite.id) }
        else if favorite.isDirectory { folders.selectFavoriteDirectory(favorite.id) }
        else { folders.previewFavorite(favorite.id, explicitPlayback: false) }
    }

    private func move(_ direction: MoveCommandDirection, in favorites: [FolderFavorite]) {
        guard direction == .up || direction == .down,
              let id = FolderColumnKeyboardNavigation.nextID(in: favorites.map(\.id), selectedID: selectedID, movingDown: direction == .down),
              let favorite = favorites.first(where: { $0.id == id }) else { return }
        select(favorite, activateDirectory: false)
    }

    private var emptyMessage: String {
        if !query.isEmpty { return "別の名前・メモ・タグで検索してください。" }
        if let favoriteFolder {
            return "フォルダや音声を右クリックして、\n「お気に入りフォルダ」から「\(favoriteFolder.name)」を選ぶと追加できます。"
        }
        return "フォルダや音声を右クリックして追加できます。\nお気に入りフォルダを作って、用途ごとに整理できます。"
    }
}

struct FavoriteFolderMembershipMenu: View {
    @ObservedObject var folders: FolderBrowserModel
    let entry: FolderEntry

    private var favorite: FolderFavorite? {
        folders.favorites.first { folders.entry(for: $0).id == entry.id }
    }

    var body: some View {
        Menu("お気に入りフォルダ") {
            if folders.favoriteFolders.isEmpty {
                Text("サイドバーでフォルダを作成できます")
            } else {
                ForEach(folders.favoriteFolders) { folder in
                    Toggle(folder.name, isOn: Binding(
                        get: { favorite?.folderIDs.contains(folder.id) == true },
                        set: { included in
                            if let favorite {
                                folders.setFavoriteMembership(favorite.id, folderID: folder.id, included: included)
                            } else if included {
                                folders.addFavorite(entry, to: folder.id)
                            }
                        }
                    ))
                }
            }
        }
    }
}
