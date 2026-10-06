import ReachyKit
@testable import ReachyMedia
import Testing

/// A negotiation that stalls is started over once and then reported (#155), against a
/// real peer connection standing in for the robot — `LoopbackRobot`, in this process.
///
/// What none of this could be checked against before is libwebrtc's own order of
/// events, and that order is the bug: the remote video track is announced while the
/// offer is applied, before the robot has seen an answer, and `.streaming` used to be
/// declared right there. The watchdog behind it asked "not streaming yet?" and the
/// answer was always no, so it never once restarted anything.
///
/// Stalls are caused, never waited out: an answer that is not carried, an offer that is
/// not delivered. Every delivery waits for the subscription it is meant for — an event
/// sent before the session has subscribed reaches nobody, and the test would be
/// measuring that rather than the session. The deadlines are shortened for those and left long wherever an
/// attempt is expected to connect, so a loaded runner cannot turn a success into a stall.
@MainActor
@Suite("Camera session negotiation", .serialized, .timeLimit(.minutes(1)))
struct CameraSessionNegotiationTests {
    private static let stall: Duration = .milliseconds(400)
    private static let patience: Duration = .seconds(30)

    /// The exact shape the robot logs as `stuck mid-negotiation`: offer sent, answer
    /// never arrived, `have-local-offer` for good. The session holds the track by then,
    /// which is the moment it used to call this a stream.
    @Test("an answer the robot never receives is not a stream")
    func lostAnswerIsNotAStream() async throws {
        let robot = LoopbackRobot()
        defer { robot.close() }
        let signaling = ScriptedSignaling()
        let session = CameraSession(signaling: signaling, negotiationDeadline: Self.patience)
        session.start()
        defer { session.stop() }
        await waitUntil("subscribed") { await signaling.subscriptions == 1 }

        try await signaling.deliver(.offer(sessionID: "s1", sdp: robot.offer()))
        await waitUntil("the session answers") { await signaling.answers == 1 }
        await waitUntil("the offer's video track reaches the session") { session.videoTrack != nil }

        #expect(session.phase == .connecting)
        #expect(robot.connectionState == .new)
    }

    @Test("a stream is declared once the robot's peer connects")
    func connectedPeerIsAStream() async throws {
        let robot = LoopbackRobot()
        defer { robot.close() }
        let signaling = ScriptedSignaling()
        let wire = SignalingWire(signaling: signaling, robot: robot)
        await wire.connect()
        defer { wire.cut() }
        let session = CameraSession(signaling: signaling, negotiationDeadline: Self.patience)
        session.start()
        defer { session.stop() }
        await waitUntil("subscribed") { await signaling.subscriptions == 1 }

        try await signaling.deliver(.offer(sessionID: "s1", sdp: robot.offer()))
        await waitUntil("the session streams") { session.phase == .streaming }
        await waitUntil("the robot connects") { robot.connectionState == .connected }
        await waitUntil("the control channel opens") { session.dataChannel.isOpen }
    }

    /// Two lost answers in a row: the first attempt is started over from the top — a new
    /// subscription and a new robot peer, as `webrtcsink` builds one per session — and
    /// the second is reported instead of retried for ever.
    @Test("an answer lost twice is retried once, then reported")
    func lostTwiceIsReported() async throws {
        // Offers made up front, so each lands inside the attempt it is meant for.
        let first = LoopbackRobot()
        defer { first.close() }
        let second = LoopbackRobot()
        defer { second.close() }
        let offers = try await (first.offer(), second.offer())
        let signaling = ScriptedSignaling()
        let session = CameraSession(signaling: signaling, negotiationDeadline: Self.stall)
        session.start()
        defer { session.stop() }
        await waitUntil("subscribed") { await signaling.subscriptions == 1 }

        await signaling.deliver(.offer(sessionID: "s1", sdp: offers.0))
        await waitUntil("the first attempt is started over") { await signaling.subscriptions == 2 }
        #expect(session.phase == .connecting)

        await signaling.deliver(.offer(sessionID: "s2", sdp: offers.1))
        await waitUntil("the second stall is reported") { session.phase == .stalled }

        #expect(await signaling.answers == 2)
        // A reported stall is the end of asking: no third subscription follows it.
        try await Task.sleep(for: Self.stall * 3)
        #expect(await signaling.subscriptions == 2)
        #expect(session.phase == .stalled)
    }

