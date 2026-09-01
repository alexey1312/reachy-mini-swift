import Foundation
@testable import ReachyKit
import Testing

/// A daemon that is already reachable — the shape a remote session arrives in,
/// where the transport was built before the session ever saw it.
/// The relay's actual apps shape: `apps.status`, `apps.start` and `apps.stop` on the
/// data channel, and no catalogue route. This is the only client where the two apps
/// flags disagree, which is the whole reason they are two.
private final class RunningAppOnlyClient: RobotAPIClient, RobotAppsClient, @unchecked Sendable {
    let identity = RobotIdentity(hardwareID: "hw-relay", name: "kitchen", daemonVersion: "1.10.0")
    private let version: String?

    init(version: String? = "1.10.0") {
        self.version = version
    }

    var offersAppStore: Bool {
        false
    }

    func handshake() async throws -> RobotConnection.Handshake {
        try await RobotConnection.Handshake(identity: identity, status: daemonStatus())
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        .preview(state: .running, wirelessVersion: false, version: version)
    }

    func wakeUp() async throws -> String {
        ""
    }

    func gotoSleep() async throws -> String {
        ""
    }
}

private final class SuppliedClient: RobotAPIClient, @unchecked Sendable {
    let identity = RobotIdentity(hardwareID: "hw-remote", name: "kitchen", daemonVersion: "1.9.0")
    private let handshakeFailure: (any Error)?

    init(handshakeFailure: (any Error)? = nil) {
        self.handshakeFailure = handshakeFailure
    }

    func handshake() async throws -> RobotConnection.Handshake {
        if let handshakeFailure {
            throw handshakeFailure
        }
        return try await RobotConnection.Handshake(identity: identity, status: daemonStatus())
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        if let handshakeFailure {
            throw handshakeFailure
        }
        return .preview(state: .running, wirelessVersion: false)
    }

    func wakeUp() async throws -> String {
        ""
    }

    func gotoSleep() async throws -> String {
        ""
    }
}

@MainActor
@Suite("Remote connect", .timeLimit(.minutes(1)))
struct RobotSessionRemoteConnectTests {
    private func session() -> RobotSession {
        // The address factory is never reached on this path, and saying so beats
        // a stub that quietly stands in for one.
        RobotSession { _ in
            Issue.record("a supplied client must not be rebuilt from an address")
            throw ReachyKitError.wirelessFeaturesUnavailable
        }
    }

