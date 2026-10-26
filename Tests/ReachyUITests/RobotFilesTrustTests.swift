import Foundation
import ReachySSH
@testable import ReachyUI
import Synchronization
import Testing

@MainActor
@Suite("Robot file access after key confirmation", .timeLimit(.minutes(1)))
struct RobotFilesTrustTests {
    private let key = HostKeyFingerprint(
        openSSHPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBKxSnnReKXYSkOtrc1X2t3KlT7aQiTAgRxF4A+fDZCz"
    )!

    private func model(_ files: PinningFileSystem, credentials: Credentials) -> RobotFilesModel {
        RobotFilesModel(files: files, credentials: credentials, robot: "test-robot", host: "robot.local")
    }

    @Test("acceptance opens the directory and saves the password for the next visit")
    func acceptanceOpensFiles() async {
        let files = PinningFileSystem(offered: key)
        let credentials = Credentials()
        let first = model(files, credentials: credentials)
        first.password = "test-password"
        await first.start()
        #expect(first.phase == .confirmHostKey(key))
        #expect(credentials.stored == nil)

        await first.trustOfferedKey()

        #expect(first.phase == .browsing)
        #expect(first.hasListed)
        #expect(await files.pinned == key)
        #expect(credentials.stored?.password == "test-password")
        await first.disconnect()

        let second = model(files, credentials: credentials)
        await second.start()
        #expect(second.phase == .browsing)
        #expect(second.hasListed)
    }

    @Test("a failed key save reports an error and does not retry the connection")
    func keyFailureIsVisible() async {
        let files = PinningFileSystem(offered: key, pinFailure: .keychain(-25308))
        let credentials = Credentials()
        let model = model(files, credentials: credentials)
        model.password = "test-password"
        await model.start()

        await model.trustOfferedKey()

        guard case let .failed(reason) = model.phase else {
            Issue.record("The screen does not report the failed key save.")
            return
        }
        #expect(!reason.isEmpty)
        #expect(await files.connections == 1)
        #expect(credentials.stored == nil)
    }

    @Test("a changed key requires confirmation before the directory opens")
    func changedKeyRequiresConfirmation() async throws {
        let previous = try #require(HostKeyFingerprint(openSSHPublicKey: "ssh-ed25519 AAAA"))
        let files = PinningFileSystem(offered: key, pinned: previous)
        let model = model(files, credentials: Credentials())
        model.password = "test-password"
        await model.start()
        #expect(model.phase == .hostKeyChanged(pinned: previous, offered: key))

        await model.trustOfferedKey()

        #expect(model.phase == .browsing)
        #expect(await files.pinned == key)
    }

    private final class Credentials: SSHCredentialStore, Sendable {
        private let value = Mutex<SSHCredentials?>(nil)

        var stored: SSHCredentials? {
            value.withLock { $0 }
        }

        func credentials(forRobot _: String) throws -> SSHCredentials? {
            stored
        }

        func save(_ credentials: SSHCredentials, forRobot _: String) throws {
            value.withLock { $0 = credentials }
        }

        func clear(robot _: String) throws {
            value.withLock { $0 = nil }
        }
    }

    private actor PinningFileSystem: HostKeyPinning {
        let offered: HostKeyFingerprint
        let pinFailure: ReachySSHError?
        private(set) var pinned: HostKeyFingerprint?
        private(set) var connections = 0
        private let files = PreviewFileSystem(tree: ["/": []])

        init(offered: HostKeyFingerprint, pinned: HostKeyFingerprint? = nil, pinFailure: ReachySSHError? = nil) {
            self.offered = offered
            self.pinned = pinned
            self.pinFailure = pinFailure
        }

        func connect(_ credentials: SSHCredentials) async throws {
            connections += 1
            guard let pinned else { throw ReachySSHError.hostKeyUnknown(offered) }
            guard pinned == offered else { throw ReachySSHError.hostKeyChanged(pinned: pinned, offered: offered) }
            try await files.connect(credentials)
        }

        func trustOfferedHostKey(_ fingerprint: HostKeyFingerprint) throws {
            if let pinFailure {
                throw pinFailure
            }
            pinned = fingerprint
        }

        func disconnect() async {
            await files.disconnect()
        }

        func list(_ path: String) async throws -> [RemoteFile] {
            try await files.list(path)
        }

        func read(_ path: String, limit: Int) async throws -> Data {
            try await files.read(path, limit: limit)
        }

        func readPseudoFile(_ path: String) async throws -> String {
            try await files.readPseudoFile(path)
        }

        func write(_ data: Data, to path: String) async throws {
            try await files.write(data, to: path)
        }

        func makeDirectory(at path: String) async throws {
            try await files.makeDirectory(at: path)
        }

        func remove(_ file: RemoteFile) async throws {
            try await files.remove(file)
        }

        func rename(_ path: String, to newPath: String) async throws {
            try await files.rename(path, to: newPath)
        }
    }
}
