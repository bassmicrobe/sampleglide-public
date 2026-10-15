import Combine
import Darwin
import Foundation

/// Notes and tags describe the source item, independently of favorite aliases.
struct LocalAnnotation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var savedPath: String
    var isDirectory: Bool
    var sourceID: UUID?
    var relativePath: String?
    var notes: String
    var tags: [String]

    func entry(sources: [FolderSource]) -> FolderEntry {
        if let sourceID, let relativePath,
           LocalAnnotationRules.validRelativePath(relativePath),
           let source = sources.first(where: { $0.id == sourceID }),
           LocalAnnotationRules.validAbsolutePath(source.savedPath) {
            let root = LocalAnnotationRules.normalizedPath(source.savedPath)
            let path = relativePath.isEmpty ? root : (root == "/" ? "/" : root + "/") + relativePath
            return FolderEntry(indexedPath: path, name: (path as NSString).lastPathComponent, isDirectory: isDirectory)
        }
        let path = LocalAnnotationRules.normalizedPath(savedPath)
        return FolderEntry(indexedPath: path, name: (path as NSString).lastPathComponent, isDirectory: isDirectory)
    }
}

private enum LocalAnnotationError: LocalizedError {
    case invalidState, invalidPath, invalidReferences, notesTooLong, invalidTag, tooManyTags, tooManyRecords, oversized, writeFailed
    var errorDescription: String? {
        switch self {
        case .invalidState: return "保存されたメモ・タグを読み込めません。元の設定ファイルを確認してください。"
        case .invalidPath: return "メモ・タグの保存先となる素材のパスが正しくありません。"
        case .invalidReferences: return "素材フォルダの参照情報が正しくありません。フォルダを選び直してください。"
        case .notesTooLong: return "メモは 10,000 文字まで入力できます。"
        case .invalidTag: return "タグは 1〜64 文字で入力してください。改行は使えません。"
        case .tooManyTags: return "1 つの素材に付けられるタグは 32 個までです。"
        case .tooManyRecords: return "メモ・タグは 10,000 個の素材まで保存できます。"
        case .oversized: return "保存するメモ・タグの合計サイズが上限を超えています。"
        case .writeFailed: return "メモ・タグを保存できません。保存先のアクセス権と空き容量を確認してください。"
        }
    }
}

private enum LocalAnnotationRules {
    static let maximumBytes = 16 * 1024 * 1024
    static let maximumRecords = 10_000
    static let maximumNotes = 10_000
    static let maximumTags = 32
    static let maximumTagLength = 64
    static let matchingLocale = Locale(identifier: "en_US_POSIX")

    static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: matchingLocale)
    }

    // Stored paths are absolute and traversal-free. Collapsing separators is
    // lexical; rendering saved annotations must never query a mounted volume.
    static func normalizedPath(_ value: String) -> String {
        "/" + value.split(separator: "/").joined(separator: "/")
    }

    static func cleanTag(_ value: String) -> String {
        var tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("#") { tag.removeFirst() }
        return tag.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizedTags(_ values: [String]) throws -> [String] {
        // Bound raw input as well as the normalized result to avoid unbounded
        // duplicate strings submitted by a malformed preference file or caller.
        guard values.count <= 1024 else { throw LocalAnnotationError.tooManyTags }
        var unique: [String: String] = [:]
        for value in values {
            guard value.utf8.count <= 1024 else { throw LocalAnnotationError.invalidTag }
            let tag = cleanTag(value)
            if tag.isEmpty { continue }
            guard tag.count <= maximumTagLength, !tag.contains(where: \.isNewline), !tag.contains("\0") else { throw LocalAnnotationError.invalidTag }
            let key = folded(tag)
            if unique[key] == nil { unique[key] = tag }
        }
        guard unique.count <= maximumTags else { throw LocalAnnotationError.tooManyTags }
        return unique.keys.sorted().compactMap { unique[$0] }
    }

    static func validAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\0") && value.utf8.count <= 32_768 &&
        !value.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
    }

    static func validRelativePath(_ value: String) -> Bool {
        guard !value.hasPrefix("/"), !value.contains("\0"), value.utf8.count <= 32_768 else { return false }
        if value.isEmpty { return true }
        return !value.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

}

