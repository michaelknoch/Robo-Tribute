import XCTest
@testable import RoboTribute

/// Needs a local sshd and a passphrase-protected key: ROBO3T_SSH_PORT, ROBO3T_SSH_KEY, ROBO3T_SSH_PASSPHRASE,
/// plus the plain test mongod on ROBO3T_TEST_PORT (default 27999). ssh runs with its own config and known_hosts
/// so the user's agent, keychain and known_hosts are never touched.
final class SSHTunnelTests: XCTestCase {
    private func env(_ key: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key] else { throw XCTSkip("\(key) not set") }
        return value
    }

    private func tunnel(passphrase: String) throws -> SSHTunnel {
        var settings = SSHSettings()
        settings.enabled = true
        settings.host = "127.0.0.1"
        settings.port = Int(try env("ROBO3T_SSH_PORT")) ?? 22
        settings.userName = NSUserName()
        settings.method = "publickey"
        settings.privateKeyFile = try env("ROBO3T_SSH_KEY")
        var secrets = ConnectionSecrets()
        secrets.sshPassphrase = passphrase
        let mongoPort = Int(ProcessInfo.processInfo.environment["ROBO3T_TEST_PORT"] ?? "27999") ?? 27999
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("robo-tribute-ssh-test", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = directory.appendingPathComponent("config")
        try "UserKnownHostsFile \(directory.appendingPathComponent("known_hosts").path)\nAddKeysToAgent no\n".write(to: config, atomically: true, encoding: .utf8)
        return SSHTunnel(settings: settings, secrets: secrets, remoteHost: "127.0.0.1", remotePort: mongoPort,
                         timeoutSeconds: 5, configFile: config.path)
    }

    private func leftoverSecrets() -> [String] {
        let tmp = FileManager.default.temporaryDirectory
        return ((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [])
            .filter { $0.hasPrefix("robo-tribute-ssh-") }
            .filter { FileManager.default.fileExists(atPath: tmp.appendingPathComponent($0).appendingPathComponent("secret").path) }
    }

    func testTunnelConsumesPassphraseFile() throws {
        let tunnel = try tunnel(passphrase: try env("ROBO3T_SSH_PASSPHRASE"))
        try tunnel.start()
        XCTAssertTrue(leftoverSecrets().isEmpty, "the askpass helper must delete the passphrase file after use")

        var settings = ConnectionSettings()
        settings.serverHost = "127.0.0.1"
        settings.serverPort = tunnel.localPort
        let connection = try MongoConnection(settings: settings, secrets: ConnectionSecrets(), timeoutSeconds: 5)
        XCTAssertFalse(try connection.listDatabases().isEmpty)
        connection.close()
        tunnel.stop()
    }

    func testWrongPassphraseFails() throws {
        let tunnel = try tunnel(passphrase: "wrong")
        XCTAssertThrowsError(try tunnel.start()) { XCTAssertTrue($0 is SSHTunnelError) }
        XCTAssertTrue(leftoverSecrets().isEmpty)
    }
}
