import Foundation
import Security

struct MusicalKey: Codable, Sendable { var root: Int; var mode: String
    var label: String { ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"][max(0, min(11, root))] + (mode == "minor" ? " min" : " maj") }
}
struct Sample: Codable, Identifiable, Sendable {
    var id: UUID; var sourceRevision: Int64; var name: String; var path: String?; var sourceState: String; var rootState: String?
    var bpm: Double?; var keyState: String; var key: MusicalKey?; var durationSeconds: Double?; var sampleKind: String?
    var favorite: Bool; var tagIds: [UUID]; var tagVersion: Int64; var analysis: [String:String]
    var bpmLabel: String { bpm.map { String(format: "%.1f", $0) } ?? analysisLabel("bpm") }
    var keyLabel: String { key?.label ?? (keyState == "unpitched" ? "音程なし" : analysisLabel("key")) }
    private func analysisLabel(_ field: String) -> String {
        switch analysis[field] { case "pending": return "解析待ち"; case "running": return "解析中"; case "failed": return "解析失敗"; case "unsupported": return "非対応"; default: return "不明" }
    }
}
struct SearchPage: Decodable, Sendable { var items: [Sample]; var nextCursor: String?; var hasMore: Bool }
struct FavoriteState: Decodable, Sendable { var favorite: Bool; var recordVersion: Int64 }
struct Annotations: Codable, Sendable {
    var bpmMode: String; var bpmValue: Double?; var keyMode: String; var keyValue: MusicalKey?; var keyNoneReason: String; var sampleKind: String; var beatOffsetFrames: Int64?; var notes: String; var recordVersion: Int64
    var body: [String: Any] { ["bpm_mode": bpmMode, "bpm_value": bpmValue as Any? ?? NSNull(), "key_mode": keyMode, "key_value": keyValue.map { ["root": $0.root, "mode": $0.mode] as [String:Any] } as Any? ?? NSNull(), "key_none_reason": keyNoneReason, "sample_kind": sampleKind, "beat_offset_frames": beatOffsetFrames as Any? ?? NSNull(), "notes": notes] }
}
struct SampleDetail: Decodable, Sendable { var sample: Sample; var annotations: Annotations; var favoriteState: FavoriteState; var sampleRate: Int64?; var channels: Int?; var totalFrames: Int64? }
struct LibraryTag: Decodable, Identifiable, Sendable { var id: UUID; var namespace: String; var name: String; var archived: Bool }
struct TagPage: Decodable, Sendable { var items: [LibraryTag]; var hasMore: Bool; var nextCursor: String? }
struct TagState: Decodable, Sendable { var tagIds: [UUID]; var tagVersion: Int64 }
struct APIError: LocalizedError { let status: Int; let message: String; var errorDescription: String? { message } }

struct ConnectionSettings: Sendable {
    var baseURL = UserDefaults.standard.string(forKey: "serverURL") ?? "https://nas.local"
    var libraryID = UserDefaults.standard.string(forKey: "libraryID") ?? ""
    var token = ""
    static let keychainService = "jp.samplebrowser.api"
    func save() async throws {
        try Self.validate(baseURL: baseURL, libraryID: libraryID)
        if !token.isEmpty { try await Keychain.store(token, account: baseURL + "/" + libraryID) }
        UserDefaults.standard.set(baseURL, forKey: "serverURL")
        UserDefaults.standard.set(libraryID, forKey: "libraryID")
    }
    static func validate(baseURL: String, libraryID: String) throws {
        guard let url = URL(string: baseURL), let host = url.host, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)), UUID(uuidString: libraryID) != nil else { throw APIError(status: 0, message: "HTTPS のサーバー URL とライブラリ UUID を指定してください。開発時の HTTP は localhost のみ利用できます。") }
    }
    func client() async throws -> APIClient {
        try Self.validate(baseURL: baseURL, libraryID: libraryID)
        let value = token.isEmpty ? try await Keychain.read(account: baseURL + "/" + libraryID) : token
        try Task.checkCancellation()
        guard !value.isEmpty else { throw APIError(status: 401, message: "接続設定にアクセストークンを入力してください。") }
        return APIClient(baseURL: URL(string: baseURL)!, libraryID: libraryID, token: value)
    }
    /// Reads developer connection files without touching preferences or Keychain.
    static func fromFile(_ url: URL) throws -> ConnectionSettings {
        func read(_ url: URL, limit: Int) throws -> Data {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: limit) ?? Data()
            guard data.count < limit else { throw APIError(status: 0, message: "接続ファイルまたはトークンファイルが長すぎます。") }
            return data
        }
        let data = try read(url, limit: 65536)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let baseURL = object["base_url"], let libraryID = object["library_id"], let tokenPath = object["token_file"], !tokenPath.isEmpty else {
            throw APIError(status: 0, message: "接続ファイルの形式が正しくありません。")
        }
        try validate(baseURL: baseURL, libraryID: libraryID)
        let tokenURL = tokenPath.hasPrefix("/") ? URL(fileURLWithPath: tokenPath) : url.deletingLastPathComponent().appendingPathComponent(tokenPath)
        let token = String(decoding: try read(tokenURL, limit: 16384), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw APIError(status: 401, message: "トークンファイルが空です。") }
        return ConnectionSettings(baseURL: baseURL, libraryID: libraryID, token: token)
    }
}

