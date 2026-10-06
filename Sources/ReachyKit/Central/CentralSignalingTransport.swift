import Foundation

/// The Hugging Face relay, dressed as signaling for the media layer.
///
/// Everything specific to reaching a robot from outside its network lives here:
/// finding it in central's producer list, asking for a session, and turning
/// central's refusals into something a screen can say. What comes out the other
/// side is the same `SignalingEvent` stream the robot's own socket produces, so
/// the WebRTC half never learns which network it is on.
public actor CentralSignalingTransport: RobotSignaling {
    private let relay: CentralRelayClient
    /// Which robot to ask for. `peerId` changes on every relay reconnect, so this
    /// is resolved from a stable id (`hardware_id`) before a transport is built,
    /// not stored across reconnects.
    private let robotPeerID: String

    private var sessionID: String?
    /// Central hands out one session per ask. Producer lists arrive repeatedly —
    /// on connect and on every peer change — and asking again for a session we
    /// already hold would evict ourselves.
    private var isNegotiating = false

    public init(relay: CentralRelayClient, robotPeerID: String) {
        self.relay = relay
        self.robotPeerID = robotPeerID
    }

    public func events() -> AsyncStream<SignalingEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SignalingEvent.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        let task = Task { await run(continuation) }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func send(answerSDP: String) async {
        guard let sessionID else { return }
        try? await relay.answer(sessionID: sessionID, sdp: answerSDP)
    }

    public func send(candidate: String, sdpMLineIndex: Int32, sdpMid: String?) async {
        guard let sessionID else { return }
        try? await relay.send(
            candidate: candidate,
            sdpMLineIndex: sdpMLineIndex,
            sdpMid: sdpMid,
            sessionID: sessionID
        )
    }

    public func disconnect() async {
        guard let sessionID else { return }
        self.sessionID = nil
        isNegotiating = false
        try? await relay.endSession(sessionID)
    }

    private func run(_ continuation: AsyncStream<SignalingEvent>.Continuation) async {
        defer { continuation.finish() }

        for await event in await relay.events() {
            guard !Task.isCancelled else { return }
            switch event {
            case .connected:
                continue
            case let .producers(producers):
                await negotiate(among: producers, continuation)
            case let .offer(sessionID, sdp):
                self.sessionID = sessionID
                continuation.yield(.offer(sessionID: sessionID, sdp: sdp))
            case let .remoteCandidate(sessionID, candidate, index, mid):
                continuation.yield(.remoteCandidate(
                    sessionID: sessionID,
                    candidate: candidate,
                    sdpMLineIndex: index,
                    sdpMid: mid
                ))
            case let .sessionEnded(_, reason):
                sessionID = nil
                isNegotiating = false
                continuation.yield(.sessionEnded(reason: reason))
            case let .failed(failure):
                continuation.yield(.failed(Self.describe(failure)))
                return
            case .disconnected:
                continuation.yield(.sessionEnded(reason: nil))
                return
            }
        }
    }

    private func negotiate(
        among producers: [CentralRelayClient.Producer],
        _ continuation: AsyncStream<SignalingEvent>.Continuation
    ) async {
        guard sessionID == nil, !isNegotiating else { return }
        guard let robot = producers.first(where: { $0.peerID == robotPeerID }) else {
            // Absence from the list is central's way of saying offline — the lease
            // simply lapsed and nothing is producing.
            continuation.yield(.waitingForProducer)
            return
        }

        isNegotiating = true
        defer { isNegotiating = false }
        do {
            switch try await relay.startSession(with: robot.peerID) {
            case let .started(sessionID):
                self.sessionID = sessionID
                // The same sign the robot's own socket gives: after a wait, the
                // media layer times the offer from here.
                continuation.yield(.sessionRequested)
            case let .rejected(reason, activeApp):
                continuation.yield(.failed(RemoteSessionEnd(reason: reason, activeApp: activeApp).message))
            }
        } catch {
            continuation.yield(.failed(Self.describe(error)))
        }
    }

    // MARK: - Words for what happened

    private static func describe(_ failure: CentralRelayClient.Failure) -> String {
        switch failure {
        case .noToken:
            "Sign in to Hugging Face to reach this robot from outside its network."
        case .unauthorized:
            "Hugging Face refused this session. Sign in again."
        case .rateLimited:
            "Too many requests to Hugging Face. Try again in a minute."
        case let .http(code):
            "Hugging Face answered HTTP \(code)."
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let failure = error as? CentralRelayClient.Failure {
            return describe(failure)
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
