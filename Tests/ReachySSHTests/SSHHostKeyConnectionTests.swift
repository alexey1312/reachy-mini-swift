#if os(macOS) || os(iOS)
    import Crypto
    import Foundation
    import NIOCore
    import NIOPosix
    @preconcurrency import NIOSSH
    @testable import ReachySSH
    import Synchronization
    import Testing

    @Suite("SSH host key connections", .timeLimit(.minutes(1)))
    struct SSHHostKeyConnectionTests {
        @Test("trusting a new key permits the next authentication attempt")
        func trustsTheOfferedKey() async throws {
            let secret = Curve25519.Signing.PrivateKey().rawRepresentation
            let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .childChannelInitializer { channel in
                    do {
                        let key = try NIOSSHPrivateKey(ed25519Key: .init(rawRepresentation: secret))
                        try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                            role: .server(.init(hostKeys: [key], userAuthDelegate: RefusePassword())),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        ))
                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                .bind(host: "127.0.0.1", port: 0).get()
            let port = try #require(server.localAddress?.port)
            let keys = MemoryHostKeys()
            let files = SSHFileSystem(robot: "test-robot", hostKeys: keys)
            let credentials = SSHCredentials(host: "127.0.0.1", port: port, username: "test", password: "wrong")
            do {
                do {
                    try await files.connect(credentials)
                    Issue.record("An unknown host key permits a connection.")
                } catch let ReachySSHError.hostKeyUnknown(offered) {
                    let key = try NIOSSHPrivateKey(ed25519Key: .init(rawRepresentation: secret))
                    let expected =
                        try #require(HostKeyFingerprint(openSSHPublicKey: String(openSSHPublicKey: key.publicKey)))
                    #expect(offered == expected)
                    try await files.trustOfferedHostKey(offered)
                    #expect(try keys.pinnedKey(forRobot: "test-robot") == offered.openSSHPublicKey)
                }
                await #expect(throws: ReachySSHError.authenticationFailed) {
                    try await files.connect(credentials)
                }
                await files.disconnect()
                try await server.close().get()
            } catch {
                await files.disconnect()
                try? await server.close().get()
                throw error
            }
        }

        private struct RefusePassword: NIOSSHServerUserAuthenticationDelegate {
            let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password

            func requestReceived(
                request _: NIOSSHUserAuthenticationRequest,
                responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
            ) {
                responsePromise.succeed(.failure)
            }
        }

        private final class MemoryHostKeys: HostKeyStore, Sendable {
            private let keys = Mutex<[String: String]>([:])

            func pinnedKey(forRobot robot: String) throws -> String? {
                keys.withLock { $0[robot] }
            }

            func pin(_ key: String, forRobot robot: String) throws {
                keys.withLock { $0[robot] = key }
            }

            func forget(robot: String) throws {
                keys.withLock { $0[robot] = nil }
            }
        }
    }
#endif
