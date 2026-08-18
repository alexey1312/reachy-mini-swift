import Foundation
@testable import ReachyKit
import Testing

/// Which kind of robot answered, derived from the status alone.
///
/// The whole point of `flavour` is that a Lite robot and a simulator have no
/// transport of their own — both are the daemon on somebody's computer, reached
/// over the same HTTP as a Wireless unit — so nothing about the link may reach this
/// answer except the one case where the link *is* the answer.
@MainActor
@Suite("Daemon flavour")
struct DaemonFlavourTests {
    @Test("a robot running its own daemon is Wireless")
    func wireless() {
        let session = RobotSession.preview(status: .preview(wirelessVersion: true))

        #expect(session.flavour == .wireless)
    }

    /// The one the daemon never states positively: a Lite unit is what is left once
    /// simulation and `--wireless-version` are both ruled out.
    @Test("no wireless routes and no simulation is a Lite robot")
    func lite() {
        let session = RobotSession.preview(status: .preview(wirelessVersion: false))

        #expect(session.flavour == .lite)
    }

    @Test("MuJoCo reports itself")
    func simulation() {
        let session = RobotSession.preview(status: .preview(wirelessVersion: false, simulationEnabled: true))

        #expect(session.flavour == .simulation)
    }

    /// `Daemon.start` assigns the two simulation flags from independent argparse
    /// flags, so a daemon given both is representable and the tie-break has to be
    /// stated rather than left to whichever branch happens to come first.
    @Test("mockup wins over MuJoCo when a daemon reports both")
    func mockupWinsTheTieBreak() {
        let session = RobotSession.preview(
            status: .preview(wirelessVersion: false, simulationEnabled: true, mockupSimEnabled: true)
        )

        #expect(session.flavour == .mockup)
    }

    /// `RemoteRobotConnection` synthesises its status with `wireless_version: false`
    /// on purpose — it is what keeps `/wifi/*` and `/update/*` closed over a link
    /// that cannot reach them — and that is indistinguishable from a Lite unit. So
    /// the link has to be consulted first, and this is the test that says so: swap
    /// the two checks and it reports `.lite`.
    @Test("a relayed session is named by its link, not by its status")
    func remoteBeatsTheLiteFallback() {
        let session = RobotSession.preview(
            status: .preview(wirelessVersion: false),
            address: nil,
            link: .remote
        )

        #expect(session.flavour == .remote)
    }

    /// Before a handshake there is nothing to answer with, and guessing would put a
    /// model name on a screen for a robot that has not spoken.
    @Test("no status yet is no answer")
    func unknownBeforeAHandshake() {
        let session = RobotSession.preview(status: nil, address: nil)

        #expect(session.flavour == nil)
    }

    /// The `filter` is bound before the assertion rather than inlined into it:
    /// `rethrows` inside a `#expect` expansion fails to compile as "call can throw,
    /// but it is not marked with 'try'", pointing at generated code — and
    /// swiftformat's `preferKeyPath` is what puts the key path there in the first
    /// place, so undoing it by hand is a loop. See the root `AGENTS.md`.
    @Test("Lite and both simulators run on a computer; a Wireless robot and the relay do not")
    func runsOnAComputer() {
        let onAComputer = DaemonFlavour.allCases.filter(\.runsOnAComputer)

        #expect(onAComputer == [.lite, .simulation, .mockup])
    }
}
