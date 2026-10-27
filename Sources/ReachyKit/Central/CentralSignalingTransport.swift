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
    /// Which robot to ask for. `peerId` changes every time the robot registers
    /// with central again, and from daemon 1.13.0 it does so more readily (two
    /// failed heartbeats), while this transport outlives it: a stalled negotiation
    /// starts over on the same transport. So it follows ``robotIdentity``.
    private var robotPeerID: String
    /// The robot's stable id, `install_id` or else `hardware_id`, the key the JS
    /// SDK re-dials by. Nil for a robot that sends neither, which is then only
    /// ever found under the peer id it was picked by.
    private let robotIdentity: String?

    private var sessionID: String?
    /// Central hands out one session per ask. Producer lists arrive repeatedly —
    /// on connect and on every peer change — and asking again for a session we
    /// already hold would evict ourselves.
    private var isNegotiating = false
    /// Sessions this transport has finished with. An `endSession` for one of them
    /// arrives late — a `superseded` for the ghost a re-dial replaced is the
    /// common case — and must not end the session that replaced it.
    private var endedSessionIDs: Set<String> = []

    public init(relay: CentralRelayClient, robotPeerID: String, robotIdentity: String? = nil) {
        self.relay = relay
        self.robotPeerID = robotPeerID
        self.robotIdentity = robotIdentity
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

    /// Always with a reason: from daemon 1.13.0 a reason-less `endSession` is
    /// central's bookkeeping, and the robot keeps a session whose link is live.
    public func disconnect(_ hangUp: SignalingHangUp) async {
        guard let sessionID else { return }
        self.sessionID = nil
        isNegotiating = false
        endedSessionIDs.insert(sessionID)
        try? await relay.endSession(sessionID, reason: hangUp.rawValue)
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
            case .offer, .remoteCandidate, .sessionEnded:
                relaySessionEvent(event, continuation)
            case let .failed(failure):
                continuation.yield(.failed(Self.describe(failure)))
                return
            case .disconnected:
                continuation.yield(.sessionEnded(reason: nil))
                return
            }
        }
    }

    /// The three events that belong to one session, passed on only for the session
    /// this transport holds or is asking for — never for one it has finished with.
    private func relaySessionEvent(
        _ event: CentralRelayClient.Event,
        _ continuation: AsyncStream<SignalingEvent>.Continuation
    ) {
        switch event {
        case let .offer(sessionID, sdp):
            guard !endedSessionIDs.contains(sessionID) else { return }
            self.sessionID = sessionID
            continuation.yield(.offer(sessionID: sessionID, sdp: sdp))
        case let .remoteCandidate(sessionID, candidate, index, mid):
            guard !endedSessionIDs.contains(sessionID) else { return }
            continuation.yield(.remoteCandidate(
                sessionID: sessionID,
                candidate: candidate,
                sdpMLineIndex: index,
                sdpMid: mid
            ))
        case let .sessionEnded(endedID, reason):
            guard ends(endedID) else { return }
            endedSessionIDs.insert(endedID)
            sessionID = nil
            isNegotiating = false
            continuation.yield(.sessionEnded(reason: reason))
        case .connected, .producers, .failed, .disconnected:
            return
        }
    }

    private func negotiate(
        among producers: [CentralRelayClient.Producer],
        _ continuation: AsyncStream<SignalingEvent>.Continuation
    ) async {
        guard sessionID == nil, !isNegotiating else { return }
        guard let robot = target(among: producers) else {
            // Absence from the list is central's way of saying offline — the lease
            // simply lapsed and nothing is producing.
            continuation.yield(.waitingForProducer)
            return
        }
        robotPeerID = robot.peerID

        isNegotiating = true
        defer { isNegotiating = false }
        do {
            switch try await relay.startSession(with: robot.peerID) {
            case let .started(sessionID):
                // A refusal can overtake this answer on the stream; then it is over.
                guard !endedSessionIDs.contains(sessionID) else { return }
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

    /// The robot under a new peer id when it has registered again, and under the
    /// one it was picked by otherwise — the JS SDK's `_redialTargetResolver`. A
    /// listing under the old id may linger until central sweeps it, so the moved
    /// entry wins when both are there.
    private func target(among producers: [CentralRelayClient.Producer]) -> CentralRelayClient.Producer? {
        if let robotIdentity,
           let moved = producers.first(where: { $0.stableID == robotIdentity && $0.peerID != robotPeerID })
        {
            return moved
        }
        return producers.first { $0.peerID == robotPeerID }
    }

    /// Whether an `endSession` is for the session this transport holds.
    ///
    /// One for a session already finished with is late, never news. While a
    /// `startSession` is in flight the id is not known yet — central answers it in
    /// the body of the POST, and a refusal may overtake that answer on the stream —
    /// so it counts. With no session and no ask, there is nothing for it to end.
    private func ends(_ endedID: String) -> Bool {
        guard !endedSessionIDs.contains(endedID) else { return false }
        if let sessionID {
            return endedID == sessionID
        }
        return isNegotiating
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
