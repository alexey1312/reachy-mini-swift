import ReachyKit
@testable import ReachyMedia
import Testing

/// Which hang-up reason the session hands its carrier.
///
/// The relay passes it to the robot, and from daemon 1.13.0 the robot keeps a live
/// session whose `endSession` carries none — so the attempt that follows a stall was
/// refused as busy. The words are the carrier's (`SignalingHangUp`); what is tested
/// here is that a stop and a restart are told apart.
@MainActor
@Suite("Camera session hang-ups", .serialized, .timeLimit(.minutes(1)))
struct CameraSessionHangUpTests {
    @Test("stopping hangs up as a stop")
    func stopIsAStop() async {
        let signaling = ScriptedSignaling()
        let session = CameraSession(signaling: signaling, negotiationDeadline: .seconds(30))
        session.start()
        await waitUntil("subscribed") { await signaling.subscriptions == 1 }

        session.stop()

        await waitUntil("hung up") { await signaling.disconnects == 1 }
        #expect(await signaling.hangUps == [.stop])
    }

    /// A stall starts the attempt over at once, so the robot must let the old
    /// session go before the new request reaches it.
    @Test("a stalled attempt hangs up to redial")
    func stallIsARedial() async {
        let signaling = ScriptedSignaling()
        let session = CameraSession(signaling: signaling, negotiationDeadline: .milliseconds(400))
        session.start()
        defer { session.stop() }
        await waitUntil("subscribed") { await signaling.subscriptions == 1 }

        await waitUntil("the attempt started over") { await signaling.subscriptions == 2 }

        #expect(await signaling.hangUps.first == .redial)
    }
}
