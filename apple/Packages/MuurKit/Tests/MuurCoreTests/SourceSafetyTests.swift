import XCTest
@testable import MuurCore

final class SourceSafetyTests: XCTestCase {
    func testFTPHonorsTheSavedEncryptionModeAndRejectsInvalidPorts() throws {
        var config = SourceConfig(kind: .ftp, name: "FTP", host: "music.example",
                                  options: [SourceConfig.OptionKey.ftpTLSMode: "implicit"])
        XCTAssertEqual(try FTPSource.tlsMode(for: config), .implicit)
        config.options[SourceConfig.OptionKey.ftpTLSMode] = "explicit"
        XCTAssertEqual(try FTPSource.tlsMode(for: config), .explicit)
        config.options[SourceConfig.OptionKey.ftpTLSMode] = "off"
        XCTAssertEqual(try FTPSource.tlsMode(for: config), .none)
        config.port = 65_536
        XCTAssertThrowsError(try FTPSource(config: config, secrets: SourceSecrets()))
    }

    func testMediaServerRecognizesSavedTLSAndRejectsPlaintextConflict() throws {
        var config = SourceConfig(kind: .jellyfin, name: "Music", host: "music.example",
                                  options: [SourceConfig.OptionKey.useTLS: "1"])
        XCTAssertEqual(try MediaServerIdentity.baseURL(config).scheme, "https")
        config.host = "http://music.example"
        XCTAssertThrowsError(try MediaServerIdentity.baseURL(config))
    }

    func testSFTPRequiresAValidHostFingerprintBeforeConnecting() throws {
        var config = SourceConfig(kind: .sftp, name: "SFTP", host: "music.example", username: "listener")
        XCTAssertThrowsError(try SFTPSource(config: config, secrets: SourceSecrets()))
        let digest = Data(repeating: 1, count: 32).base64EncodedString().dropLast()
        config.options[SourceConfig.OptionKey.sftpHostFingerprint] = "SHA256:" + digest
        XCTAssertNoThrow(try SFTPSource(config: config, secrets: SourceSecrets()))
    }

    func testFailedConnectionProbeKeepsSavedCredentials() async throws {
        let database = try MuurDatabase.inMemory()
        let credentials = CredentialStore.inMemory()
        let paths = AppPaths()
        let cache = AudioCache(directory: paths.audioCacheDirectory) { 1_024 }
        let manager = SourceManager(repository: LibraryRepository(database: database), credentials: credentials,
                                    paths: paths, cache: cache)
        let config = SourceConfig(kind: .sftp, name: "Missing Host")
        let saved = SourceSecrets(password: "saved")
        try credentials.save(saved, for: config.id)
        do {
            _ = try await manager.test(config, secrets: SourceSecrets(password: "candidate"))
            XCTFail("The source has no host.")
        } catch {
            XCTAssertEqual(credentials.secrets(for: config.id), saved)
        }
    }

    func testLargeCachedFileSurvivesUntilTheLastPlaybackLeaseIsReleased() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AudioCache(directory: root) { 4 }
        let uri = "sftp://music.example/song.flac"
        await cache.retain(uri)
        await cache.retain(uri)
        let file = try await cache.file(for: uri, fileExtension: "flac") { destination in
            try Data(repeating: 0, count: 8).write(to: destination)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        await cache.release(uri)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        await cache.release(uri)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
