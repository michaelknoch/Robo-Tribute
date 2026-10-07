import Foundation
import Security

nonisolated enum Keychain {
    private static let service = "Robo Tribute"

    static func secrets(for connectionId: String) -> ConnectionSecrets {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let secrets = try? JSONDecoder().decode(ConnectionSecrets.self, from: data) else {
            if status != errSecItemNotFound && status != errSecSuccess {
                Log.warning("Keychain read failed for connection \(connectionId): \(status)")
            }
            return ConnectionSecrets()
        }
        return secrets
    }

    static func store(_ secrets: ConnectionSecrets, for connectionId: String) {
        if secrets.isEmpty {
            delete(connectionId)
            return
        }
        guard let data = try? JSONEncoder().encode(secrets) else { return }
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionId,
        ]
        let status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Robo Tribute connection"
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess { Log.error("Keychain write failed: \(addStatus)") }
        } else if status != errSecSuccess {
            Log.error("Keychain update failed: \(status)")
        }
    }

    static func delete(_ connectionId: String) {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionId,
        ]
        SecItemDelete(match as CFDictionary)
    }
}
