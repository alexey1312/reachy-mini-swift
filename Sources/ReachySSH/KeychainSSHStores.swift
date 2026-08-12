import Foundation
import ReachyJSON
import Security

/// The Keychain shape both stores share.
///
/// Written against `Security` directly, like `KeychainHFTokenStore`: the surface is
/// three calls, and a dependency that holds a credential is one more thing to
/// audit. Items are `ThisDeviceOnly` for the same reason a Hugging Face token is —
/// a robot password restored onto another device is one the user never knowingly
/// put there.
private enum KeychainItem {
    static func load(service: String, account: String) throws -> Data? {
        var query = base(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw ReachySSHError.keychain(status)
        }
    }

    static func save(_ data: Data, service: String, account: String) throws {
        let query = base(service: service, account: account)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess {
            return
        }
        guard update == errSecItemNotFound else { throw ReachySSHError.keychain(update) }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw ReachySSHError.keychain(status) }
    }

    static func delete(service: String, account: String) throws {
        let status = SecItemDelete(base(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ReachySSHError.keychain(status)
        }
    }

    private static func base(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Pinned host keys in the Keychain, one item per robot.
public struct KeychainHostKeyStore: HostKeyStore {
    private let service: String

    public init(service: String = "com.alexey1312.ReachyMini.ssh.hostkey") {
        self.service = service
    }

    public func pinnedKey(forRobot robot: String) throws -> String? {
        guard let data = try KeychainItem.load(service: service, account: robot) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func pin(_ openSSHPublicKey: String, forRobot robot: String) throws {
        try KeychainItem.save(Data(openSSHPublicKey.utf8), service: service, account: robot)
    }

    public func forget(robot: String) throws {
        try KeychainItem.delete(service: service, account: robot)
    }
}

/// Saved SSH passwords in the Keychain, one item per robot.
///
/// Host and port are *not* stored: the session already knows where the robot is,
/// and a remembered address is exactly the mistake project rule 4 warns about.
/// Only the username and the password are kept.
public struct KeychainSSHCredentialStore: SSHCredentialStore {
    private struct Stored: Codable {
        var username: String
        var password: String
    }

    private let service: String

    public init(service: String = "com.alexey1312.ReachyMini.ssh.login") {
        self.service = service
    }

    public func credentials(forRobot robot: String) throws -> SSHCredentials? {
        guard let data = try KeychainItem.load(service: service, account: robot),
              let stored = try? JSONCodec.stored.decode(Stored.self, from: data)
        else { return nil }
        // Host and port are filled in by the caller, which is the only thing that
        // knows where this robot is right now.
        return SSHCredentials(host: "", username: stored.username, password: stored.password)
    }

    public func save(_ credentials: SSHCredentials, forRobot robot: String) throws {
        let stored = Stored(username: credentials.username, password: credentials.password)
        try KeychainItem.save(JSONCodec.stored.encode(stored), service: service, account: robot)
    }

    public func clear(robot: String) throws {
        try KeychainItem.delete(service: service, account: robot)
    }
}