private struct LocalAnnotationQuery {
    private struct Token {
        let key: String
        let isTag: Bool
    }
    private let tokens: [Token]
    init(_ query: String) {
        tokens = query.split(whereSeparator: \.isWhitespace).map { token in
            let value = String(token), isTag = token.hasPrefix("#")
            return Token(key: LocalAnnotationRules.folded(isTag ? LocalAnnotationRules.cleanTag(value) : value), isTag: isTag)
        }
    }
    var isEmpty: Bool { tokens.isEmpty }
    func matches(namesAndNotes: [String], tags: [String]) -> Bool {
        tokens.allSatisfy { token in
            if token.isTag { return !token.key.isEmpty && tags.contains { $0.contains(token.key) } }
            return namesAndNotes.contains { $0.contains(token.key) } || tags.contains { $0.contains(token.key) }
        }
    }
}

/// App-local annotations. Reading and writing never touch source samples or NAS
/// directories. Failed loads block writes so corruption cannot erase old notes.
@MainActor final class LocalAnnotationStore: ObservableObject {
    @Published private(set) var records: [LocalAnnotation] = []
    @Published var error: String?
    private let fileURL: URL
    private var loadFailure: String?
    private struct StableIdentity: Hashable {
        let sourceID: UUID
        let relativePath: String
        let isDirectory: Bool
    }
    private struct PathIdentity: Hashable {
        let path: String
        let isDirectory: Bool
    }
    private struct SourceLocation: Equatable {
        let id: UUID
        let path: String
    }
    private struct IndexedSource {
        let id: UUID
        let path: String
        let childPrefix: String
    }
    private var identityIndex: [StableIdentity: LocalAnnotation] = [:]
    private var resolvedPathIndex: [PathIdentity: LocalAnnotation] = [:]
    private struct SearchFields {
        let notes: String
        let tags: [String]
    }
    private struct SearchKey: Equatable {
        let query: String
        let tag: String?
    }
    private var searchFields: [UUID: SearchFields] = [:]
    private var resolvedEntries: [UUID: FolderEntry] = [:]
    private var foldedNames: [UUID: String] = [:]
    private var orderedRecords: [LocalAnnotation] = []
    private var cachedSearch: (key: SearchKey, results: [LocalAnnotation])?
    private var indexedSources: [SourceLocation]?
    private var orderedSources: [IndexedSource] = []
    private var pathsNeedRebuild = true
    private var cachedTags: [String] = []

