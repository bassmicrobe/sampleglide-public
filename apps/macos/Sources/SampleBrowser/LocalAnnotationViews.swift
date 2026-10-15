import SwiftUI
import AppKit

struct LocalAnnotationEditor: View {
    let entry: FolderEntry
    @ObservedObject var store: LocalAnnotationStore
    let sources: [FolderSource]
    let onSaved: () -> Void
    let onCancel: () -> Void
    @State private var notes = ""
    @State private var tags: [String] = []
    @State private var tagInput = ""
    @State private var saveError: String?
    @State private var initialized = false

    private var suggestedTags: [String] {
        Array(store.allTags.filter { candidate in !tags.contains { sameTag($0, candidate) } }.prefix(12))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "text.bubble.fill").font(.system(size: 25)).foregroundStyle(StudioTheme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("メモとタグを編集").font(.system(size: 25, weight: .bold))
                    Text("この Mac に保存します").font(.system(size: 14)).foregroundStyle(StudioTheme.secondary)
                }
                Spacer()
            }.padding(24)
            Rectangle().fill(StudioTheme.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(entry.name, systemImage: entry.isDirectory ? "folder.fill" : "waveform")
                            .font(.system(size: 17, weight: .semibold)).lineLimit(2)
                        Text(entry.url.path).font(.system(size: 13)).foregroundStyle(StudioTheme.secondary)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16).background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 13))
                    notesEditor
                    tagsEditor
                }.padding(24)
            }
            Rectangle().fill(StudioTheme.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 14) {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 14)).foregroundStyle(StudioTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("保存できませんでした。\(saveError)")
                }
                HStack(spacing: 12) {
                    Spacer()
                    Button(action: onCancel) { Text("キャンセル").font(.system(size: 15, weight: .semibold)) }
                        .buttonStyle(StudioButtonStyle()).keyboardShortcut(.cancelAction)
                        .accessibilityLabel("メモとタグの編集をキャンセル")
                    Button(action: save) { Text("保存").font(.system(size: 15, weight: .semibold)) }
                        .buttonStyle(StudioButtonStyle(prominent: true))
                        .keyboardShortcut("s", modifiers: .command)
                        .accessibilityLabel("メモとタグを保存")
                }
            }.padding(20)
        }
        .frame(width: 620, height: 680)
        .foregroundStyle(StudioTheme.text)
        .background(StudioTheme.surface)
        .tint(StudioTheme.accent)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            if let annotation = store.annotation(for: entry, sources: sources) {
                notes = annotation.notes
                tags = annotation.tags
            }
        }
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("メモ").font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("\(notes.count.formatted()) / 10,000")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(notes.count > 10_000 ? StudioTheme.warning : StudioTheme.secondary)
            }
            TextEditor(text: $notes)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(height: 150)
                .background(StudioTheme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudioTheme.border))
                .accessibilityLabel("素材のメモ")
        }
    }

    private var tagsEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("タグ").font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("\(tags.count) / 32").font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(tags.count > 32 ? StudioTheme.warning : StudioTheme.secondary)
            }
            HStack(spacing: 10) {
                TextField("例: kick, warm, house", text: $tagInput, axis: .vertical)
                    .lineLimit(1...3).font(.system(size: 15)).textFieldStyle(.plain)
                    .padding(.horizontal, 13).padding(.vertical, 12).frame(minHeight: 44)
                    .background(StudioTheme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StudioTheme.border))
                    .onSubmit(addInputTags)
                    .accessibilityLabel("追加するタグ")
                Button(action: addInputTags) { Text("追加").font(.system(size: 15, weight: .semibold)) }
                    .buttonStyle(StudioButtonStyle())
                    .disabled(parsedInputTags.isEmpty)
                    .accessibilityLabel("入力したタグを追加")
            }
            Text("カンマや改行でまとめて追加できます。タグは各64文字まで。")
                .font(.system(size: 13)).foregroundStyle(StudioTheme.secondary)
            if !tags.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        Button {
                            tags.removeAll { $0 == tag }
                            saveError = nil
                        } label: {
                            HStack(spacing: 8) {
                                Text(tag).font(.system(size: 15, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            }
                            .padding(.horizontal, 12).frame(height: 44)
                            .background(StudioTheme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain).foregroundStyle(StudioTheme.accent)
                        .help(tag).accessibilityLabel("タグ「\(tag)」を削除")
                    }
                }
            }
            if !suggestedTags.isEmpty {
                Text("使ったことのあるタグ").font(.system(size: 13)).foregroundStyle(StudioTheme.secondary).padding(.top, 3)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(suggestedTags, id: \.self) { tag in
                        Button { appendTags([tag]); saveError = nil } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                                Text(tag).font(.system(size: 15)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12).frame(height: 44)
                            .background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain).help(tag).accessibilityLabel("既存のタグ「\(tag)」を追加")
                    }
                }
            }
        }
    }

    private var parsedInputTags: [String] {
        tagInput.components(separatedBy: CharacterSet(charactersIn: ",，、\n\r"))
            .map { value in
                String(value.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "#" }))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    private func sameTag(_ lhs: String, _ rhs: String) -> Bool {
        let locale = Locale(identifier: "en_US_POSIX")
        return lhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            == rhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }

    private func appendTags(_ additions: [String]) {
        for tag in additions where !tags.contains(where: { sameTag($0, tag) }) { tags.append(tag) }
    }

    private func addInputTags() {
        appendTags(parsedInputTags)
        tagInput = ""
        saveError = nil
    }

    private func save() {
        // Save includes the last typed tag even if the Add button was not used.
        addInputTags()
        if store.save(entry: entry, notes: notes, tags: tags, sources: sources) {
            onSaved()
        } else {
            saveError = store.error ?? "メモとタグを保存できませんでした。"
        }
    }
}

