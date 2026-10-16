import Foundation
import ReachyJSON
import ReachyKeychain

/// Pinned host keys in the Keychain, one item per robot.
public struct KeychainHostKeyStore: HostKeyStore {
    private let items: KeychainItems

    public init(service: String = "com.alexey1312.ReachyMini.ssh.hostkey") {
        self.init(items: KeychainItems(service: service, failure: ReachySSHError.keychain))
    }

    /// The seam for tests, which hand in a `KeychainItems` with no Keychain behind it.
    package init(items: KeychainItems) {
        self.items = items
    }

    public func pinnedKey(forRobot robot: String) throws -> String? {
        guard let data = try items.read(account: robot) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func pin(_ openSSHPublicKey: String, forRobot robot: String) throws {
        try items.write(Data(openSSHPublicKey.utf8), account: robot)
    }

    public func forget(robot: String) throws {
        try items.delete(account: robot)
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

    private let items: KeychainItems

    public init(service: String = "com.alexey1312.ReachyMini.ssh.login") {
        self.init(items: KeychainItems(service: service, failure: ReachySSHError.keychain))
    }

    /// The seam for tests, which hand in a `KeychainItems` with no Keychain behind it.
    package init(items: KeychainItems) {
        self.items = items
    }

    public func credentials(forRobot robot: String) throws -> SSHCredentials? {
        guard let data = try items.read(account: robot),
              let stored = try? JSONCodec.stored.decode(Stored.self, from: data)
        else { return nil }
        // Host and port are filled in by the caller, which is the only thing that
        // knows where this robot is right now.
        return SSHCredentials(host: "", username: stored.username, password: stored.password)
    }

    public func save(_ credentials: SSHCredentials, forRobot robot: String) throws {
        let stored = Stored(username: credentials.username, password: credentials.password)
        try items.write(JSONCodec.stored.encode(stored), account: robot)
    }

    public func clear(robot: String) throws {
        try items.delete(account: robot)
    }
}