    /// The whole point: over the relay there is no address to dial, and the
    /// client is built from a data channel long before the session sees it.
    @Test("a session connects with a client it was handed, and no address")
    func connectsWithoutAnAddress() async {
        let session = session()

        let connected = await session.connect(using: SuppliedClient())

        #expect(connected)
        #expect(session.phase == .connected(RobotIdentity(
            hardwareID: "hw-remote",
            name: "kitchen",
            daemonVersion: "1.9.0"
        )))
        #expect(session.address == nil)
    }

    /// A remote attempt is always a deliberate one — the user picked the robot off
    /// a list — so its failure has to be shown. Reporting it only when there is an
    /// address to show would swallow every remote failure there is.
    @Test("a remote failure lands on the failed step rather than back on idle")
    func showsARemoteFailure() async {
        let session = session()

        let connected = await session.connect(
            using: SuppliedClient(handshakeFailure: ReachyKitError.daemonRejected(statusCode: 503))
        )

        #expect(!connected)
        guard case let .connecting(.failed(stage, message)) = session.phase else {
            Issue.record("expected a failed step, got \(session.phase)")
            return
        }
        #expect(stage == .connect)
        #expect(!message.isEmpty)
        #expect(session.robotError == message)
    }

    /// Disconnect suppresses discovery-driven reconnect, and picking a robot out of
    /// the remote list is as explicit as typing an address — it has to lift that.
    @Test("connecting remotely re-allows automatic connection")
    func liftsTheDisconnectLatch() async {
        let session = session()
        session.disconnect()
        #expect(!session.automaticConnectionAllowed)

        await session.connect(using: SuppliedClient())

        #expect(session.automaticConnectionAllowed)
    }

    /// The session's own surface has to keep working: the client it was handed is
    /// the one every later command goes through.
    @Test("the supplied client backs the session's commands")
    func keepsTheSuppliedClient() async {
        let session = session()

        await session.connect(using: SuppliedClient())

        #expect(session.lastStatus?.state == .running)
        #expect(session.canConfigureWiFi == false)
    }

    /// `address == nil` used to be the only record that this was a relay session,
    /// and three screens read it as "no robot". The link says which it is.
    @Test("a remote session names its link")
    func namesTheLink() async {
        let session = session()

        await session.connect(using: SuppliedClient())

        #expect(session.link == .remote)
        #expect(session.isRemote)
        #expect(session.address == nil)
    }

    /// The whole point of the change, as one table. Everything the data channel
    /// genuinely does not carry still answers `false`; what it does carry no
    /// longer answers `false` merely because there is no address.
    @Test("a remote session reports the capabilities it actually has")
    func reportsRemoteCapabilities() async {
        let session = session()

        await session.connect(using: SuppliedClient())

        // Carried by this connection.
        #expect(session.hasCamera)
        // Genuinely not carried — an honest subset, not a facade.
        #expect(!session.canManageApps)
        #expect(!session.canConfigureWiFi)
        #expect(!session.canUpdateDaemon)
        #expect(!session.canLinkHuggingFace)
        // The one that moved: the scene needs a shape and a pose, and neither has
        // to come off the robot's own network any more.
        #expect(session.canRenderScene)
        #expect(!session.canPlayMoves)
        // `SuppliedClient` is a bare `RobotAPIClient`, so it speaks neither of the
        // two new protocols — `RemoteRobotConnection` is what conforms, and its own
        // suite covers that. What matters here is that the session asks the client
        // rather than the address.
        #expect(!session.canReadDaemonLogs)
        #expect(!session.canTeleoperate)
    }

    /// The two apps flags read the same client and must still disagree: conformance
    /// answers "the running app can be watched", `offersAppStore` answers "there is
    /// a catalogue". Every double in the repository takes the protocol default for
    /// the second, so without this client the two are indistinguishable and either
    /// one can be reverted into the other with the suite still green.
    @Test("the relay can watch the running app without offering a store")
    func separatesTheStoreFromTheRunningApp() async {
        let session = session()

        await session.connect(using: RunningAppOnlyClient())

        #expect(!session.canManageApps)
        #expect(session.canControlRunningApp)
    }

    /// `apps.*` arrived in daemon 1.10.0 and 1.9.0 is still the minimum, so a
    /// relayed robot on the older one carries the conformance and answers none of
    /// the three. Polling it costs a full reply budget per tick and reports nothing.
    @Test("a relayed daemon older than the commands is not offered them")
    func withholdsRelayCommandsFromAnOlderDaemon() async {
        let session = session()

        await session.connect(using: RunningAppOnlyClient(version: "1.9.0"))

        #expect(!session.canControlRunningApp)
    }

    /// Withheld on evidence, never on the absence of it: a version this client
    /// cannot read leaves the feature offered rather than hidden.
    @Test("an unreadable version leaves the relay commands offered")
    func offersRelayCommandsWhenTheVersionIsUnknown() async {
        let session = session()

        await session.connect(using: RunningAppOnlyClient(version: nil))

        #expect(session.canControlRunningApp)
    }

    /// A LAN session is the control: the same flags, answered the other way.
    @Test("a local session reports the capabilities a remote one lacks")
    func reportsLocalCapabilities() {
        let session = RobotSession.preview()

        #expect(session.canRenderScene)
        #expect(session.canPlayMoves)
        #expect(session.link == .lan(RobotAddress(host: "192.168.1.42")))
        #expect(!session.isRemote)
    }

    @Test("disconnecting clears the link")
    func clearsTheLink() async {
        let session = session()
        await session.connect(using: SuppliedClient())

        session.disconnect()

        #expect(session.link == .none)
        #expect(session.address == nil)
    }
}
