import Foundation

/// Imports connection metadata from an existing Robo 3T installation (~/.3T/robo-3t/<version>/robo3t.json).
/// Secrets (passwords, passphrases) are deliberately not imported; they are re-entered once and stored in the Keychain.
nonisolated enum RoboImporter {
    private static var roboDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".3T/robo-3t", isDirectory: true)
    }

    private static func latestConfig() -> [String: Any]? {
        let fm = FileManager.default
        guard let versions = try? fm.contentsOfDirectory(atPath: roboDirectory.path) else { return nil }
        let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for version in sorted {
            let url = roboDirectory.appendingPathComponent(version).appendingPathComponent("robo3t.json")
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let connections = json["connections"] as? [Any], !connections.isEmpty else { continue }
            return json
        }
        return nil
    }

    static func applyPreferences(to settings: inout AppSettings) {
        guard let json = latestConfig() else { return }
        settings.batchSize = json["batchSize"] as? Int ?? settings.batchSize
        settings.viewMode = (json["viewMode"] as? Int).flatMap(ViewMode.init(rawValue:)) ?? settings.viewMode
        settings.timeZone = (json["timeZone"] as? Int).flatMap(TimeZoneMode.init(rawValue:)) ?? settings.timeZone
        settings.uuidEncoding = (json["uuidEncoding"] as? Int).flatMap(UUIDEncoding.init(rawValue:)) ?? settings.uuidEncoding
        settings.autoExpand = json["autoExpand"] as? Bool ?? settings.autoExpand
        settings.autoExec = json["autoExec"] as? Bool ?? settings.autoExec
        settings.lineNumbers = json["lineNumbers"] as? Bool ?? settings.lineNumbers
        settings.shellTimeoutSec = json["shellTimeoutSec"] as? Int ?? settings.shellTimeoutSec
        settings.mongoTimeoutSec = json["mongoTimeoutSec"] as? Int ?? settings.mongoTimeoutSec
    }

    static func importConnections() -> [ConnectionSettings] {
        guard let json = latestConfig(), let list = json["connections"] as? [[String: Any]] else { return [] }
        var result: [ConnectionSettings] = []
        for item in list {
            var conn = ConnectionSettings()
            conn.id = UUID().uuidString
            conn.imported = true
            conn.connectionName = item["connectionName"] as? String ?? ""
            conn.serverHost = item["serverHost"] as? String ?? "localhost"
            conn.serverPort = item["serverPort"] as? Int ?? 27017
            conn.defaultDatabase = item["defaultDatabase"] as? String ?? ""

            if item["isReplicaSet"] as? Bool == true {
                conn.connectionType = .replicaSet
                let replica = item["replicaSet"] as? [String: Any] ?? [:]
                conn.replicaSetMembers = replica["members"] as? [String] ?? []
                conn.replicaSetName = replica["setNameUserEntered"] as? String ?? replica["setName"] as? String ?? ""
            }

            if let credential = (item["credentials"] as? [[String: Any]])?.first {
                conn.credential.enabled = credential["enabled"] as? Bool ?? false
                conn.credential.userName = credential["userName"] as? String ?? ""
                conn.credential.databaseName = credential["databaseName"] as? String ?? "admin"
                conn.credential.useManuallyVisibleDbs = credential["useManuallyVisibleDbs"] as? Bool ?? false
                conn.credential.manuallyVisibleDbs = credential["manuallyVisibleDbs"] as? String ?? ""
            }

            if let ssh = item["ssh"] as? [String: Any] {
                conn.ssh.enabled = ssh["enabled"] as? Bool ?? false
                conn.ssh.host = ssh["host"] as? String ?? ""
                conn.ssh.port = ssh["port"] as? Int ?? 22
                conn.ssh.userName = ssh["userName"] as? String ?? ""
                conn.ssh.method = ssh["method"] as? String ?? "publickey"
                conn.ssh.privateKeyFile = ssh["privateKeyFile"] as? String ?? ""
                conn.ssh.askPassword = ssh["askPassword"] as? Bool ?? false
            }

            if let ssl = item["ssl"] as? [String: Any] {
                conn.ssl.sslEnabled = ssl["sslEnabled"] as? Bool ?? false
                conn.ssl.allowInvalidCertificates = ssl["allowInvalidCertificates"] as? Bool ?? false
                conn.ssl.allowInvalidHostnames = ssl["allowInvalidHostnames"] as? Bool ?? false
                conn.ssl.caFile = ssl["caFile"] as? String ?? ""
                conn.ssl.crlFile = ssl["crlFile"] as? String ?? ""
                conn.ssl.pemKeyFile = ssl["pemKeyFile"] as? String ?? ""
                conn.ssl.usePemFile = ssl["usePemFile"] as? Bool ?? false
                conn.ssl.askPassphrase = ssl["askPassphrase"] as? Bool ?? false
                conn.ssl.useAdvancedOptions = ssl["useAdvancedOptions"] as? Bool ?? false
            }

            result.append(conn)
        }
        if !result.isEmpty {
            Log.info("Imported \(result.count) connection(s) from Robo 3T")
        }
        return result
    }
}
