import Foundation
@testable import ReachyKit
import Testing

/// Central refuses and evicts with short reason codes. They are the only
/// explanation a remote user gets, and they mean genuinely different things.
@Suite("Remote session endings")
struct RemoteSessionEndTests {
    @Test("a busy robot names what is running on it")
    func namesTheActiveApp() {
        let end = RemoteSessionEnd(reason: "robot_busy", activeApp: "Hand Tracker")

        #expect(end.message.contains("Hand Tracker"))
        #expect(end.isWorthRetrying)
    }

    @Test("a busy robot with nothing named still says it is busy")
    func handlesAMissingAppName() {
        #expect(RemoteSessionEnd(reason: "robot_busy").message.localizedCaseInsensitiveContains("in use"))
    }

    /// Someone walked up to the robot and started an app on it. Retrying would
    /// take it away from them.
    @Test("a local app taking over is explained as that, and not worth retrying")
    func explainsLocalTakeover() {
        let end = RemoteSessionEnd(reason: "local_app_started")

        #expect(end.message.localizedCaseInsensitiveContains("app"))
        #expect(end.isWorthRetrying == false)
    }

    /// The same account opened the robot somewhere else. Retrying here would
    /// bounce the other device, and then it would bounce this one back.
    @Test("another device taking over is not worth retrying either")
    func explainsDeviceTakeover() {
        let end = RemoteSessionEnd(reason: "install_id_takeover")

        #expect(end.message.localizedCaseInsensitiveContains("another device"))
        #expect(end.isWorthRetrying == false)
    }

    /// The robot's negotiation watchdog ending a session is a stall, not a refusal:
    /// the camera spends its one retry on it rather than showing the code. Nothing a
    /// person did is one, or a robot somebody took would be retried out from under them.
    @Test("the robot's own negotiation watchdog is a stall; a refusal is not")
    func recognisesANegotiationStall() {
        #expect(RemoteSessionEnd(reason: "ice_negotiation_timeout").isNegotiationStall)
        #expect(RemoteSessionEnd(reason: "peer_connection_failed").isNegotiationStall)
        for refusal in ["robot_busy", "local_app_started", "install_id_takeover", "gremlins"] {
            #expect(RemoteSessionEnd(reason: refusal).isNegotiationStall == false, "\(refusal)")
        }
    }

    /// A reason a later central invents must still produce a sentence, and must
    /// carry the raw code so a bug report can name it.
    @Test("an unfamiliar reason is still shown, verbatim")
    func carriesAnUnknownReason() {
        #expect(RemoteSessionEnd(reason: "gremlins").message.contains("gremlins"))
    }
}
