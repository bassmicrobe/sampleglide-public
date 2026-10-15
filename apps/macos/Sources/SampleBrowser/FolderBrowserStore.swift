import Foundation

struct FolderSource: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var savedPath: String
    var bookmark: Data?
    var url: URL { URL(fileURLWithPath: savedPath, isDirectory: true) }
}

/// Named collections exist only in this app; they never create NAS directories.
struct FavoriteFolder: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    static let defaultID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let defaultFolder = FavoriteFolder(id: defaultID, name: "お気に入り")
}

/// `name` is a local display alias; the original file or folder is never renamed.
struct FolderFavorite: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var savedPath: String
    let isDirectory: Bool
    var sourceID: UUID?
    var relativePath: String?
    var bookmark: Data?
    /// Empty membership keeps the item in All Favorites without a named folder.
    var folderIDs: [UUID] = []
    var url: URL { URL(fileURLWithPath: savedPath, isDirectory: isDirectory) }

    private enum CodingKeys: String, CodingKey {
        case id, name, savedPath, isDirectory, sourceID, relativePath, bookmark, folderIDs
    }
}

// Decoder-only initialization lives in extensions, retaining the existing
// memberwise initializers and their defaulted fields for model call sites.
extension FolderFavorite {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        savedPath = try values.decode(String.self, forKey: .savedPath)
        isDirectory = try values.decode(Bool.self, forKey: .isDirectory)
        sourceID = try values.decodeIfPresent(UUID.self, forKey: .sourceID)
        relativePath = try values.decodeIfPresent(String.self, forKey: .relativePath)
        bookmark = try values.decodeIfPresent(Data.self, forKey: .bookmark)
        folderIDs = try values.decodeIfPresent([UUID].self, forKey: .folderIDs) ?? []
    }
}

struct FolderBrowserState: Codable, Equatable {
    var version = 2
    var sources: [FolderSource] = []
    var favorites: [FolderFavorite] = []
    var favoriteFolders: [FavoriteFolder] = [.defaultFolder]

    private enum CodingKeys: String, CodingKey {
        case version, sources, favorites, favoriteFolders
    }
}

extension FolderBrowserState {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try values.decode(Int.self, forKey: .version)
        guard storedVersion == 1 || storedVersion == 2 else { throw FolderBrowserError.invalidState }
        sources = try values.decode([FolderSource].self, forKey: .sources)
        favorites = try values.decode([FolderFavorite].self, forKey: .favorites)
        version = 2
        if storedVersion == 1 {
            // Migration is in memory only. The original JSON is untouched until
            // the user makes a change and the model explicitly saves version 2.
            favoriteFolders = [.defaultFolder]
            for index in favorites.indices { favorites[index].folderIDs = [FavoriteFolder.defaultID] }
        } else {
            favoriteFolders = try values.decode([FavoriteFolder].self, forKey: .favoriteFolders)
        }
    }
}

enum FolderBrowserError: LocalizedError {
    case invalidURL, tooManySources, tooManyFavorites, tooManyFavoriteFolders, invalidName, invalidState, oversizedState
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Mac にマウントされたフォルダを選択してください。"
        case .tooManySources: return "登録できるフォルダは 64 個までです。"
        case .tooManyFavorites: return "お気に入りは 2,000 個まで登録できます。"
        case .tooManyFavoriteFolders: return "お気に入りフォルダは 64 個まで作成できます。"
        case .invalidName: return "お気に入りの名前は 1〜120 文字で入力してください。"
        case .invalidState: return "保存されたフォルダ設定を読み込めません。"
        case .oversizedState: return "保存されたフォルダ設定が大きすぎます。"
        case .unavailable(let name): return "「\(name)」を開けません。Finder で NAS の接続とアクセス権を確認し、再試行してください。"
        }
    }
}

/// Stores only local preferences, using atomic replacement. Never writes to a sample source.
struct FolderBrowserStore {
    let fileURL: URL
    static let maximumBytes = 8 * 1024 * 1024

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("jp.samplebrowser", isDirectory: true).appendingPathComponent("folders.json")
    }

    func load() throws -> FolderBrowserState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return FolderBrowserState() }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Self.maximumBytes else { throw FolderBrowserError.oversizedState }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= Self.maximumBytes else { throw FolderBrowserError.oversizedState }
        let state = try JSONDecoder().decode(FolderBrowserState.self, from: data)
        try validate(state)
        return state
    }

    func save(_ state: FolderBrowserState) throws {
        try validate(state)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= Self.maximumBytes else { throw FolderBrowserError.oversizedState }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func validate(_ state: FolderBrowserState) throws {
        guard state.version == 2, state.sources.count <= 64, state.favorites.count <= 2000, state.favoriteFolders.count <= 64,
              Set(state.sources.map(\.id)).count == state.sources.count,
              Set(state.favorites.map(\.id)).count == state.favorites.count,
              Set(state.favoriteFolders.map(\.id)).count == state.favoriteFolders.count else { throw FolderBrowserError.invalidState }
        func validPath(_ value: String) -> Bool { value.hasPrefix("/") && !value.contains("\0") && value.utf8.count <= 32_768 }
        func validName(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 120 && !value.contains(where: \.isNewline) && !value.contains("\0") }
        let folderIDs = Set(state.favoriteFolders.map(\.id))
        for folder in state.favoriteFolders {
            guard validName(folder.name) else { throw FolderBrowserError.invalidState }
        }
        for source in state.sources {
            guard validPath(source.savedPath), validName(source.name), (source.bookmark?.count ?? 0) <= 65_536 else { throw FolderBrowserError.invalidState }
        }
        for favorite in state.favorites {
            guard validPath(favorite.savedPath), validName(favorite.name), (favorite.bookmark?.count ?? 0) <= 65_536 else { throw FolderBrowserError.invalidState }
            let membership = Set(favorite.folderIDs)
            guard membership.count == favorite.folderIDs.count, membership.isSubset(of: folderIDs) else { throw FolderBrowserError.invalidState }
            if let relative = favorite.relativePath {
                guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."), !relative.contains("\0") else { throw FolderBrowserError.invalidState }
            }
        }
    }
}
