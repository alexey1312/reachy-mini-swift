import Foundation
import Observation
import ReachyDesign
import ReachySSH

/// Browsing the robot's own file system over SFTP.
///
/// The screen is thin and this is where the interesting parts live: the two-step
/// host key trust, and the fact that a failure here is *not* a daemon failure and
/// so cannot go through `recordDaemonFailure`.
@MainActor
@Observable
final class RobotFilesModel {
    /// A phone must not pull a multi-gigabyte file into memory in either direction —
    /// not a model weight coming off the robot to reach a document picker, and not
    /// one picked on the device to be pushed back.
    static let transferLimit = 8 * 1024 * 1024

    private let files: any RobotFileSystem
    private let credentials: any SSHCredentialStore
    private let robot: String
    private let host: String
    private let port: Int

    private(set) var phase: Phase = .idle
    private(set) var path: String
    private(set) var entries: [RemoteFile] = []
    /// A listing in flight over rows already on screen. Distinct from `.connecting`
    /// so a refresh keeps what is there instead of blanking it.
    private(set) var isLoading = false
    /// Never answered yet, as opposed to answered with nothing — without this the
    /// first frame would claim an empty directory before anything was asked.
    private(set) var hasListed = false
    private(set) var lastError: String?
    /// The operation the screen is showing progress for, if any.
    private(set) var transferring: String?

    /// Whether the Keychain has been consulted. See `loadStoredCredentials()`.
    private var hasLoadedCredentials = false

    /// Coalesces overlapping listings (`AppStoreModel.loadID`'s pattern): a
    /// stale answer must not land under a path the user has since left.
    private var listingID: UUID?

    /// The password field. Not `private(set)`: the sheet binds to it.
    var username: String
    /// Empty until `loadStoredCredentials()` or the user fills it in. The factory
    /// default is named in the field's footer rather than prefilled here.
    var password = ""
    var confirming: Confirmation?

    init(
        files: any RobotFileSystem,
        credentials: any SSHCredentialStore = KeychainSSHCredentialStore(),
        robot: String,
        host: String,
        port: Int = SSHCredentials.defaultPort,
        path: String = "/"
    ) {
        self.files = files
        self.credentials = credentials
        self.robot = robot
        self.host = host
        self.port = port
        self.path = path
        // Deliberately *not* reading the Keychain here. `NavigationLink { … }` builds
        // its destination eagerly, so this initialiser runs on the main thread on
        // every render of the Advanced group — and `RobotFilesScreen` adopts the
        // first model into `@State`, so every later one is built and thrown away.
        // A synchronous `SecItemCopyMatching` per render is an XPC round trip for
        // nothing. `loadStoredCredentials()` does it once, from `start()`.
        username = SSHCredentials.defaultUsername
    }

    /// Closes the session when nothing holds this model any more.
    ///
    /// Not housekeeping: `SSHClient` has **no `deinit`** and `close()` is the only
    /// thing that shuts its channel, so a model released without this leaves a live
    /// TCP connection to the robot and a NIO channel behind — one per visit to the
    /// screen, for as long as the app runs. `deinit` rather than `.onDisappear`
    /// because it fires exactly when the last reference goes, which is what "the
    /// user left for good" actually means.
    ///
    /// `files` is bound before the `Task` so the closure never captures `self`,
    /// which a `deinit` may not escape.
    deinit {
        let files = files
        Task { await files.disconnect() }
    }

    // MARK: - Session

    /// Opens the session if it is not open, using whatever password is in hand.
    /// Safe to call from `.task` — a second call while browsing does nothing.
    func start() async {
        guard phase == .idle || phase == .needsPassword else { return }
        loadStoredCredentials()
        guard !password.isEmpty else {
            phase = .needsPassword
            return
        }
        await connect()
    }

    /// Reads the Keychain once, on the first visit rather than in `init`.
    ///
    /// Gated on a flag and not on `password.isEmpty`: someone who clears the field
    /// on purpose — because the robot's password changed — must not have the old one
    /// put back under them on the next `start()`.
    private func loadStoredCredentials() {
        guard !hasLoadedCredentials else { return }
        hasLoadedCredentials = true
        guard let stored = try? credentials.credentials(forRobot: robot) else { return }
        username = stored.username
        password = stored.password
    }

