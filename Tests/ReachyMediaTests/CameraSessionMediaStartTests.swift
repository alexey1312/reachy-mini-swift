import ReachyKit
@testable import ReachyMedia
import Testing

/// An acquire that the robot answers with a pipeline that did not start (daemon 1.15.0,
/// pollen-robotics/reachy_mini#1567). Beside `CameraSessionNegotiationTests` because that
/// file reached SwiftLint's length limits.
@MainActor
@Suite("Camera session media start", .serialized, .timeLimit(.minutes(1)))
struct CameraSessionMediaStartTests {
    private static let stall: Duration = .milliseconds(400)
    private static let patience: Duration = .seconds(30)

    /// Daemon 1.15.0 answers the acquire with 500 when its pipeline does not start
    /// (pollen-robotics/reachy_mini#1567). That is the robot's verdict, at once, so the
    /// session reports it rather than spend two deadlines on a producer that is not there.
    /// The deadline here is the long one: a stall could not reach this phase in time.
    @Test("a pipeline that did not start is reported at once, with nothing subscribed")
    func pipelineThatDidNotStartIsReported() async {
        let acquirer = CountingAcquirer(refusing: [ReachyKitError.mediaDidNotStart])
        let signaling = ScriptedSignaling()
        let session = CameraSession(signaling: signaling, negotiationDeadline: Self.patience, connection: acquirer)
        session.probeDelay = Self.stall
        session.start()
        defer { session.stop() }

        await waitUntil("reported") { session.phase == .mediaDidNotStart }
        #expect(await signaling.subscriptions == 0)
        #expect(await acquirer.calls == 1)
        // No deadline and no probe: only an acquire starts that pipeline again, and a
        // probe does not send one.
        #expect(session.deadlineTask == nil)
    }

    @Test("trying again after a pipeline that did not start acquires again")
    func retryAfterAPipelineThatDidNotStart() async {
        let acquirer = CountingAcquirer(refusing: [ReachyKitError.mediaDidNotStart])
        let signaling = ScriptedSignaling()
        let session = CameraSession(signaling: signaling, negotiationDeadline: Self.patience, connection: acquirer)
        session.start()
        defer { session.stop() }
        await waitUntil("reported") { session.phase == .mediaDidNotStart }

        session.retry()
        await waitUntil("a subscription") { await signaling.subscriptions == 1 }
        #expect(await acquirer.calls == 2)
        #expect(session.phase == .connecting)
    }

    /// Before 1.15.0 a failed acquire said nothing about the pipeline, and a request
    /// that times out still says nothing: the session asks for a session all the same.
    @Test("any other failure of the acquire still asks for a session")
    func otherAcquireFailuresStillSubscribe() async {
        let acquirer = CountingAcquirer(refusing: [ReachyKitError.daemonRejected(statusCode: 503)])
        let signaling = ScriptedSignaling()
        let session = CameraSession(signaling: signaling, negotiationDeadline: Self.patience, connection: acquirer)
        session.start()
        defer { session.stop() }

        await waitUntil("subscribed") { await signaling.subscriptions == 1 }
        #expect(session.phase == .connecting)
    }
}
