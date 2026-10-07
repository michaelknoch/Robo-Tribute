import XCTest
@testable import RoboTribute

/// Needs a mongod with --tlsMode requireTLS and --auth; configure with ROBO3T_TLS_PORT, ROBO3T_TLS_CA,
/// ROBO3T_TLS_CLIENT_PEM, ROBO3T_TLS_USER and ROBO3T_TLS_PASSWORD.
final class TLSTests: XCTestCase {
    private func env(_ key: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key] else { throw XCTSkip("\(key) not set") }
        return value
    }

    private func settings() throws -> (ConnectionSettings, ConnectionSecrets) {
        var settings = ConnectionSettings()
        settings.serverHost = "localhost"
        settings.serverPort = Int(try env("ROBO3T_TLS_PORT")) ?? 0
        settings.ssl.sslEnabled = true
        settings.ssl.caFile = try env("ROBO3T_TLS_CA")
        settings.credential.enabled = true
        settings.credential.userName = try env("ROBO3T_TLS_USER")
        settings.credential.databaseName = "admin"
        var secrets = ConnectionSecrets()
        secrets.password = try env("ROBO3T_TLS_PASSWORD")
        return (settings, secrets)
    }

    func testCAFileAndScram() throws {
        let (settings, secrets) = try settings()
        let connection = try MongoConnection(settings: settings, secrets: secrets, timeoutSeconds: 10)
        XCTAssertTrue(try connection.listDatabases().contains("admin"))
        connection.close()
    }

    func testScramSha256Mechanism() throws {
        var (settings, secrets) = try settings()
        settings.credential.mechanism = "SCRAM-SHA-256"
        let connection = try MongoConnection(settings: settings, secrets: secrets, timeoutSeconds: 10)
        connection.close()
    }

    func testDefaultMechanismFallsBackForSha1OnlyUsers() throws {
        var (settings, secrets) = try settings()
        XCTAssertEqual(CredentialSettings().mechanism, "SCRAM-SHA-256")
        settings.credential.userName = "legacy"
        secrets.password = "legacy-pw"
        let connection = try MongoConnection(settings: settings, secrets: secrets, timeoutSeconds: 10)
        connection.close()
    }

    func testExplicitSha1() throws {
        var (settings, secrets) = try settings()
        settings.credential.mechanism = "SCRAM-SHA-1"
        let connection = try MongoConnection(settings: settings, secrets: secrets, timeoutSeconds: 10)
        connection.close()
    }

    func testClientCertificate() throws {
        var (settings, secrets) = try settings()
        settings.ssl.usePemFile = true
        settings.ssl.pemKeyFile = try env("ROBO3T_TLS_CLIENT_PEM")
        let connection = try MongoConnection(settings: settings, secrets: secrets, timeoutSeconds: 10)
        connection.close()
    }

    func testWrongPasswordFails() throws {
        var (settings, secrets) = try settings()
        secrets.password = "wrong"
        XCTAssertThrowsError(try MongoConnection(settings: settings, secrets: secrets, timeoutSeconds: 10))
    }

    func testMissingCAFails() throws {
        var (settings, secrets) = try settings()
        settings.ssl.caFile = ""
        XCTAssertThrowsError(try MongoConnection(settings: settings, secrets: secrets, timeoutSeconds: 10))
    }

    func testSelfSignedModeSkipsValidation() throws {
        var (settings, secrets) = try settings()
        settings.ssl.caFile = ""
        settings.ssl.allowInvalidCertificates = true
        let connection = try MongoConnection(settings: settings, secrets: secrets, timeoutSeconds: 10)
        connection.close()
    }
}
