import Foundation
@testable import ReachyKit
import Testing

/// A daemon below the baseline used to throw out of the handshake, leaving the user
/// on a "Try again" button that could never work. It is now a halt the update flow
/// can act on — while ADR 0001 still forbids sending that daemon any command.
private final class OldDaemonClient: RobotAPIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    private let version: String
    private let wireless: Bool

    init(version: String, wireless: Bool = true) {
        self.version = version
        self.wireless = wireless
    }

    var sentCommands: [String] {
        lock.withLock { commands }
    }

    private var status: Components.Schemas.DaemonStatus {
        let json = """
        {"robot_name": "testbot", "state": "running", "wireless_version": \(wireless),
         "desktop_app_daemon": false, "version": "\(version)",
         "backend_status": {"ready": true, "motor_control_mode": "enabled",
                            "last_alive": null, "control_loop_stats": {}}}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Components.Schemas.DaemonStatus.self, from: Data(json.utf8))
    }

    func handshake() async throws -> RobotConnection.Handshake {
        .init(
            identity: RobotIdentity(hardwareID: "hw-1", name: "testbot", daemonVersion: version),
            status: status
        )
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        status
    }

    func setMotorMode(_ mode: Components.Schemas.MotorControlMode) async throws {
        lock.withLock { commands.append("setMotorMode(\(mode.rawValue))") }
    }

    func wakeUp() async throws -> String {
        lock.withLock { commands.append("wakeUp") }
        return "uuid"
    }

    func gotoSleep() async throws -> String {
        lock.withLock { commands.append("gotoSleep") }
        return "uuid"
    }

    func volume() async throws -> AudioLevel {
        lock.withLock { commands.append("volume") }
        return AudioLevel(percent: 50, platform: "test", device: "test")
    }
}

@MainActor
@Suite("RobotSession compatibility gate")
struct RobotSessionCompatibilityGateTests {
    private func makeSession(_ client: OldDaemonClient) -> RobotSession {
        RobotSession { _ in client }
    }

    private func requirement(of session: RobotSession) -> DaemonUpdateRequirement? {
        guard case let .connecting(.needsDaemonUpdate(_, requirement)) = session.phase else { return nil }
        return requirement
    }

    @Test("an old daemon halts on the update step instead of failing the connection")
    func haltsRatherThanFailing() async {
        let session = makeSession(OldDaemonClient(version: "1.8.0"))

        let connected = await session.connect(to: RobotAddress(host: "10.0.0.9"))

        #expect(connected == false)
        #expect(requirement(of: session) == DaemonUpdateRequirement(
            reported: "1.8.0",
            minimum: DaemonCompatibilityPolicy.minimumVersion,
            canSelfUpdate: true
        ))
    }

    @Test("a Lite robot never mounts /update/*, so the halt says it cannot update itself")
    func reportsThatALiteRobotCannotSelfUpdate() async {
        let session = makeSession(OldDaemonClient(version: "1.8.0", wireless: false))

        await session.connect(to: RobotAddress(host: "10.0.0.9"))

        #expect(requirement(of: session)?.canSelfUpdate == false)
    }

    @Test("the halt latches on an automatic attempt too, so the rescan stops hammering the robot")
    func latchesOnAutomaticAttempts() async {
        let session = makeSession(OldDaemonClient(version: "1.8.0"))

        await session.connect(to: RobotAddress(host: "10.0.0.9"), automatically: true)

        #expect(session.phase != .idle)
        #expect(requirement(of: session) != nil)
    }

    @Test("connect itself succeeded, so only the version step asks for attention")
    func projectsOntoTheStepper() async {
        let session = makeSession(OldDaemonClient(version: "1.8.0"))

        await session.connect(to: RobotAddress(host: "10.0.0.9"))

        #expect(session.phase.outcome(for: .connect) == .done)
        #expect(session.phase.outcome(for: .compatibility) == .attention)
        #expect(session.phase.outcome(for: .backend) == .pending)
    }

    @Test("ADR 0001: no command reaches an unsupported daemon, whatever the navigation allows")
    func refusesEveryCommand() async {
        let client = OldDaemonClient(version: "1.8.0")
        let session = makeSession(client)
        await session.connect(to: RobotAddress(host: "10.0.0.9"))

        await session.wake()
        await session.sleep()
        _ = try? await session.volume()

        #expect(client.sentCommands.isEmpty)
        #expect(session.robotError?.contains("1.8.0") == true)
    }

    @Test("a supported daemon is unaffected — the gate only fires below the baseline")
    func letsASupportedDaemonThrough() async {
        let session = makeSession(OldDaemonClient(version: DaemonCompatibilityPolicy.minimumVersion))

        let connected = await session.connect(to: RobotAddress(host: "10.0.0.9"))

        #expect(connected)
        #expect(requirement(of: session) == nil)
    }
}

@MainActor
@Suite("Pre-release channel readiness")
struct PreReleaseReadinessTests {
    @Test("a daemon below 1.10.0 has the beta channel closed to it")
    func closedBelowTheRankingFix() {
        let session = RobotSession.preview(status: .preview(version: "1.9.0"))
        #expect(session.lastStatus?.version == "1.9.0")
        #expect(session.refusesPreReleaseUpdates)
    }

    @Test("1.10.0 and its release candidates can take a pre-release", arguments: ["1.10.0", "1.10.0rc5", "1.11.0"])
    func openFromTheRankingFix(version: String) {
        #expect(RobotSession.preview(status: .preview(version: version)).refusesPreReleaseUpdates == false)
    }

    /// A daemon that reported no version is not evidence of an old one.
    @Test("an unreported version keeps the channel open")
    func openWithoutAVersion() {
        #expect(RobotSession.preview(status: .preview()).refusesPreReleaseUpdates == false)
    }
}
