import Foundation
@testable import ReachyKit
import Testing

/// A daemon that answers the handshake as one robot and lets the connect finish.
///
/// Internal rather than private: `CandidateSweepTests` drains a queue through it.
final class AnsweringRobot: RobotAPIClient, @unchecked Sendable {
    let identity: RobotIdentity

    /// `hardwareID: nil` is the simulator, or a robot without the Pollen audio device.
    /// Two units share the default name, so the name is the same unless a test asks.
    init(hardwareID: String?, name: String = "reachy_mini") {
        identity = RobotIdentity(hardwareID: hardwareID, name: name, daemonVersion: "1.12.0")
    }

    private var status: Components.Schemas.DaemonStatus {
        let json = """
        {"robot_name": "reachy_mini", "state": "running", "wireless_version": true,
         "desktop_app_daemon": false, "version": "1.12.0", "backend_status": null}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Components.Schemas.DaemonStatus.self, from: Data(json.utf8))
    }

    func handshake() async throws -> RobotConnection.Handshake {
        .init(identity: identity, status: status)
    }

    func daemonStatus() async throws -> Components.Schemas.DaemonStatus {
        status
    }

    func wakeUp() async throws -> String {
        "uuid"
    }

    func gotoSleep() async throws -> String {
        "uuid"
    }
}

/// An automatic attempt takes back only the robot this device connected to last.
///
/// The sweep dials whatever answers. Another unit can hold `reachy-mini.local` or the
/// old DHCP lease, and both units report `reachy_mini` — a third party measured both
/// on one LAN (`docs/research/wireless-cpu-and-mdns.md`). So the session compares
/// hardware ids, and only on an automatic attempt.
@MainActor
@Suite("Automatic connect holds to the last robot", .timeLimit(.minutes(1)))
struct RobotSessionAutomaticConnectTests {
    /// A suite of its own: other suites connect against the shared store at the same time.
    private let store: KnownRobotStore
    private let oldLease = RobotAddress(host: "192.168.1.50")
    private let newLease = RobotAddress(host: "192.168.1.60")

    init() throws {
        let defaults = try #require(UserDefaults(suiteName: "RobotSessionAutomaticConnectTests.\(UUID().uuidString)"))
        store = KnownRobotStore(defaults: defaults)
    }

    /// This device connected last to `hardwareID`, at the lease it held then.
    private func remember(_ hardwareID: String?) {
        store.lastAddress = oldLease
        store.lastHardwareID = hardwareID
    }

    private func session(answeringAs robot: AnsweringRobot) -> RobotSession {
        let session = RobotSession { _ in robot }
        session.knownRobots = store
        return session
    }

    @Test("an automatic attempt passes over another robot and leaves no trace of it")
    func passesOverAnotherRobot() async {
        remember("hw-mine")
        let session = session(answeringAs: AnsweringRobot(hardwareID: "hw-other"))

        let connected = await session.connect(to: newLease, automatically: true)

        #expect(!connected)
        #expect(session.phase == .idle, "the sweep goes on to its next candidate")
        #expect(session.address == nil)
        #expect(session.robotError == nil, "another robot answering is not a failure")
        #expect(store.all.isEmpty)
        #expect(store.lastAddress == oldLease)
        #expect(store.lastHardwareID == "hw-mine")
    }

    @Test("an automatic attempt takes the last robot back at a new address")
    func takesTheLastRobotAtANewAddress() async {
        remember("hw-mine")
        let robot = AnsweringRobot(hardwareID: "hw-mine")
        let session = session(answeringAs: robot)

        let connected = await session.connect(to: newLease, automatically: true)

        #expect(connected)
        #expect(session.phase == .connected(robot.identity))
        #expect(store.lastAddress == newLease)
        session.disconnect()
    }

    /// The simulator on loopback, or a unit without the audio board: nil cannot match.
    @Test("a daemon with no hardware id cannot stand in for the last robot")
    func aDaemonWithNoHardwareIDIsPassedOver() async {
        remember("hw-mine")
        let session = session(answeringAs: AnsweringRobot(hardwareID: nil))

        let connected = await session.connect(to: RobotAddress(host: "127.0.0.1"), automatically: true)

        #expect(!connected)
        #expect(session.phase == .idle)
        #expect(store.all.isEmpty)
        #expect(store.lastHardwareID == "hw-mine")
    }

    @Test("a device that has met no robot takes the first one that answers")
    func takesAnyRobotWithNothingRemembered() async {
        let robot = AnsweringRobot(hardwareID: "hw-first")
        let session = session(answeringAs: robot)

        let connected = await session.connect(to: newLease, automatically: true)

        #expect(connected)
        #expect(session.phase == .connected(robot.identity))
        #expect(store.lastHardwareID == "hw-first", "the robot it took is the one held to from now on")
        session.disconnect()
    }

    /// The simulator keeps working for whoever uses it: connecting to it by hand
    /// clears the hold, and nothing is held until a robot with an id answers.
    @Test("after a robot with no hardware id, an automatic attempt takes whoever answers")
    func aRobotWithNoHardwareIDHoldsNothing() async {
        remember("hw-mine")
        let simulator = session(answeringAs: AnsweringRobot(hardwareID: nil))
        #expect(await simulator.connect(to: RobotAddress(host: "127.0.0.1")))
        simulator.disconnect()
        #expect(store.lastHardwareID == nil)

        let robot = AnsweringRobot(hardwareID: "hw-other")
        let session = session(answeringAs: robot)
        let connected = await session.connect(to: newLease, automatically: true)

        #expect(connected)
        #expect(session.phase == .connected(robot.identity))
        session.disconnect()
    }

    @Test("a manual connect is never held, and moves the hold to the robot it reached")
    func aManualConnectMovesTheHold() async {
        remember("hw-mine")
        let robot = AnsweringRobot(hardwareID: "hw-other")
        let session = session(answeringAs: robot)

        let connected = await session.connect(to: newLease)

        #expect(connected)
        #expect(session.phase == .connected(robot.identity))
        #expect(store.lastHardwareID == "hw-other")
        session.disconnect()
    }

    /// The onboarding hands its address to the sweep, so this attempt is automatic too.
    @Test("a robot set up over Bluetooth a moment ago is taken automatically")
    func takesARobotJustProvisioned() async {
        remember("hw-mine")
        store.pendingProvisionedHardwareID = "hw-new"
        let robot = AnsweringRobot(hardwareID: "hw-new")
        let session = session(answeringAs: robot)

        let connected = await session.connect(to: newLease, automatically: true)

        #expect(connected)
        #expect(session.phase == .connected(robot.identity))
        #expect(store.pendingProvisionedHardwareID == nil)
        #expect(store.lastHardwareID == "hw-new")
        session.disconnect()
    }
}