    /// No offer at all is the same stall from an earlier step, and the LAN has nothing
    /// else to end it: the robot reports a stuck peer to central only.
    @Test("an offer that never comes is a stall too")
    func missingOfferIsAStall() async {
        let signaling = ScriptedSignaling()
        let session = CameraSession(signaling: signaling, negotiationDeadline: Self.stall)
        session.start()
        defer { session.stop() }
        await waitUntil("subscribed") { await signaling.subscriptions == 1 }

        await waitUntil("the stall is reported") { session.phase == .stalled }
        #expect(await signaling.subscriptions == 2)
    }

    @Test("a retry that gets through streams, and refills the budget")
    func retryThatConnects() async throws {
        let lost = LoopbackRobot()
        defer { lost.close() }
        let lostOffer = try await lost.offer()
        let signaling = ScriptedSignaling()
        let session = CameraSession(signaling: signaling, negotiationDeadline: Self.stall)
        session.start()
        defer { session.stop() }
        // Read when an attempt is armed: the first already has the short deadline, and
        // the retry it stalls into gets this one.
        session.negotiationDeadline = Self.patience
        await waitUntil("subscribed") { await signaling.subscriptions == 1 }

        await signaling.deliver(.offer(sessionID: "s1", sdp: lostOffer))
        await waitUntil("the first attempt is started over") { await signaling.subscriptions == 2 }

        let robot = LoopbackRobot()
        defer { robot.close() }
        let wire = SignalingWire(signaling: signaling, robot: robot)
        await wire.connect()
        defer { wire.cut() }
        try await signaling.deliver(.offer(sessionID: "s2", sdp: robot.offer()))
        await waitUntil("the retry streams") { session.phase == .streaming }
        #expect(session.stalledAttempts == 0)
    }

    @Test("trying again after a reported stall starts over, and can stream")
    func retryAfterAStall() async throws {
        let signaling = ScriptedSignaling()
        let session = CameraSession(signaling: signaling, negotiationDeadline: Self.stall)
        session.start()
        defer { session.stop() }
        await waitUntil("subscribed") { await signaling.subscriptions == 1 }
        await waitUntil("the stall is reported") { session.phase == .stalled }

        session.negotiationDeadline = Self.patience
        session.retry()
        #expect(session.phase == .connecting)
        await waitUntil("a fresh subscription") { await signaling.subscriptions == 3 }

        let robot = LoopbackRobot()
        defer { robot.close() }
        let wire = SignalingWire(signaling: signaling, robot: robot)
        await wire.connect()
        defer { wire.cut() }
        try await signaling.deliver(.offer(sessionID: "s3", sdp: robot.offer()))
        await waitUntil("the retry streams") { session.phase == .streaming }
    }

    /// The robot saying it has nothing to stream is an answer, not a stall — waiting on
    /// it is honest, and restarting would only ask the same question again.
    @Test("waiting for a producer is not a stall")
    func waitingIsNotAStall() async throws {
        let signaling = ScriptedSignaling()
        let session = CameraSession(signaling: signaling, negotiationDeadline: Self.stall)
        session.start()
        defer { session.stop() }
        await waitUntil("subscribed") { await signaling.subscriptions == 1 }

        await signaling.deliver(.waitingForProducer)
        await waitUntil("the session waits") { session.phase == .waitingForProducer }
        try await Task.sleep(for: Self.stall * 3)
        #expect(session.phase == .waitingForProducer)
        #expect(await signaling.subscriptions == 1)
    }

