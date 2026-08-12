import Foundation
import ReachyJSON

/// Drives the gst `webrtcsink` signaling handshake on `ws://<host>:8443` and
/// surfaces only what a peer connection needs: the robot's SDP offer, remote
/// ICE candidates, and session teardown.
///
/// Flow: `welcome` → `setPeerStatus(listener)` → `list` → pick a producer
/// (prefer `meta.name == "reachymini"`; the simulator names its camera
/// differently, so any producer is accepted as fallback) → `startSession` →
/// forward `sdp`/`ice`. Reconnects forever until the events consumer cancels.
public actor CameraSignalingClient {
    public static let defaultPort = 8443
    static let preferredProducerName = "reachymini"

    public struct Configuration: Sendable {
        /// Upstream reconnect cadence: fast before the first established session, slow after.
        public var reconnectBeforeFirstSuccess: Duration = .milliseconds(500)
        public var reconnectAfterSuccess: Duration = .seconds(2)
        /// Sent as `meta.name` in `setPeerStatus`; shows up in the daemon's peer list.
        public var clientName = "ReachyMini Swift"
        public init() {}
    }

    private let url: URL
    private let configuration: Configuration
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var ownPeerID: String?
    private var producerID: String?
    private var sessionID: String?
    private var hadSession = false

    public init(
        address: RobotAddress,
        port: Int = CameraSignalingClient.defaultPort,
        configuration: Configuration = .init(),
        session: URLSession = .shared
    ) throws {
        var signaling = address
        signaling.port = port
        guard let url = signaling.webSocketURL(path: "") else {
            throw ReachyKitError.invalidAddress(address)
        }
        self.url = url
        self.configuration = configuration
        self.session = session
    }

    /// Signaling events. Single consumer; connects lazily, reconnects forever,
    /// finishes only when the consumer cancels.
    public func events() -> AsyncStream<SignalingEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: SignalingEvent.self)
        let task = Task { await run(continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Sends the SDP answer for the current session (no-op when no session).
    public func send(answerSDP: String) async {
        guard let sessionID else { return }
        await send(.sdp(sessionID: sessionID, type: "answer", sdp: answerSDP))
    }

    /// Sends a local ICE candidate for the current session (no-op when no session).
    public func send(candidate: String, sdpMLineIndex: Int32, sdpMid: String?) async {
        guard let sessionID else { return }
        await send(.ice(sessionID: sessionID, candidate: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid))
    }

    /// Best-effort `endSession` + socket close. The events loop reconnects on
    /// its own; cancel the events stream to stop for good.
    public func disconnect() async {
        if let sessionID {
            await send(.endSession(sessionID: sessionID, reason: nil))
        }
        sessionID = nil
        producerID = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    // MARK: - Internals

    private func run(_ continuation: AsyncStream<SignalingEvent>.Continuation) async {
        while !Task.isCancelled {
            let socket = session.webSocketTask(with: url)
            socket.resume()
            self.socket = socket
            ownPeerID = nil
            producerID = nil
            sessionID = nil
            do {
                while true {
                    let message = try await socket.receive()
                    // receive() is not cancellation-responsive; without this a
                    // cancelled loop keeps renegotiating until the socket closes.
                    guard !Task.isCancelled else { throw CancellationError() }
                    let data: Data? = switch message {
                    case let .data(data): data
                    case let .string(text): Data(text.utf8)
                    @unknown default: nil
                    }
                    // Unknown message types are dropped: the daemon may add new ones.
                    guard let data,
                          let decoded = try? JSONCodec.daemon.decode(SignalingMessage.self, from: data)
                    else { continue }
                    await handle(decoded, continuation)
                }
            } catch {
                socket.cancel(with: .goingAway, reason: nil)
            }
            self.socket = nil
            if sessionID != nil || producerID != nil {
                continuation.yield(.sessionEnded(reason: nil))
            }
            if Task.isCancelled {
                break
            }
            let backoff = hadSession
                ? configuration.reconnectAfterSuccess
                : configuration.reconnectBeforeFirstSuccess
            try? await Task.sleep(for: backoff)
        }
        continuation.finish()
    }

    // Flat wire-protocol switch: one branch per message type.
    // swiftlint:disable:next cyclomatic_complexity
    private func handle(_ message: SignalingMessage, _ continuation: AsyncStream<SignalingEvent>.Continuation) async {
        switch message {
        case let .welcome(peerID):
            ownPeerID = peerID
            await send(.setPeerStatus(roles: ["listener"], name: configuration.clientName))
        case let .peerStatusChanged(peerID, roles, _) where peerID == ownPeerID:
            if roles.contains("listener") {
                await send(.list)
            }
        case let .peerStatusChanged(peerID, roles, _):
            if roles.contains("producer") {
                if producerID == nil {
                    await startSession(producerID: peerID)
                }
            } else if peerID == producerID {
                endCurrentSession(continuation)
                await send(.list)
            }
        case let .producerList(producers):
            guard producerID == nil else { return }
            let preferred = producers.first { $0.name == Self.preferredProducerName } ?? producers.first
            if let preferred {
                await startSession(producerID: preferred.id)
            } else {
                continuation.yield(.waitingForProducer)
            }
        case let .sessionStarted(_, sessionID):
            self.sessionID = sessionID
            hadSession = true
        case let .sdp(sessionID, _, sdp):
            continuation.yield(.offer(sessionID: sessionID, sdp: sdp))
        case let .ice(sessionID, candidate, sdpMLineIndex, sdpMid):
            continuation.yield(.remoteCandidate(
                sessionID: sessionID, candidate: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid
            ))
        case .endSession:
            endCurrentSession(continuation)
            await send(.list)
        case .error:
            // Advisory ("details" text); real failures surface via the socket.
            break
        case .setPeerStatus, .list, .startSession:
            break // outbound-only types; a server never sends these to a listener
        case .sessionRejected, .sessionStateChanged:
            break // the central relay's vocabulary; the robot's own socket has neither
        }
    }

    private func startSession(producerID: String) async {
        self.producerID = producerID
        await send(.startSession(peerID: producerID))
    }

    private func endCurrentSession(_ continuation: AsyncStream<SignalingEvent>.Continuation) {
        guard sessionID != nil || producerID != nil else { return }
        sessionID = nil
        producerID = nil
        continuation.yield(.sessionEnded(reason: nil))
    }

    private func send(_ message: SignalingMessage) async {
        guard let socket,
              let data = try? JSONCodec.daemon.encode(message),
              let text = String(data: data, encoding: .utf8)
        else { return }
        try? await socket.send(.string(text))
    }
}