    private struct State: Codable {
        var version = 1
        var records: [LocalAnnotation]
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jp.samplebrowser", isDirectory: true).appendingPathComponent("annotations.json")
        guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: self.fileURL.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= LocalAnnotationRules.maximumBytes else { throw LocalAnnotationError.oversized }
            let data = try Data(contentsOf: self.fileURL)
            guard data.count <= LocalAnnotationRules.maximumBytes else { throw LocalAnnotationError.oversized }
            let state = try JSONDecoder().decode(State.self, from: data)
            guard state.version == 1 else { throw LocalAnnotationError.invalidState }
            try validate(state.records)
            records = state.records
            rebuildRecordIndex()
        } catch {
            let message = "メモ・タグの読込に失敗しました。既存データを保護するため保存を停止しています。\n\(error.localizedDescription)"
            loadFailure = message; self.error = message
        }
    }

    var allTags: [String] { cachedTags }

    func annotation(for entry: FolderEntry, sources: [FolderSource]) -> LocalAnnotation? {
        guard !records.isEmpty, entry.url.isFileURL else { return nil }
        ensureSourceIndex(sources)
        if let anchor = anchor(for: entry),
           let exact = identityIndex[StableIdentity(sourceID: anchor.sourceID, relativePath: anchor.relativePath, isDirectory: entry.isDirectory)] {
            return exact
        }
        return resolvedPathIndex[PathIdentity(path: entry.id, isDirectory: entry.isDirectory)]
    }

    @discardableResult func save(entry: FolderEntry, notes: String, tags: [String], sources: [FolderSource]) -> Bool {
        if let loadFailure { error = loadFailure; return false }
        do {
            guard entry.url.isFileURL, LocalAnnotationRules.validAbsolutePath(entry.url.path) else { throw LocalAnnotationError.invalidPath }
            guard sources.count <= 64, Set(sources.map(\.id)).count == sources.count,
                  sources.allSatisfy({ LocalAnnotationRules.validAbsolutePath($0.savedPath) }) else { throw LocalAnnotationError.invalidReferences }
            guard notes.count <= LocalAnnotationRules.maximumNotes, !notes.contains("\0") else { throw LocalAnnotationError.notesTooLong }
            let normalized = try LocalAnnotationRules.normalizedTags(tags)
            let existing = annotation(for: entry, sources: sources)
            var next = records
            if notes.isEmpty && normalized.isEmpty {
                if let existing { next.removeAll { $0.id == existing.id } }
                else { error = nil; return true }
            } else {
                ensureSourceIndex(sources)
                let location = anchor(for: entry)
                let value = LocalAnnotation(id: existing?.id ?? UUID(), savedPath: entry.id, isDirectory: entry.isDirectory,
                    sourceID: location?.sourceID, relativePath: location?.relativePath, notes: notes, tags: normalized)
                if let index = next.firstIndex(where: { $0.id == value.id }) { next[index] = value }
                else { next.append(value) }
            }
            try validate(next)
            try write(next)
            records = next; rebuildRecordIndex(); error = nil
            return true
        } catch {
            self.error = "メモ・タグを保存できませんでした。\n\(error.localizedDescription)"
            return false
        }
    }

    func matches(entry: FolderEntry, query: String, sources: [FolderSource], alternateName: String? = nil) -> Bool {
        matches(entry: entry, query: LocalAnnotationQuery(query), sources: sources, alternateName: alternateName)
    }

    func matchingEntries(_ entries: [FolderEntry], query: String, sources: [FolderSource]) -> [FolderEntry] {
        let parsed = LocalAnnotationQuery(query)
        guard !parsed.isEmpty else { return entries }
        return entries.filter { matches(entry: $0, query: parsed, sources: sources) }
    }

    func matchingFavorites(_ favorites: [FolderFavorite], query: String, folders: FolderBrowserModel) -> [FolderFavorite] {
        let parsed = LocalAnnotationQuery(query)
        guard !parsed.isEmpty else { return favorites }
        return favorites.filter { matches(entry: folders.entry(for: $0), query: parsed, sources: folders.sources, alternateName: $0.name) }
    }

    private func matches(entry: FolderEntry, query: LocalAnnotationQuery, sources: [FolderSource], alternateName: String? = nil) -> Bool {
        guard !query.isEmpty else { return true }
        let value = annotation(for: entry, sources: sources)
        let fields = value.flatMap { searchFields[$0.id] }
        return query.matches(namesAndNotes: [LocalAnnotationRules.folded(entry.name), LocalAnnotationRules.folded(alternateName ?? ""), fields?.notes ?? ""], tags: fields?.tags ?? [])
    }

    func entry(for annotation: LocalAnnotation, sources: [FolderSource]) -> FolderEntry {
        ensureSourceIndex(sources)
        return resolvedEntries[annotation.id] ?? annotation.entry(sources: sources)
    }

    func search(query: String, tag: String? = nil, sources: [FolderSource]) -> [LocalAnnotation] {
        ensureSourceIndex(sources)
        let key = SearchKey(query: query, tag: tag)
        if let cachedSearch, cachedSearch.key == key { return cachedSearch.results }
        let parsed = LocalAnnotationQuery(query)
        let exactTag = tag.map(LocalAnnotationRules.cleanTag).map(LocalAnnotationRules.folded)
        let results = orderedRecords.filter { value in
            guard let fields = searchFields[value.id] else { return false }
            if let exactTag, !exactTag.isEmpty, !fields.tags.contains(exactTag) { return false }
            return parsed.matches(namesAndNotes: [foldedNames[value.id] ?? "", fields.notes], tags: fields.tags)
        }
        cachedSearch = (key, results)
        return results
    }

    private func anchor(for entry: FolderEntry) -> (sourceID: UUID, relativePath: String)? {
        // Prefer the most specific registered root if roots overlap.
        for source in orderedSources {
            if entry.id == source.path {
                if entry.isDirectory { return (source.id, "") }
                continue
            }
            guard entry.id.hasPrefix(source.childPrefix) else { continue }
            let relative = String(entry.id.dropFirst(source.childPrefix.count))
            guard LocalAnnotationRules.validRelativePath(relative) else { continue }
            return (source.id, relative)
        }
        return nil
    }

    private func rebuildRecordIndex() {
        identityIndex.removeAll(keepingCapacity: true)
        searchFields.removeAll(keepingCapacity: true)
        var uniqueTags: [String: String] = [:]
        for record in records {
            searchFields[record.id] = SearchFields(notes: LocalAnnotationRules.folded(record.notes), tags: record.tags.map(LocalAnnotationRules.folded))
            if let sourceID = record.sourceID, let relativePath = record.relativePath {
                identityIndex[StableIdentity(sourceID: sourceID, relativePath: relativePath, isDirectory: record.isDirectory)] = record
            }
            for tag in record.tags {
                let key = LocalAnnotationRules.folded(tag)
                if uniqueTags[key] == nil { uniqueTags[key] = tag }
            }
        }
        cachedTags = uniqueTags.keys.sorted().compactMap { uniqueTags[$0] }
        pathsNeedRebuild = true
        cachedSearch = nil
    }

    /// Each visible row uses dictionary lookup. Re-resolving all stored paths is
    /// needed only after a save or a changed mount/source mapping, never per row.
    private func ensureSourceIndex(_ sources: [FolderSource]) {
        let sameSources = indexedSources.map { previous in
            previous.count == sources.count && zip(previous, sources).allSatisfy {
                $0.id == $1.id && $0.path == $1.savedPath
            }
        } ?? false
        if !sameSources {
            indexedSources = sources.map { SourceLocation(id: $0.id, path: $0.savedPath) }
            orderedSources = sources.compactMap { source in
                guard LocalAnnotationRules.validAbsolutePath(source.savedPath) else { return nil }
                let path = LocalAnnotationRules.normalizedPath(source.savedPath)
                return IndexedSource(id: source.id, path: path, childPrefix: path == "/" ? "/" : path + "/")
            }.sorted { $0.path.count > $1.path.count }
            pathsNeedRebuild = true
        }
        guard pathsNeedRebuild else { return }
        pathsNeedRebuild = false
        cachedSearch = nil
        resolvedPathIndex.removeAll(keepingCapacity: true)
        resolvedEntries.removeAll(keepingCapacity: true)
        foldedNames.removeAll(keepingCapacity: true)
        for record in records {
            let path: String
            if let sourceID = record.sourceID, let relativePath = record.relativePath,
               let source = orderedSources.first(where: { $0.id == sourceID }) {
                path = relativePath.isEmpty ? source.path : source.childPrefix + relativePath
            } else {
                path = LocalAnnotationRules.normalizedPath(record.savedPath)
            }
            resolvedPathIndex[PathIdentity(path: path, isDirectory: record.isDirectory)] = record
            let name = (path as NSString).lastPathComponent
            resolvedEntries[record.id] = FolderEntry(indexedPath: path, name: name, isDirectory: record.isDirectory)
            foldedNames[record.id] = LocalAnnotationRules.folded(name)
        }
        orderedRecords = records.sorted {
            let comparison = (resolvedEntries[$0.id]?.name ?? "").localizedStandardCompare(resolvedEntries[$1.id]?.name ?? "")
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
    }

    private func validate(_ values: [LocalAnnotation]) throws {
        guard values.count <= LocalAnnotationRules.maximumRecords else { throw LocalAnnotationError.tooManyRecords }
        guard Set(values.map(\.id)).count == values.count else { throw LocalAnnotationError.invalidState }
        var sourceIdentities: Set<String> = [], paths: Set<String> = []
        for value in values {
            guard LocalAnnotationRules.validAbsolutePath(value.savedPath) else { throw LocalAnnotationError.invalidPath }
            guard value.notes.count <= LocalAnnotationRules.maximumNotes, !value.notes.contains("\0") else { throw LocalAnnotationError.notesTooLong }
            let normalized = try LocalAnnotationRules.normalizedTags(value.tags)
            guard normalized == value.tags, !value.notes.isEmpty || !value.tags.isEmpty else { throw LocalAnnotationError.invalidState }
            guard paths.insert("\(value.isDirectory)|\(LocalAnnotationRules.normalizedPath(value.savedPath))").inserted else { throw LocalAnnotationError.invalidState }
            switch (value.sourceID, value.relativePath) {
            case (nil, nil): break
            case let (sourceID?, relative?):
                guard LocalAnnotationRules.validRelativePath(relative), !relative.isEmpty || value.isDirectory else { throw LocalAnnotationError.invalidReferences }
                guard sourceIdentities.insert("\(value.isDirectory)|\(sourceID.uuidString)|\(relative)").inserted else { throw LocalAnnotationError.invalidState }
            default: throw LocalAnnotationError.invalidReferences
            }
        }
    }

    private func write(_ values: [LocalAnnotation]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(State(records: values))
        guard data.count <= LocalAnnotationRules.maximumBytes else { throw LocalAnnotationError.oversized }
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".annotations-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw LocalAnnotationError.writeFailed }
        // Same-directory rename atomically replaces the old snapshot only after
        // the complete new file and its private permissions are in place.
        guard Darwin.rename(temporary.path, fileURL.path) == 0 else { throw LocalAnnotationError.writeFailed }
    }
}