struct LocalTagSearchPane: View {
    @ObservedObject var store: LocalAnnotationStore
    @ObservedObject var folders: FolderBrowserModel
    let query: String
    @Binding var selectedTag: String?
    let activate: (FolderEntry) -> Void
    let edit: (FolderEntry) -> Void
    var selectionChanged: (FolderEntry?) -> Void = { _ in }
    let focusRequest: UUID
    @State private var selectedID: UUID?
    @FocusState private var resultsFocused: Bool

    var body: some View {
        let results = store.search(query: query, tag: selectedTag, sources: folders.sources)
        VStack(spacing: 0) {
            HStack {
                Text("保存したメモとタグ").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(results.count) 件").font(.system(size: 14)).foregroundStyle(StudioTheme.secondary)
            }.padding(18)
            if !store.allTags.isEmpty { tagFilters }
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14)).foregroundStyle(StudioTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(StudioTheme.warning.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 18).padding(.bottom, 14)
                    .accessibilityLabel("メモとタグのエラー。\(error)")
            }
            Rectangle().fill(StudioTheme.border).frame(height: 1)
            if results.isEmpty {
                VStack(spacing: 15) {
                    Image(systemName: store.error == nil ? "tag" : "exclamationmark.triangle")
                        .font(.system(size: 38, weight: .light)).foregroundStyle(StudioTheme.accent)
                    Text(store.error != nil ? "メモ・タグを確認してください" : (store.records.isEmpty ? "音の特徴を、タグで整理" : "一致する素材はありません"))
                        .font(.system(size: 23, weight: .semibold))
                    Text(store.error != nil ? "上に表示されたエラー内容を確認してください。" : (store.records.isEmpty
                         ? "素材を右クリックして「メモとタグを編集」から保存すると、\nここでタグやメモから探せます。"
                         : "検索する言葉やタグを変えてください。"))
                        .font(.system(size: 15)).foregroundStyle(StudioTheme.secondary)
                        .lineSpacing(6).multilineTextAlignment(.center)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(results) { annotation in annotationRow(annotation) }
                        }.padding(14)
                    }
                .focusable().focusEffectDisabled().focused($resultsFocused)
                    .onMoveCommand { move($0, in: results) }
                    .onKeyPress(.return) {
                        guard let annotation = results.first(where: { $0.id == selectedID }) else { return .ignored }
                        select(annotation, activateDirectory: true)
                        return .handled
                    }
                    .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
            Rectangle().fill(StudioTheme.border).frame(height: 1)
            Text("この Mac に保存したメモ・タグを検索します")
                .font(.system(size: 13)).foregroundStyle(StudioTheme.secondary).padding(14)
        }
        .foregroundStyle(StudioTheme.text)
        .background(StudioTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(StudioTheme.border))
        .background(FolderHierarchyKeyboardView { direction in
            guard resultsFocused, direction == .up || direction == .down else { return false }
            move(direction, in: results)
            return true
        }.frame(width: 0, height: 0))
        .task(id: focusRequest) { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, !results.isEmpty, NSApp.keyWindow?.attachedSheet == nil else { return }
            resultsFocused = true
        }
        .onChange(of: results.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) {
                self.selectedID = nil
                selectionChanged(nil)
            }
        }
        .onChange(of: store.allTags) { _, tags in
            if let selectedTag, !tags.contains(selectedTag) { self.selectedTag = nil }
        }
    }

    private var tagFilters: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                tagFilter("すべて", tag: nil)
                ForEach(store.allTags, id: \.self) { tag in tagFilter(tag, tag: tag) }
            }.padding(.horizontal, 18).padding(.bottom, 14)
        }.scrollIndicators(.hidden).frame(height: 58)
    }

    private func tagFilter(_ title: String, tag: String?) -> some View {
        let active = selectedTag == tag
        return Button { selectedTag = tag } label: {
            HStack(spacing: 7) {
                if tag != nil { Image(systemName: active ? "checkmark" : "number").font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.system(size: 15, weight: active ? .semibold : .regular)).lineLimit(1)
            }
            .padding(.horizontal, 14).frame(height: 44)
            .foregroundStyle(active ? StudioTheme.background : StudioTheme.text)
            .background(active ? StudioTheme.accent : StudioTheme.raised, in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tag.map { "タグ「\($0)」で絞り込む" } ?? "すべてのタグを表示")
        .accessibilityValue(active ? "選択中" : "")
    }

    private func annotationRow(_ annotation: LocalAnnotation) -> some View {
        let entry = store.entry(for: annotation, sources: folders.sources)
        let selected = selectedID == annotation.id
        return Button { select(annotation, activateDirectory: true) } label: {
            HStack(alignment: .top, spacing: 15) {
                Image(systemName: entry.isDirectory ? "folder.fill" : "waveform")
                    .font(.system(size: 23)).foregroundStyle(entry.isDirectory ? StudioTheme.accent : StudioTheme.cyan)
                    .frame(width: 48, height: 48).background(StudioTheme.raised, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 7) {
                    Text(entry.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    Text(entry.url.path).font(.system(size: 13)).foregroundStyle(StudioTheme.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if !annotation.notes.isEmpty {
                        Text(annotation.notes.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 14)).foregroundStyle(StudioTheme.secondary).lineLimit(2)
                    }
                    if !annotation.tags.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(annotation.tags.prefix(4)), id: \.self) { tag in
                                Text(tag).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .foregroundStyle(StudioTheme.accent)
                                    .background(StudioTheme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
                            }
                            if annotation.tags.count > 4 {
                                Text("+\(annotation.tags.count - 4)").font(.system(size: 12)).foregroundStyle(StudioTheme.secondary)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: entry.isDirectory ? "chevron.right" : "play.circle.fill")
                    .font(.system(size: entry.isDirectory ? 15 : 24)).foregroundStyle(StudioTheme.accent).padding(.top, 12)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .background(selected ? StudioTheme.accent.opacity(0.12) : StudioTheme.sidebar.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? StudioTheme.accent.opacity(0.45) : .clear))
        }
        .buttonStyle(.plain).id(annotation.id)
        .accessibilityLabel(entry.name + (entry.isDirectory ? "、フォルダを開く" : "、試聴"))
        .accessibilityValue(selected ? "選択中" : "")
        .help("右クリックでメモとタグを編集できます")
        .contextMenu {
            Button(entry.isDirectory ? "開く" : "試聴") { select(annotation, activateDirectory: true) }
            Button("メモとタグを編集…") { edit(entry) }
            Divider()
            Button(folders.isFavorite(entry) ? "お気に入りから削除" : "お気に入りに追加") { folders.toggleFavorite(entry) }
            FavoriteFolderMembershipMenu(folders: folders, entry: entry)
            Divider()
            Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        }
    }

    private func select(_ annotation: LocalAnnotation, activateDirectory: Bool) {
        selectedID = annotation.id
        resultsFocused = true
        let entry = store.entry(for: annotation, sources: folders.sources)
        if activateDirectory { activate(entry) }
        else { selectionChanged(entry) }
    }

    private func move(_ direction: MoveCommandDirection, in results: [LocalAnnotation]) {
        guard direction == .up || direction == .down,
              let id = FolderColumnKeyboardNavigation.nextID(in: results.map(\.id), selectedID: selectedID, movingDown: direction == .down),
              let annotation = results.first(where: { $0.id == id }) else { return }
        select(annotation, activateDirectory: false)
    }
}
