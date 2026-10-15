import XCTest
@testable import SampleBrowser

final class ConnectionSettingsTests: XCTestCase {
    func testSessionFileUsesRelativeTokenWithoutChangingSavedConnection() async throws {
        let savedURL = UserDefaults.standard.string(forKey: "serverURL")
        let savedLibrary = UserDefaults.standard.string(forKey: "libraryID")
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try connectionFile(in: folder, tokenPath: "token")
        try Data("  test-only-token\n".utf8).write(to: folder.appendingPathComponent("token"))

        let settings = try ConnectionSettings.fromFile(file)
        let client = try await settings.client()
        XCTAssertEqual(client.baseURL.absoluteString, "http://127.0.0.1:8080")
        XCTAssertEqual(client.libraryID, "b6edfa0f-ec38-4138-99a4-e26fd53d507d")
        XCTAssertEqual(settings.token, "test-only-token")
        XCTAssertEqual(UserDefaults.standard.string(forKey: "serverURL"), savedURL)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "libraryID"), savedLibrary)
    }

    func testAbsoluteTokenPathIsSupported() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let token = folder.appendingPathComponent("token")
        try Data("test-only-token".utf8).write(to: token)
        let file = try connectionFile(in: folder, tokenPath: token.path)
        XCTAssertEqual(try ConnectionSettings.fromFile(file).token, "test-only-token")
    }

    func testEmptyOrOversizedSessionTokenIsRejectedBeforeKeychainFallback() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try connectionFile(in: folder, tokenPath: "token")
        let token = folder.appendingPathComponent("token")
        for data in [Data(" \n".utf8), Data(repeating: 65, count: 16384)] {
            try data.write(to: token)
            XCTAssertThrowsError(try ConnectionSettings.fromFile(file))
        }
    }

    func testUnsafeServerAndMalformedConnectionAreRejected() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try connectionFile(in: folder, tokenPath: "token", baseURL: "http://nas.example.com")
        XCTAssertThrowsError(try ConnectionSettings.fromFile(file))
        try Data("{}".utf8).write(to: file)
        XCTAssertThrowsError(try ConnectionSettings.fromFile(file))
        try Data(repeating: 32, count: 65536).write(to: file)
        XCTAssertThrowsError(try ConnectionSettings.fromFile(file))
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func connectionFile(in folder: URL, tokenPath: String, baseURL: String = "http://127.0.0.1:8080") throws -> URL {
        let file = folder.appendingPathComponent("connection.json")
        let data = try JSONSerialization.data(withJSONObject: ["base_url": baseURL, "library_id": "b6edfa0f-ec38-4138-99a4-e26fd53d507d", "token_file": tokenPath])
        try data.write(to: file)
        return file
    }
}
