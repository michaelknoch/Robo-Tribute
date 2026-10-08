import Foundation

nonisolated enum ViewMode: Int, Codable {
    case text = 0, tree = 1, table = 2, custom = 3
}

nonisolated struct CredentialSettings: Codable, Equatable {
    var enabled = false
    var userName = ""
    var databaseName = "admin"
    var mechanism = "SCRAM-SHA-256"
    var useManuallyVisibleDbs = false
    var manuallyVisibleDbs = ""
}

nonisolated struct SSHSettings: Codable, Equatable {
    var enabled = false
    var host = ""
    var port = 22
    var userName = ""
    var method = "publickey"
    var privateKeyFile = ""
    var askPassword = false

    var usesPublicKey: Bool { method == "publickey" }
}

nonisolated struct SSLSettings: Codable, Equatable {
    var sslEnabled = false
    var allowInvalidCertificates = false
    var caFile = ""
    var usePemFile = false
    var pemKeyFile = ""
    var askPassphrase = false
    var useAdvancedOptions = false
    var crlFile = ""
    var allowInvalidHostnames = false
}

/// Secrets are never written to settings.json; they live in the macOS Keychain.
nonisolated struct ConnectionSecrets: Codable, Equatable {
    var password = ""
    var sshPassword = ""
    var sshPassphrase = ""
    var pemPassphrase = ""

    var isEmpty: Bool { password.isEmpty && sshPassword.isEmpty && sshPassphrase.isEmpty && pemPassphrase.isEmpty }
}

nonisolated enum ConnectionType: Int, Codable {
    case direct = 0, replicaSet = 1, srv = 2
}

nonisolated struct ConnectionSettings: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var connectionName = "New Connection"
    var connectionType: ConnectionType = .direct
    var serverHost = "localhost"
    var serverPort = 27017
    var replicaSetMembers: [String] = []
    var replicaSetName = ""
    var defaultDatabase = ""
    var credential = CredentialSettings()
    var ssh = SSHSettings()
    var ssl = SSLSettings()
    var imported = false
    /// Optional so settings saved before it existed still decode.
    var readOnly: Bool?

    var isReplicaSet: Bool { connectionType == .replicaSet }
    var isReadOnly: Bool { readOnly ?? false }

    var fullAddress: String {
        switch connectionType {
        case .direct: return "\(serverHost):\(serverPort)"
        case .srv: return serverHost
        case .replicaSet: return replicaSetMembers.first ?? "\(serverHost):\(serverPort)"
        }
    }

    var readableName: String { connectionName.isEmpty ? fullAddress : connectionName }

    var hasEnabledCredential: Bool { credential.enabled && !credential.userName.isEmpty }
    var usesSSHTunnel: Bool { ssh.enabled && connectionType == .direct }

    var usesTLS: Bool { ssl.sslEnabled || connectionType == .srv }
    var verifiesCertificates: Bool { !ssl.allowInvalidCertificates && !(ssl.useAdvancedOptions && ssl.allowInvalidHostnames) }
    /// Without verified TLS the driver must never discover its way off this machine.
    var requiresLocalMembers: Bool { isReplicaSet && !(usesTLS && verifiesCertificates) }

    /// Why this connection may not be opened: anything beyond this machine needs verified TLS or an SSH tunnel.
    var transportSecurityError: String? {
        if usesSSHTunnel { return nil }
        let hosts: [String]
        switch connectionType {
        case .direct, .srv: hosts = [serverHost]
        case .replicaSet: hosts = seedMembers.map(Self.host(ofMember:))
        }
        if hosts.allSatisfy(Self.isLoopback) { return nil }
        if !usesTLS { return "TLS is required for remote servers. Enable TLS or connect through an SSH tunnel." }
        if ssl.sslEnabled && !verifiesCertificates {
            return "Remote servers need a verified TLS certificate. Use a CA-signed certificate and disallow invalid hostnames."
        }
        return nil
    }

    var seedMembers: [String] { replicaSetMembers.isEmpty ? ["\(serverHost):\(serverPort)"] : replicaSetMembers }

    static func splitHostPort(_ member: String) -> (host: String, port: Int)? {
        guard let colon = member.lastIndex(of: ":"), let port = Int(member[member.index(after: colon)...]) else { return nil }
        return (String(member[..<colon]), port)
    }

    static func host(ofMember member: String) -> String {
        if member.hasPrefix("["), let end = member.firstIndex(of: "]") { return String(member[member.index(after: member.startIndex)..<end]) }
        if let colon = member.lastIndex(of: ":"), member.firstIndex(of: ":") == colon { return String(member[..<colon]) }
        return member
    }

    static func isLoopback(_ host: String) -> Bool {
        var name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name.hasSuffix(".") { name.removeLast() }
        if name == "localhost" { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, name, &v4) == 1 { return UInt32(bigEndian: v4.s_addr) >> 24 == 127 }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, name, &v6) == 1 { return withUnsafeBytes(of: v6) { Array($0) } == withUnsafeBytes(of: in6addr_loopback) { Array($0) } }
        return false
    }
}