    /// Waiting stops the clock rather than pausing it: the offer that ends a wait starts
    /// its attempt with the whole deadline, not with what was left of the one before.
    /// Measured, because the wrong branch ends in the very same stall — only sooner.
    @Test("the offer after a wait gets the whole deadline")
    func offerAfterAWaitGetsTheWholeDeadline() async throws {
        let deadline: Duration = .seconds(2)
        let robot = LoopbackRobot()
        defer { robot.close() }
        let offer = try await robot.offer()
        let signaling = ScriptedSignaling()
        let session = CameraSession(signaling: signaling, negotiationDeadline: deadline)
        session.start()
        defer { session.stop() }
        await waitUntil("subscribed") { await signaling.subscriptions == 1 }

        await signaling.deliver(.waitingForProducer)
        await waitUntil("the session waits") { session.phase == .waitingForProducer }
        try await Task.sleep(for: deadline / 2)
        let offered = ContinuousClock.now
        await signaling.deliver(.offer(sessionID: "s1", sdp: offer))
        await waitUntil("the attempt stalls") { await signaling.subscriptions == 2 }

        // A sleep is never early, so the right branch cannot come in under this.
        #expect(ContinuousClock.now - offered >= deadline)
    }

    /// A robot whose producer registers after the session started waiting — just woken,
    /// or its media server restarted — and then never offers. The wait stopped the
    /// clock, so the session request has to start it again, or nothing ends this one.
    @Test("a producer that appears late and never offers is a stall")
    func lateProducerThatNeverOffersIsAStall() async {
        let signaling = ScriptedSignaling()
        let session = CameraSession(signaling: signaling, negotiationDeadline: Self.stall)
        session.start()
        defer { session.stop() }
        await waitUntil("subscribed") { await signaling.subscriptions == 1 }

        await signaling.deliver(.waitingForProducer)
        await waitUntil("the session waits") { session.phase == .waitingForProducer }
        await signaling.deliver(.sessionRequested)
        await waitUntil("the attempt is started over") { await signaling.subscriptions == 2 }
    }

    /// Over the relay the robot's own watchdog says it first, with a reason code. That
    /// is the same stall seen from the other end, and spends the same budget.
    @Test("the robot's own watchdog over the relay counts as a stall")
    func robotWatchdogIsAStall() async {
        let signaling = ScriptedSignaling()
        let session = CameraSession(signaling: signaling, negotiationDeadline: Self.patience)
        session.start()
        defer { session.stop() }
        await waitUntil("subscribed") { await signaling.subscriptions == 1 }

        await signaling.deliver(.sessionEnded(reason: "ice_negotiation_timeout"))
        await waitUntil("the attempt is started over") { await signaling.subscriptions == 2 }
        #expect(session.phase == .connecting)

        await signaling.deliver(.sessionEnded(reason: "peer_connection_failed"))
        await waitUntil("the second is reported") { session.phase == .stalled }
    }

    /// A robot somebody else took is not stalled, and retrying is how two devices fight
    /// over it — so it is neither retried nor offered a retry.
    @Test("a refusal is reported as it was, and not retried")
    func refusalIsNotRetried() async {
        let signaling = ScriptedSignaling()
        let session = CameraSession(signaling: signaling, negotiationDeadline: Self.patience)
        session.start()
        defer { session.stop() }
        await waitUntil("subscribed") { await signaling.subscriptions == 1 }

        await signaling.deliver(.sessionEnded(reason: "install_id_takeover"))
        await waitUntil("the refusal is shown") { session.phase != .connecting }
        #expect(session.phase == .failed(RemoteSessionEnd(reason: "install_id_takeover").message))

        session.retry()
        #expect(session.phase == .failed(RemoteSessionEnd(reason: "install_id_takeover").message))
        #expect(await signaling.subscriptions == 1)
    }
}

@MainActor
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(20),
    _ condition: () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting until \(description)", sourceLocation: sourceLocation)
}
