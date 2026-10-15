import Foundation
import Combine

enum BrowserDestination { case folders, librarySearch, favorites, tags, index }

/// Display aliases for shared-index favorites are local preferences, never file names.
@MainActor final class FavoriteAliasStore: ObservableObject {
    @Published private var names: [String: String]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        names = defaults.dictionary(forKey: "sharedFavoriteAliases") as? [String: String] ?? [:]
    }
    func name(key: String, fallback: String) -> String { names[key] ?? fallback }
    func rename(key: String, name: String) {
        let value = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !value.isEmpty else { return }
        names[key] = value
        defaults.set(names, forKey: "sharedFavoriteAliases")
    }
}
