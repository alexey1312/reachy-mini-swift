import Citadel
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Synchronization

/// Citadel marks the `SFTPClient` it hands out `Sendable` but not the `SSHClient`
/// that opened it, though both are driven through the same NIO `Channel`. Without
/// this, an `SSHClient` built inside an `async` function is task-isolated and cannot
/// be stored *at all*: an actor property fails with "sending 'client' risks causing
/// data races", `nonisolated(unsafe)` does not help because the diagnostic lands on
/// the local, and a `Mutex<SSHClient?>` fails with "'inout sending' parameter cannot
/// be task-isolated". Should Citadel ever declare the conformance itself, this line
/// becomes a duplicate-conformance build error — loud, and a one-line fix.
extension SSHClient: @retroactive @unchecked Sendable {}

/// SFTP to one robot.
///
/// An `actor` because a session is a single conversation: SFTP replies are matched
/// to requests by id inside Citadel, and serialising our own calls keeps "open the
/// subsystem once" honest without a second lock.
public actor SSHFileSystem: RobotFileSystem {
    /// The robot's stable identity, which keys both Keychain items. Never an
    /// address (project rule 4).
    private let robot: String
    private let hostKeys: any HostKeyStore
    private var client: SSHClient?
    /// Opened once per connection and reused. `openSFTP()` costs a child channel
    /// and a round trip, and logs a warning of its own about too many handles.
    private var sftp: SFTPClient?
    /// The handshake in flight, if any. See `connect(_:)`.
    private var connecting: Task<Void, any Error>?

    public init(robot: String, hostKeys: any HostKeyStore = KeychainHostKeyStore()) {
        self.robot = robot
        self.hostKeys = hostKeys
    }

    // MARK: - Session

    public func connect(_ credentials: SSHCredentials) async throws {
        if sftp != nil {
            return
        }
        // The actor is reentrant across the handshake's suspensions, so a second
        // connect arriving meanwhile must join the attempt in flight rather than
        // race it: the loser of that race was overwritten unclosed, and
        // `SSHClient` has no deinit — each race leaked a live TCP connection to
        // the robot and its NIO channel.
        if let connecting {
            return try await connecting.value
        }
        let attempt = Task { try await establish(credentials) }
        connecting = attempt
        // `disconnect()` may have cleared the slot — or a reconnect refilled it —
        // while this attempt was suspended; clearing blindly would erase the
        // successor's handle and revive the very race this task exists to stop.
        defer { if connecting == attempt { connecting = nil } }
        return try await attempt.value
    }

    private func establish(_ credentials: SSHCredentials) async throws {
        let pinned = try hostKeys.pinnedKey(forRobot: robot).flatMap(HostKeyFingerprint.init(openSSHPublicKey:))
        let validator = TOFUHostKeyValidator(pinned: pinned)

        let opened: SSHClient
        do {
            opened = try await SSHClient.connect(
                host: credentials.host,
                port: credentials.port,
                authenticationMethod: .passwordBased(
                    username: credentials.username,
                    password: credentials.password
                ),
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                // The process-wide group. Citadel's default builds a fresh
                // single-thread group per connection and `close()` never shuts one
                // down, so every reconnect on a flaky LAN would leak a thread.
                group: MultiThreadedEventLoopGroup.singleton
            )
        } catch {
            throw Self.mapConnectFailure(error, validator: validator)
        }

        do {
            let sftp = try await opened.openSFTP()
            // A disconnect() interleaved during the handshake cancelled this
            // attempt. Ending up connected anyway would overrule it.
            try Task.checkCancellation()
            self.sftp = sftp
            client = opened
        } catch {
            try? await opened.close()
            throw error is CancellationError ? error : Self.map(error)
        }
    }

    public func disconnect() async {
        connecting?.cancel()
        // Cleared as well as cancelled: the doomed attempt only notices the
        // cancellation once its handshake lands, seconds later, and a reconnect
        // arriving before then must start fresh rather than join it and inherit
        // its `CancellationError`.
        connecting = nil
        try? await sftp?.close()
        try? await client?.close()
        sftp = nil
        client = nil
    }

    /// Accepts the key the last ``connect(_:)`` was offered, so the next one
    /// succeeds. Separate from `connect` because only a person can do this.
    public func trustOfferedHostKey(_ fingerprint: HostKeyFingerprint) throws {
        try hostKeys.pin(fingerprint.openSSHPublicKey, forRobot: robot)
    }

    // MARK: - Files

    public func list(_ path: String) async throws -> [RemoteFile] {
        let sftp = try session()
        let names = try await perform { try await sftp.listDirectory(atPath: path) }
        return names.flatMap(\.components)
            // The server lists these and a file browser has no use for them; the
            // parent is reached by the breadcrumb, not by a row.
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { component in
                let mode = component.attributes.permissions
                return RemoteFile(
                    name: component.filename,
                    path: RemoteFile.joining(path, component.filename),
                    kind: RemoteFile.kind(mode: mode, longname: component.longname),
                    size: component.attributes.size,
                    modified: component.attributes.accessModificationTime?.modificationTime,
                    mode: mode
                )
            }
    }

    public func read(_ path: String, limit: Int) async throws -> Data {
        let sftp = try session()
        // Asked before opening, so a model file answers `.fileTooLarge` instead of
        // being pulled into a phone's memory to find out.
        let attributes = try await perform { try await sftp.getAttributes(at: path) }
        if let size = attributes.size, size > UInt64(limit) {
            throw ReachySSHError.fileTooLarge(bytes: size, limit: limit)
        }
        return try await perform {
            try await sftp.withFile(filePath: path, flags: .read) { file in
                try await Data(file.readAll().readableBytesView)
            }
        }
    }

    public func write(_ data: Data, to path: String) async throws {
        let sftp = try session()
        try await perform {
            try await sftp.withFile(filePath: path, flags: [.write, .create, .truncate]) { file in
                try await file.write(ByteBuffer(bytes: data), at: 0)
            }
        }
    }

    public func makeDirectory(at path: String) async throws {
        let sftp = try session()
        try await perform { try await sftp.createDirectory(atPath: path) }
    }

    public func remove(_ file: RemoteFile) async throws {
        let sftp = try session()
        try await perform {
            if file.isDirectory {
                // `rmdir` refuses a directory with contents, which is the guard we
                // want: nothing here recurses.
                try await sftp.rmdir(at: file.path)
            } else {
                try await sftp.remove(at: file.path)
            }
        }
    }

    public func rename(_ path: String, to newPath: String) async throws {
        let sftp = try session()
        try await perform { try await sftp.rename(at: path, to: newPath) }
    }

    // MARK: - Plumbing

    private func session() throws -> SFTPClient {
        guard let sftp else { throw ReachySSHError.notConnected }
        return sftp
    }

    /// Runs one SFTP call and translates whatever it threw. Cancellation is
    /// rethrown untouched: an abandoned listing is not a failure, and the screen
    /// filters it out rather than painting it.
    private func perform<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.map(error)
        }
    }

    private static func mapConnectFailure(
        _ error: any Error,
        validator: TOFUHostKeyValidator
    ) -> any Error {
        // The handshake fails with whatever the delegate put in the promise, but
        // NIO wraps it on the way out, so the validator's own record — not the
        // thrown value — is what says which case this is.
        guard let offered = validator.offered else { return map(error) }
        if let pinned = validator.pinned, pinned != offered {
            return ReachySSHError.hostKeyChanged(pinned: pinned, offered: offered)
        }
        if validator.pinned == nil {
            return ReachySSHError.hostKeyUnknown(offered)
        }
        return map(error)
    }

    private static func map(_ error: any Error) -> any Error {
        switch error {
        case let error as ReachySSHError:
            return error
        case let error as SFTPError:
            guard case let .errorStatus(status) = error else {
                return ReachySSHError.transport(String(describing: error))
            }
            switch status.errorCode {
            case .noSuchFile: return ReachySSHError.pathNotFound(status.message)
            case .permissionDenied: return ReachySSHError.notPermitted(status.message)
            // The spec has no "not empty" code; OpenSSH answers a plain failure and
            // says so only in the message, so that is what has to be read.
            case .failure where status.message.lowercased().contains("not empty"):
                return ReachySSHError.directoryNotEmpty(status.message)
            default: return ReachySSHError.transport(status.message)
            }
        case CitadelError.unauthorized:
            return ReachySSHError.authenticationFailed
        default:
            return ReachySSHError.transport(error.localizedDescription)
        }
    }
}