enum Keychain {
    // Security.framework may wait for authorization. Keep its blocking calls off
    // the UI actor, without changing authorization or accessibility policy.
    static func store(_ token: String, account: String) async throws {
        try await Task.detached(priority: .userInitiated) { try storeBlocking(token, account: account) }.value
    }
    static func read(account: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) { try readBlocking(account: account) }.value
    }
    private static func storeBlocking(_ token: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: ConnectionSettings.keychainService, kSecAttrAccount as String: account]
        let attrs: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw APIError(status: 0, message: "Keychain への保存に失敗しました (\(status))。") }
    }
    private static func readBlocking(account: String) throws -> String {
        let query: [String:Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: ConnectionSettings.keychainService, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else { throw APIError(status: 0, message: "Keychain から認証情報を読み出せません。") }
        return String(decoding: data, as: UTF8.self)
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct APIClient: Sendable {
    private static let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)
    let baseURL: URL; let libraryID: String; private let token: String
    init(baseURL: URL, libraryID: String, token: String) { self.baseURL = baseURL; self.libraryID = libraryID; self.token = token }
    private func request(path: String, method: String = "GET", body: [String:Any]? = nil, version: Int64? = nil) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("v1/libraries/\(libraryID)/\(path)")
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let version { request.setValue("\"v\(version)\"", forHTTPHeaderField: "If-Match") }
        if method != "GET" && path != "search" { request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key") }
        return request
    }
    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError(status: 0, message: "NAS から有効な応答がありません。") }
        var data = Data(); data.reserveCapacity(64 * 1024)
        for try await byte in bytes { guard data.count < 4 * 1024 * 1024 else { throw APIError(status: 413, message: "NAS の応答が 4 MB を超えました。") }; data.append(byte) }
        guard (200..<300).contains(response.statusCode) else {
            let envelope = try? JSONSerialization.jsonObject(with: data) as? [String:Any]
            let message = (envelope?["error"] as? [String:Any])?["message"] as? String
            throw APIError(status: response.statusCode, message: response.statusCode == 412 ? "別の端末で更新されています。最新情報を再取得しました。内容を確認して、もう一度保存してください。" : (message ?? "NAS との通信に失敗しました (HTTP \(response.statusCode))。"))
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
    static func parseBPMBound(_ text: String) throws -> Double? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let number = Double(value), number.isFinite, number > 0 else { throw APIError(status: 400, message: "BPM の下限・上限は正の有限な数値で入力してください。") }
        return number
    }
    static func searchBody(text: String, favorite: Bool, bpmMinimum: Double?, bpmMaximum: Double?, kind: String, sort: String, cursor: String?) throws -> [String:Any] {
        var filters: [[String:Any]] = []
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { filters.append(["field":"text", "op":"contains", "value": text]) }
        if favorite { filters.append(["field":"favorite", "op":"eq", "value":true]) }
        for bound in [bpmMinimum, bpmMaximum].compactMap({ $0 }) {
            guard bound.isFinite, bound > 0 else { throw APIError(status: 400, message: "BPM の下限・上限は正の有限な数値で指定してください。") }
        }
        switch (bpmMinimum, bpmMaximum) {
        case let (minimum?, maximum?):
            guard maximum >= minimum else { throw APIError(status: 400, message: "BPM の上限は下限以上で指定してください。") }
            filters.append(["field":"bpm", "op":"between", "value":[minimum,maximum]])
        case let (minimum?, nil): filters.append(["field":"bpm", "op":"gte", "value":minimum])
        case let (nil, maximum?): filters.append(["field":"bpm", "op":"lte", "value":maximum])
        case (nil, nil): break
        }
        if kind != "all" { filters.append(["field":"sample_kind", "op":"eq", "value": kind]) }
        return ["schema_version":1, "filter":["all":filters], "sort":["field":sort,"direction":"asc"], "page_size":100, "cursor":cursor as Any? ?? NSNull()]
    }
    func search(text: String, favorite: Bool, bpmMinimum: Double?, bpmMaximum: Double?, kind: String, sort: String, cursor: String?) async throws -> SearchPage {
        let body = try Self.searchBody(text: text, favorite: favorite, bpmMinimum: bpmMinimum, bpmMaximum: bpmMaximum, kind: kind, sort: sort, cursor: cursor)
        return try await perform(request(path: "search", method: "POST", body: body))
    }
    func detail(_ id: UUID) async throws -> SampleDetail { try await perform(request(path: "samples/\(id)")) }
    func favorite(_ id: UUID, value: Bool, version: Int64) async throws -> FavoriteState { try await perform(request(path: "samples/\(id)/favorite", method: "PUT", body: ["favorite":value], version: version)) }
    func tags() async throws -> TagPage { try await perform(request(path: "tags")) }
    func changeTags(_ id: UUID, add: [UUID], remove: [UUID], version: Int64) async throws -> TagState { try await perform(request(path: "samples/\(id)/tags", method: "PATCH", body: ["add":add.map(\.uuidString), "remove":remove.map(\.uuidString)], version: version)) }
    func annotate(_ id: UUID, value: Annotations) async throws -> Annotations { try await perform(request(path: "samples/\(id)/annotations", method: "PUT", body: value.body, version: value.recordVersion)) }
    func download(_ sample: Sample, directory: URL) async throws -> URL {
        var request = try request(path: "samples/\(sample.id)/audio")
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "source_revision", value: String(sample.sourceRevision))]
        request.url = components.url; request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw APIError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: "原音を取得できません。NAS 接続・原音の所在・原音版を確認してください。") }
        let limit: Int64 = 512 * 1024 * 1024
        guard response.expectedContentLength <= limit else { throw APIError(status: 413, message: "この初期版では選択素材の取得を 512 MB までに制限しています。ローカルで開いてください。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(sample.id)-v\(sample.sourceRevision)-\(UUID().uuidString).\(URL(fileURLWithPath: sample.name).pathExtension)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        var success = false
        defer { try? handle.close(); if !success { try? FileManager.default.removeItem(at: url) } }
        var block = Data(); block.reserveCapacity(65536); var total: Int64 = 0
        for try await byte in bytes {
            try Task.checkCancellation(); total += 1
            guard total <= limit else { throw APIError(status: 413, message: "選択素材の 512 MB 制限を超えました。") }
            block.append(byte)
            if block.count >= 65536 { try handle.write(contentsOf: block); block.removeAll(keepingCapacity: true) }
        }
        if !block.isEmpty { try handle.write(contentsOf: block) }
        guard response.expectedContentLength < 0 || total == response.expectedContentLength else { throw APIError(status: 0, message: "原音の取得が途中で終了しました。") }
        success = true; return url
    }
}