nonisolated struct AppSettings: Codable {
    @MainActor static var shared = AppSettings.load()

    var connections: [ConnectionSettings] = []
    var batchSize = 50
    var viewMode: ViewMode = .tree
    var timeZone: TimeZoneMode = .utc
    var uuidEncoding: UUIDEncoding = .standard
    var autoExpand = true
    var autoExec = true
    var lineNumbers = false
    var shellTimeoutSec = 15
    var mongoTimeoutSec = 10
    var importedConnectionsCount = 0
    var importChecked = false

    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["ROBO_TRIBUTE_SETTINGS_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Robo Tribute", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("settings.json") }

    private enum CodingKeys: String, CodingKey {
        case connections, batchSize, viewMode, timeZone, uuidEncoding, autoExpand, autoExec, lineNumbers
        case shellTimeoutSec, mongoTimeoutSec, importChecked
    }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connections = (try? c.decodeIfPresent([ConnectionSettings].self, forKey: .connections)) ?? connections
        batchSize = (try? c.decodeIfPresent(Int.self, forKey: .batchSize)) ?? batchSize
        viewMode = (try? c.decodeIfPresent(ViewMode.self, forKey: .viewMode)) ?? viewMode
        timeZone = (try? c.decodeIfPresent(TimeZoneMode.self, forKey: .timeZone)) ?? timeZone
        uuidEncoding = (try? c.decodeIfPresent(UUIDEncoding.self, forKey: .uuidEncoding)) ?? uuidEncoding
        autoExpand = (try? c.decodeIfPresent(Bool.self, forKey: .autoExpand)) ?? autoExpand
        autoExec = (try? c.decodeIfPresent(Bool.self, forKey: .autoExec)) ?? autoExec
        lineNumbers = (try? c.decodeIfPresent(Bool.self, forKey: .lineNumbers)) ?? lineNumbers
        shellTimeoutSec = (try? c.decodeIfPresent(Int.self, forKey: .shellTimeoutSec)) ?? shellTimeoutSec
        mongoTimeoutSec = (try? c.decodeIfPresent(Int.self, forKey: .mongoTimeoutSec)) ?? mongoTimeoutSec
        importChecked = (try? c.decodeIfPresent(Bool.self, forKey: .importChecked)) ?? importChecked
    }

    private static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL), let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    /// First launch only: takes over connections and preferences from an installed Robo 3T.
    mutating func importFromRoboIfNeeded() {
        guard !importChecked else { return }
        importChecked = true
        let imported = RoboImporter.importConnections()
        connections += imported
        importedConnectionsCount = imported.count
        RoboImporter.applyPreferences(to: &self)
        save()
    }

    func save() {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
            // Host names and user names are nobody else's business on a shared Mac.
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
        } catch {
            Log.error("Failed to save settings: \(error.localizedDescription)")
        }
    }
}
