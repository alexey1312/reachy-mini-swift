import Foundation
import Network
@testable import ReachyKit
import Testing

/// The server's "you are registered as listener" confirmation for the fake's fixed peer id.
private let listenerReady = SignalingMessage.peerStatusChanged(
    peerID: FakeSignalingServer.clientPeerID, roles: ["listener"], name: nil
)

@Suite("CameraSignalingClient")
struct CameraSignalingClientTests {
    private func makeClient(port: UInt16) throws -> CameraSignalingClient {
        var configuration = CameraSignalingClient.Configuration()
        configuration.reconnectBeforeFirstSuccess = .milliseconds(50)
        configuration.reconnectAfterSuccess = .milliseconds(50)
        return try CameraSignalingClient(
            address: RobotAddress(host: "127.0.0.1"),
            port: Int(port),
            configuration: configuration
        )
    }

    @Test("happy path: handshake → offer + remote ICE, answer reaches the server", .timeLimit(.minutes(1)))
    func happyPath() async throws {
        let fake = try FakeSignalingServer { message, server in
            switch message {
            case .setPeerStatus:
                server.send(listenerReady)
            case .list:
                server.send(.producerList([.init(id: "prod-1", name: "reachymini")]))
            case let .startSession(peerID):
                server.send(.sessionStarted(peerID: peerID, sessionID: "sess-1"))
                server.send(.sdp(sessionID: "sess-1", type: "offer", sdp: "v=0 offer"))
                server.send(.ice(sessionID: "sess-1", candidate: "candidate:1", sdpMLineIndex: 0, sdpMid: "0"))
            default:
                break
            }
        }
        defer { fake.stop() }

        let client = try await makeClient(port: fake.readyPort())
        var events = await client.events().makeAsyncIterator()
        #expect(await events.next() == .offer(sessionID: "sess-1", sdp: "v=0 offer"))
        #expect(await events.next() == .remoteCandidate(
            sessionID: "sess-1", candidate: "candidate:1", sdpMLineIndex: 0, sdpMid: "0"
        ))
        #expect(fake.received(.startSession(peerID: "prod-1")) == 1)

        await client.send(answerSDP: "v=0 answer")
        await fake.waitFor(.sdp(sessionID: "sess-1", type: "answer", sdp: "v=0 answer"))
        await client.send(candidate: "candidate:9", sdpMLineIndex: 0, sdpMid: nil)
        await fake.waitFor(.ice(sessionID: "sess-1", candidate: "candidate:9", sdpMLineIndex: 0, sdpMid: nil))
        await client.disconnect()
    }

    @Test("prefers the producer named reachymini over others", .timeLimit(.minutes(1)))
    func prefersNamedProducer() async throws {
        let fake = try FakeSignalingServer { message, server in
            switch message {
            case .setPeerStatus:
                server.send(listenerReady)
            case .list:
                server.send(.producerList([
                    .init(id: "other", name: "someone-else"),
                    .init(id: "robot", name: "reachymini"),
                ]))
            default:
                break
            }
        }
        defer { fake.stop() }

        let client = try await makeClient(port: fake.readyPort())
        let events = await client.events()
        await fake.waitFor(.startSession(peerID: "robot"))
        #expect(fake.received(.startSession(peerID: "other")) == 0)
        _ = events // keep the stream (and its run loop) alive until here
    }

    @Test(
        "empty producer list → waitingForProducer, producer appearing later starts a session",
        .timeLimit(.minutes(1))
    )
    func waitsForProducer() async throws {
        let fake = try FakeSignalingServer { message, server in
            switch message {
            case .setPeerStatus:
                server.send(listenerReady)
            case .list:
                server.send(.producerList([]))
            case let .startSession(peerID):
                server.send(.sessionStarted(peerID: peerID, sessionID: "sess-2"))
                server.send(.sdp(sessionID: "sess-2", type: "offer", sdp: "v=0 late offer"))
            default:
                break
            }
        }
        defer { fake.stop() }

        let client = try await makeClient(port: fake.readyPort())
        var events = await client.events().makeAsyncIterator()
        #expect(await events.next() == .waitingForProducer)

        fake.send(.peerStatusChanged(peerID: "prod-late", roles: ["producer"], name: "reachymini"))
        #expect(await events.next() == .offer(sessionID: "sess-2", sdp: "v=0 late offer"))
    }

    @Test("endSession from server → sessionEnded event and a fresh list request", .timeLimit(.minutes(1)))
    func sessionEndedAndRelist() async throws {
        let fake = try FakeSignalingServer { message, server in
            switch message {
            case .setPeerStatus:
                server.send(listenerReady)
            case .list:
                server.send(.producerList([.init(id: "prod-1", name: "reachymini")]))
            case let .startSession(peerID):
                server.send(.sessionStarted(peerID: peerID, sessionID: "sess-1"))
                server.send(.sdp(sessionID: "sess-1", type: "offer", sdp: "v=0 offer"))
            default:
                break
            }
        }
        defer { fake.stop() }

        let client = try await makeClient(port: fake.readyPort())
        var events = await client.events().makeAsyncIterator()
        #expect(await events.next() == .offer(sessionID: "sess-1", sdp: "v=0 offer"))

        fake.send(.endSession(sessionID: "sess-1", reason: nil))
        #expect(await events.next() == .sessionEnded(reason: nil))
        // The client re-lists and re-negotiates a fresh session on its own.
        #expect(await events.next() == .offer(sessionID: "sess-1", sdp: "v=0 offer"))
        #expect(fake.received(.startSession(peerID: "prod-1")) == 2)
    }

    @Test("socket drop mid-session → sessionEnded, reconnect renegotiates", .timeLimit(.minutes(1)))
    func reconnectsAfterSocketDrop() async throws {
        let fake = try FakeSignalingServer { message, server in
            switch message {
            case .setPeerStatus:
                server.send(listenerReady)
            case .list:
                server.send(.producerList([.init(id: "prod-1", name: "reachymini")]))
            case let .startSession(peerID):
                server.send(.sessionStarted(peerID: peerID, sessionID: "sess-1"))
                server.send(.sdp(sessionID: "sess-1", type: "offer", sdp: "v=0 offer"))
            default:
                break
            }
        }
        defer { fake.stop() }

        let client = try await makeClient(port: fake.readyPort())
        var events = await client.events().makeAsyncIterator()
        #expect(await events.next() == .offer(sessionID: "sess-1", sdp: "v=0 offer"))

        fake.dropConnections()
        #expect(await events.next() == .sessionEnded(reason: nil))
        #expect(await events.next() == .offer(sessionID: "sess-1", sdp: "v=0 offer"))
        #expect(fake.connectionCount == 2)
    }

    /// What `CameraSession` does to a stalled attempt: drop the stream, end the
    /// session, subscribe again at once. The second subscription must come up with
    /// its own socket and its own session, and what it sends must reach the server —
    /// the first loop winds down while the second is starting, and the socket the
    /// second one sends on is not the first one's to clear.
    @Test("a consumer that starts over gets a fresh socket and a fresh session", .timeLimit(.minutes(1)))
    func startsOverOnResubscribe() async throws {
        let fake = try FakeSignalingServer { message, server in
            switch message {
            case .setPeerStatus:
                server.send(listenerReady)
            case .list:
                server.send(.producerList([.init(id: "prod-1", name: "reachymini")]))
            case let .startSession(peerID):
                let session = "sess-\(server.received(.startSession(peerID: peerID)))"
                server.send(.sessionStarted(peerID: peerID, sessionID: session))
                server.send(.sdp(sessionID: session, type: "offer", sdp: "v=0 offer"))
            default:
                break
            }
        }
        defer { fake.stop() }

        let client = try await makeClient(port: fake.readyPort())
        // A consumer of its own, so it can be cancelled the way the session cancels one.
        let (seen, forward) = AsyncStream.makeStream(of: SignalingEvent.self)
        let first = Task {
            for await event in await client.events() {
                forward.yield(event)
            }
        }
        var firstEvents = seen.makeAsyncIterator()
        #expect(await firstEvents.next() == .offer(sessionID: "sess-1", sdp: "v=0 offer"))
        first.cancel()
        await client.disconnect()

        var events = await client.events().makeAsyncIterator()
        #expect(await events.next() == .offer(sessionID: "sess-2", sdp: "v=0 offer"))
        #expect(fake.received(.endSession(sessionID: "sess-1", reason: nil)) == 1)
        await client.send(answerSDP: "v=0 answer")
        await fake.waitFor(.sdp(sessionID: "sess-2", type: "answer", sdp: "v=0 answer"))
        #expect(fake.connectionCount == 2)
    }
}

