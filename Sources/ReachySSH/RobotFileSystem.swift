import Foundation

/// Where a robot's files are reached, and the seam a screen is written against.
///
/// A protocol rather than the concrete actor so that a preview and a test can hand
/// a screen a settled directory without a robot, an SSH server or a network — the
/// same reason `RobotAPIClient` exists one package over.
public protocol RobotFileSystem: Sendable {
    /// Opens a session, or throws ``ReachySSHError/hostKeyUnknown(_:)`` when this
    /// robot's key has never been confirmed. Idempotent: calling it on a live
    /// session is a no-op rather than a second connection.
    func connect(_ credentials: SSHCredentials) async throws
    func disconnect() async

    func list(_ path: String) async throws -> [RemoteFile]
    /// Reads a whole file, refusing anything over `limit` rather than growing to
    /// fit it.
    func read(_ path: String, limit: Int) async throws -> Data
    /// Reads a file the server reports no size for — which is every entry under
    /// `/proc` and `/sys`.
    ///
    /// Separate from ``read(_:limit:)`` because Citadel drives `readAll()` from the
    /// size in the file's attributes, and procfs answers `0`: the loop never runs
    /// and the caller is handed an empty buffer instead of the file. This one reads
    /// forward until a short answer, which is the only end-of-file SFTP gives.
    func readPseudoFile(_ path: String) async throws -> String
    /// Creates or truncates. This is also how an edit lands: the file goes to the
    /// device, an editor there changes it, and it comes back over the same path.
    func write(_ data: Data, to path: String) async throws
    func makeDirectory(at path: String) async throws
    /// Picks `remove` or `rmdir` from the entry's kind, which is why this takes a
    /// ``RemoteFile`` and not a path.
    func remove(_ file: RemoteFile) async throws
    func rename(_ path: String, to newPath: String) async throws
}

/// The robot's SSH login. Not `Codable` on purpose — the password belongs in the
/// Keychain as a value, never in anything with a `write(to:)`.
public struct SSHCredentials: Hashable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String

    /// Reachy Mini Wireless ships with OpenSSH enabled and this account. Offered
    /// as a prefill and never assumed: a robot whose password has been changed —
    /// which the UI should encourage — must still be reachable.
    public static let defaultUsername = "pollen"
    public static let defaultPort = 22

    public init(host: String, port: Int = SSHCredentials.defaultPort, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }
}

/// Pinned host keys, one per robot.
///
/// Keyed by the robot's hardware id rather than by its address (project rule 4): a
/// robot moves between networks and addresses, and its host key does not.
public protocol HostKeyStore: Sendable {
    func pinnedKey(forRobot robot: String) throws -> String?
    func pin(_ openSSHPublicKey: String, forRobot robot: String) throws
    func forget(robot: String) throws
}

/// Saved passwords, one per robot, under the same key as the pinned host key.
public protocol SSHCredentialStore: Sendable {
    func credentials(forRobot robot: String) throws -> SSHCredentials?
    func save(_ credentials: SSHCredentials, forRobot robot: String) throws
    func clear(robot: String) throws
}
