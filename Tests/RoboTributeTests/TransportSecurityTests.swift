import XCTest
@testable import RoboTribute

final class TransportSecurityTests: XCTestCase {
    private func direct(_ host: String) -> ConnectionSettings {
        var settings = ConnectionSettings()
        settings.serverHost = host
        return settings
    }

    func testLoopbackNeedsNoTLS() {
        for host in ["localhost", "LOCALHOST.", "127.0.0.1", "127.8.9.10", "::1", "[::1]"] {
            XCTAssertNil(direct(host).transportSecurityError, host)
        }
    }

    func testRemoteNeedsTLS() {
        for host in ["db.example.com", "192.168.1.5", "10.0.0.1", "128.0.0.1", "::2", "localhost.example.com"] {
            XCTAssertNotNil(direct(host).transportSecurityError, host)
        }
    }

    func testRemoteWithVerifiedTLSIsAllowed() {
        var settings = direct("db.example.com")
        settings.ssl.sslEnabled = true
        XCTAssertNil(settings.transportSecurityError)
    }

    func testRemoteRejectsUnverifiedTLS() {
        var settings = direct("db.example.com")
        settings.ssl.sslEnabled = true
        settings.ssl.allowInvalidCertificates = true
        XCTAssertNotNil(settings.transportSecurityError)

        settings.ssl.allowInvalidCertificates = false
        settings.ssl.useAdvancedOptions = true
        settings.ssl.allowInvalidHostnames = true
        XCTAssertNotNil(settings.transportSecurityError)
    }

    func testLoopbackAllowsUnverifiedTLS() {
        var settings = direct("localhost")
        settings.ssl.sslEnabled = true
        settings.ssl.allowInvalidCertificates = true
        XCTAssertNil(settings.transportSecurityError)
    }

    func testSSHTunnelIsAllowed() {
        var settings = direct("db.internal")
        settings.ssh.enabled = true
        XCTAssertNil(settings.transportSecurityError)
    }

    func testSRVImpliesTLS() {
        var settings = direct("cluster0.example.mongodb.net")
        settings.connectionType = .srv
        XCTAssertTrue(settings.usesTLS)
        XCTAssertNil(settings.transportSecurityError)
    }

    func testReplicaSetChecksEveryMember() {
        var settings = direct("localhost")
        settings.connectionType = .replicaSet
        settings.replicaSetMembers = ["localhost:27017", "[::1]:27018"]
        XCTAssertNil(settings.transportSecurityError)

        settings.replicaSetMembers.append("db2.example.com:27017")
        XCTAssertNotNil(settings.transportSecurityError)
    }

    func testReplicaSetWithoutVerifiedTLSMustStayLocal() {
        var settings = direct("localhost")
        settings.connectionType = .replicaSet
        XCTAssertTrue(settings.requiresLocalMembers)
        settings.ssl.sslEnabled = true
        settings.ssl.allowInvalidCertificates = true
        XCTAssertTrue(settings.requiresLocalMembers)
        settings.ssl.allowInvalidCertificates = false
        XCTAssertFalse(settings.requiresLocalMembers)
        XCTAssertFalse(direct("localhost").requiresLocalMembers)
    }

    func testConnectRefusesBeforeTouchingTheNetwork() {
        XCTAssertThrowsError(try MongoConnection(settings: direct("db.example.com"), secrets: ConnectionSecrets(), timeoutSeconds: 1)) { XCTAssertTrue($0.localizedDescription.contains("TLS is required")) }
    }
}