/// Trust on first use, decided synchronously because it has to be.
///
/// `validateHostKey` hands back an `EventLoopPromise` that must be resolved during
/// the handshake — there is no way to suspend it while a person looks at a
/// fingerprint. So an unpinned key is *recorded and refused*: the screen shows what
/// it saw, the user accepts, the key is pinned, and the next connection succeeds.
/// Two connections, and the decision stays testable without bridging a promise.
/// Citadel's own `InvalidHostKey` is public but its initialiser is not, so the
/// refusal needs a type of its own. Nothing reads it: the validator's record is
/// what `mapConnectFailure` interprets, because NIO wraps whatever goes into the
/// promise on the way back out.
private struct HostKeyRefused: Error {}

final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let pinned: HostKeyFingerprint?
    /// Written on an event-loop thread and read from the actor afterwards.
    private let record = Mutex<HostKeyFingerprint?>(nil)

    var offered: HostKeyFingerprint? {
        record.withLock { $0 }
    }

    init(pinned: HostKeyFingerprint?) {
        self.pinned = pinned
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let offered = HostKeyFingerprint(openSSHPublicKey: String(openSSHPublicKey: hostKey))
        record.withLock { $0 = offered }
        guard let pinned, let offered else {
            validationCompletePromise.fail(HostKeyRefused())
            return
        }
        // `==`, the same operator `mapConnectFailure` uses. Every stored property of
        // `HostKeyFingerprint` is derived from the key line inside one failable
        // initialiser, so full equality and comparing `openSSHPublicKey` can never
        // disagree — but two spellings of one question invite them to drift.
        if pinned == offered {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(HostKeyRefused())
        }
    }
}