/// Scripted gst-style signaling server: sends `welcome` to every connection,
/// decodes client frames, records them, and lets the script reply.
private final class FakeSignalingServer: @unchecked Sendable {
    static let clientPeerID = "client-1"

    private final class Box: @unchecked Sendable {
        weak var value: FakeSignalingServer?
    }

    private let server: LocalWebSocketServer
    private let onMessage: @Sendable (SignalingMessage, FakeSignalingServer) -> Void
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var receivedMessages: [SignalingMessage] = []

    var connectionCount: Int {
        lock.withLock { connections.count }
    }

    init(onMessage: @escaping @Sendable (SignalingMessage, FakeSignalingServer) -> Void) throws {
        self.onMessage = onMessage
        let box = Box()
        server = try LocalWebSocketServer { connection in
            box.value?.accept(connection)
        }
        box.value = self
    }

    func readyPort() async throws -> UInt16 {
        try await server.readyPort()
    }

    func stop() {
        server.stop()
    }

    /// Sends a message over the most recent connection.
    func send(_ message: SignalingMessage) {
        guard let connection = lock.withLock({ connections.last }),
              let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8)
        else { return }
        LocalWebSocketServer.sendText(text, over: connection)
    }

    func received(_ message: SignalingMessage) -> Int {
        lock.withLock { receivedMessages.count { $0 == message } }
    }

    /// Polls until the client has sent `message`; the test's time limit is the timeout.
    func waitFor(_ message: SignalingMessage) async {
        while received(message) == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func dropConnections() {
        let dropped = lock.withLock { connections }
        for connection in dropped {
            connection.forceCancel()
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        send(.welcome(peerID: Self.clientPeerID))
        receiveLoop(connection)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let message = try? JSONDecoder().decode(SignalingMessage.self, from: data) {
                lock.withLock { receivedMessages.append(message) }
                onMessage(message, self)
            }
            if error == nil {
                receiveLoop(connection)
            }
        }
    }
}
