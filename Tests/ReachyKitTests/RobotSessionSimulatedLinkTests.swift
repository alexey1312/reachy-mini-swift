import Foundation
@testable import ReachyKit
import Testing

/// A simulator that is already answering — the shape `connect(simulating:)` takes,
/// where there is no transport at all and never was.
private final class SimulatedStubClient: RobotAPIClient, @unchecked Sendable {
    let identity = RobotIdentity(hardwareID: nil, name: "Simulator", daemonVersion: "1.9.0")

    func handshake() async throws -> RobotConnection.Handshake {
        try await RobotConnection.Handshake(identity: identity, status: daemonStatus())
    }

    /// What a native Swift simulator can honestly claim: no physics, no
    /// `--wireless-version` routes, and — unlike the Python daemon's own `--sim`,
    /// which names `"mujoco"` — no camera specs at all, because there is no media
    /// server to name one.
    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        .preview(
            state: .running,
            wirelessVersion: false,
            mockupSimEnabled: true,
            cameraSpecsName: ""
        )
    }

    func wakeUp() async throws -> String {
        ""
    }

    func gotoSleep() async throws -> String {
        ""
    }
}

/// What separates a simulated session from a relayed one.
///
/// Both arrive with a client built elsewhere and neither has an address, so
/// `connect(using:)` was the obvious way in — and it hardcodes `.remote`, which is
/// the one word that would have got both facts below wrong.
@MainActor
@Suite("Simulated link", .timeLimit(.minutes(1)))
struct RobotSessionSimulatedLinkTests {
    private func session() -> RobotSession {
        RobotSession { _ in
            Issue.record("a supplied client must not be rebuilt from an address")
            throw ReachyKitError.wirelessFeaturesUnavailable
        }
    }

    @Test("connecting to a simulator takes the simulated link, not the remote one")
    func connectsOverTheSimulatedLink() async {
        let session = session()

        let connected = await session.connect(simulating: SimulatedStubClient())

        #expect(connected)
        #expect(session.link == .simulated)
        #expect(session.isRemote == false)
        #expect(session.address == nil)
    }

    /// The regression `.remote` would have shipped: `hasCamera` reads `isRemote`
    /// first, because a relay session carries its video on the same peer connection
    /// as its commands. A simulator carries nothing, and the tab would have opened
    /// over a stream that does not exist.
    @Test("a simulated session offers no camera")
    func offersNoCamera() async {
        let session = session()

        await session.connect(simulating: SimulatedStubClient())

        #expect(session.hasCamera == false)
    }

    /// The second one: `flavour` answers `.remote` before it looks at the status at
    /// all, so the caption would have read "Hugging Face relay" over a robot that
    /// never touched one. Through the simulated link the status is consulted, and
    /// it says mockup.
    @Test("a simulated session is named for what it is")
    func namesItselfMockup() async {
        let session = session()

        await session.connect(simulating: SimulatedStubClient())

        #expect(session.flavour == .mockup)
    }

    /// Unchanged by the split, and worth pinning: the relay path still takes the
    /// link it always did.
    @Test("a supplied client with no simulation still connects as remote")
    func suppliedClientStaysRemote() async {
        let session = session()

        await session.connect(using: SimulatedStubClient())

        #expect(session.link == .remote)
        #expect(session.isRemote)
    }
}