    func connect() async {
        phase = .connecting
        lastError = nil
        do {
            try await files.connect(
                SSHCredentials(host: host, port: port, username: username, password: password)
            )
            try? credentials.save(
                SSHCredentials(host: host, port: port, username: username, password: password),
                forRobot: robot
            )
            phase = .browsing
            await refresh()
        } catch let error as ReachySSHError {
            switch error {
            case let .hostKeyUnknown(fingerprint):
                phase = .confirmHostKey(fingerprint)
            case let .hostKeyChanged(pinned, offered):
                phase = .hostKeyChanged(pinned: pinned, offered: offered)
            case .authenticationFailed:
                // Back to the field rather than to a dead end, and the stored
                // password goes: keeping a refused one means the next visit
                // fails the same way with nothing to show for it.
                try? credentials.clear(robot: robot)
                phase = .needsPassword
                lastError = String(localized: .reachy("That password was refused by the robot."))
            default:
                phase = .failed(Self.describe(error))
            }
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    /// Accepts the offered key and connects again. Only reachable from a screen
    /// that showed the fingerprint.
    func trustOfferedKey() async {
        let offered: HostKeyFingerprint? = switch phase {
        case let .confirmHostKey(fingerprint): fingerprint
        case let .hostKeyChanged(_, offered): offered
        default: nil
        }
        guard let offered, let files = files as? SSHFileSystem else {
            // A stub file system has no key to pin; treat acceptance as a retry so
            // previews and tests can drive the same button.
            await connect()
            return
        }
        do {
            try await files.trustOfferedHostKey(offered)
        } catch {
            phase = .failed(Self.describe(error))
            return
        }
        await connect()
    }

    func disconnect() async {
        await files.disconnect()
        phase = .idle
        entries = []
        hasListed = false
    }

    // MARK: - Browsing

    func refresh() async {
        guard phase == .browsing else { return }
        let requestID = UUID()
        listingID = requestID
        isLoading = true
        defer {
            if listingID == requestID {
                isLoading = false
            }
        }
        do {
            let listed = try await files.list(path).sorted(by: Self.ordered)
            guard listingID == requestID else { return }
            entries = listed
            hasListed = true
            lastError = nil
        } catch is CancellationError {
            // Leaving the screen mid-listing learned nothing: it may neither report
            // a failure nor clear one still being read.
        } catch {
            guard listingID == requestID else { return }
            // A refusal is an answer. Without this the screen keeps the full-bleed
            // "Reading the folder…" overlay up for good — and that overlay covers
            // the very error row the failure just filled in.
            hasListed = true
            report(error)
        }
    }

    func open(_ file: RemoteFile) async {
        guard file.isDirectory else { return }
        await go(to: file.path)
    }

    func go(to newPath: String) async {
        path = newPath
        entries = []
        hasListed = false
        await refresh()
    }

    func goUp() async {
        guard let parent = RemoteFile.parent(of: path) else { return }
        await go(to: parent)
    }

    var canGoUp: Bool {
        RemoteFile.parent(of: path) != nil
    }

    // MARK: - Changing things

    /// Reads a file so the screen can hand it to a document picker.
    func contents(of file: RemoteFile) async -> Data? {
        transferring = file.name
        defer { transferring = nil }
        do {
            return try await files.read(file.path, limit: Self.transferLimit)
        } catch {
            report(error)
            return nil
        }
    }

    /// Reads a file the user picked on the device and writes it to the robot.
    ///
    /// `PickedFile.read` is where the detached task, the security scope and the
    /// size-check-before-read live; the limit and the sentence for crossing it are this
    /// screen's, which is why they are passed in.
    func upload(from url: URL, to destination: String) async {
        transferring = (destination as NSString).lastPathComponent
        defer { transferring = nil }
        do {
            let limit = Self.transferLimit
            let data = try await PickedFile.read(at: url, limit: limit) {
                ReachySSHError.fileTooLarge(bytes: UInt64($0), limit: limit)
            }
            try await files.write(data, to: destination)
            await refresh()
        } catch {
            report(error)
        }
    }

    /// Writes bytes already in hand to an explicit path. This is both "add a file
    /// here" and "replace this one": without an in-app editor, replacing over the
    /// same path is how an edit made on the device lands back on the robot.
    func upload(_ data: Data, to destination: String) async {
        transferring = (destination as NSString).lastPathComponent
        defer { transferring = nil }
        do {
            try await files.write(data, to: destination)
            await refresh()
        } catch {
            report(error)
        }
    }

    func makeDirectory(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await files.makeDirectory(at: RemoteFile.joining(path, trimmed))
            await refresh()
        } catch {
            report(error)
        }
    }

    func rename(_ file: RemoteFile, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != file.name else { return }
        do {
            try await files.rename(file.path, to: RemoteFile.joining(path, trimmed))
            await refresh()
        } catch {
            report(error)
        }
    }

    func delete(_ file: RemoteFile) async {
        do {
            try await files.remove(file)
            await refresh()
        } catch {
            report(error)
        }
    }

    /// The destination an upload into the current directory would take.
    func destination(forFileNamed name: String) -> String {
        RemoteFile.joining(path, name)
    }

    // MARK: - Errors

    private func report(_ error: any Error) {
        if error is CancellationError {
            return
        }
        lastError = Self.describe(error)
    }

    /// Directories first, then case-insensitive by name — the order every file
    /// manager uses, and the one that puts `user_personalities/` above the noise.
    private static func ordered(_ lhs: RemoteFile, _ rhs: RemoteFile) -> Bool {
        if lhs.isDirectory != rhs.isDirectory {
            return lhs.isDirectory
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

#if DEBUG
    extension RobotFilesModel {
        /// In the model's own file rather than in `Previews/`, because it writes
        /// `private(set)` members that `@testable` does not reach.
        static func preview(
            files: any RobotFileSystem = PreviewFileSystem.brokenPersonality(),
            phase: Phase = .browsing,
            path: String = PreviewFileSystem.appPackage,
            entries: [RemoteFile] = [],
            isLoading: Bool = false,
            hasListed: Bool = true,
            error: String? = nil,
            transferring: String? = nil,
            password: String = "root"
        ) -> RobotFilesModel {
            let model = RobotFilesModel(
                files: files,
                credentials: EphemeralCredentialStore(),
                robot: "preview",
                host: "reachy-mini.local",
                path: path
            )
            model.phase = phase
            model.entries = entries
            model.isLoading = isLoading
            model.hasListed = hasListed
            model.lastError = error
            model.transferring = transferring
            model.password = password
            return model
        }

        /// The directory listing the fixture holds, sorted the way the screen shows
        /// it — so a preview is final on its first frame without a `.task`.
        static func previewEntries(at path: String = PreviewFileSystem.appPackage) -> [RemoteFile] {
            PreviewFileSystem.brokenPersonality().entries(at: path).sorted(by: ordered)
        }
    }
#endif
