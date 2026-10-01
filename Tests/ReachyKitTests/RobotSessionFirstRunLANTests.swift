import Foundation
@testable import ReachyKit
import Testing

/// A robot on this network, answering the handshake and nothing else the first run
/// needs — the flag is on its data channel, which the opener under test hands over.
private final class LANRobot: RobotAPIClient, @unchecked Sendable {
    let identity: RobotIdentity

    init(version: String = "1.11.0") {
        identity = RobotIdentity(hardwareID: "hw-\(UUID().uuidString)", name: "lan-robot", daemonVersion: version)
    }

    private var status: Components.Schemas.DaemonStatus {
        let json = """
        {"robot_name": "lan-robot", "state": "running", "wireless_version": true,
         "desktop_app_daemon": false, "version": "\(identity.daemonVersion ?? "")", "backend_status": null}
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

/// The first run's gate on the LAN (#169): the robot's own flag over its data channel
/// where that channel opens, this device's record where it does not, and nothing
/// asked of a robot already settled.
@MainActor
@Suite("First run on the LAN", .timeLimit(.minutes(1)))
struct RobotSessionFirstRunLANTests {
    private let records = FirstRunRecordStore(defaults: UserDefaults(suiteName: "first-run-\(UUID().uuidString)")!)

    private final class Opener {
        private(set) var opened: [RobotAddress] = []
        let channel: FakeDataChannel?

        /// `completed: nil` is a channel that never opened.
        init(completed: Bool?) {
            channel = completed.map { completed in
                FakeDataChannel(replies: [
                    "get_first_wake_up": #"{"command":"get_first_wake_up","is_completed":\#(completed)}"#,
                    "set_first_wake_up": #"{"command":"set_first_wake_up","status":"ok","is_completed":true}"#,
                ])
            }
        }

        func open(_ address: RobotAddress) -> (any FirstWakeUpClient)? {
            opened.append(address)
            return channel.map { RemoteRobotConnection(channel: $0, timeout: .seconds(5)) }
        }

        func sent(_ command: String) -> Int {
            channel?.sent.count(where: { $0.contains(#""type":"\#(command)""#) }) ?? 0
        }
    }

    private func connect(
        _ robot: LANRobot,
        opener: Opener?
    ) async -> RobotSession {
        let session = RobotSession { _ in robot }
        session.firstRunServices = FirstRunServices(
            openLANChannel: opener.map { opener in { @MainActor address in opener.open(address) } },
            records: records
        )
        await session.connect(to: RobotAddress(host: "192.168.1.77"))
        return session
    }

    // MARK: - The robot's own flag

    @Test("a robot whose channel says it was never woken is offered the run, and finishing writes the flag")
    func readsTheFlagOverTheChannel() async {
        let robot = LANRobot()
        let opener = Opener(completed: false)
        let session = await connect(robot, opener: opener)

        #expect(session.offersFirstRun)
        #expect(opener.opened == [RobotAddress(host: "192.168.1.77")])
        #expect(records.state(for: robot.identity.deduplicationKey) == .pending)

        await session.finishFirstRun()

        #expect(opener.sent("set_first_wake_up") == 1)
        #expect(records.state(for: robot.identity.deduplicationKey) == .settled)
    }

    /// Set up in Pollen's app, or by this app on another device: the robot says so, and
    /// this device remembers, so the channel is opened once rather than on every connect.
    @Test("a robot whose channel says it was woken is settled and never asked again")
    func settlesAMarkedRobot() async {
        let robot = LANRobot()
        let opener = Opener(completed: true)
        let first = await connect(robot, opener: opener)
        #expect(!first.offersFirstRun)

        let second = await connect(robot, opener: opener)

        #expect(!second.offersFirstRun)
        #expect(opener.opened.count == 1)
    }

    // MARK: - When the channel does not open

    @Test("a robot this device has never met is offered the run on its own record")
    func fallsBackForANewRobot() async {
        let robot = LANRobot()
        let session = await connect(robot, opener: Opener(completed: nil))

        #expect(session.offersFirstRun)

        await session.finishFirstRun()

        #expect(records.state(for: robot.identity.deduplicationKey) == .settled)
    }

    /// Met before and never offered: set up already as far as this device can tell —
    /// and not worth an eight-second channel that did not open on every connect.
    @Test("a robot this device has met before is settled, not greeted")
    func settlesAKnownRobot() async {
        let robot = LANRobot()
        KnownRobots.remember(identity: robot.identity, address: RobotAddress(host: "192.168.1.77"))
        let opener = Opener(completed: nil)

        let session = await connect(robot, opener: opener)

        #expect(!session.offersFirstRun)
        #expect(records.state(for: robot.identity.deduplicationKey) == .settled)
        _ = await connect(robot, opener: opener)
        #expect(opener.opened.count == 1)
    }

    /// A disconnect halfway through is not a finish, and the next connect knows the robot
    /// by then — so the pending record is what brings the run back.
    @Test("a run abandoned halfway is offered again on the next connect")
    func resumesAnAbandonedRun() async {
        let robot = LANRobot()
        let opener = Opener(completed: nil)
        let first = await connect(robot, opener: opener)
        #expect(first.offersFirstRun)
        first.disconnect()

        let second = await connect(robot, opener: opener)

        #expect(second.offersFirstRun)
    }

    @Test("a robot set up over Bluetooth a moment ago is new, even to a device that knew it")
    func treatsAProvisionedRobotAsNew() async {
        let robot = LANRobot()
        KnownRobots.remember(identity: robot.identity, address: RobotAddress(host: "192.168.1.77"))
        KnownRobots.pendingProvisionedHardwareID = robot.identity.hardwareID
        defer {
            if KnownRobots.pendingProvisionedHardwareID == robot.identity.hardwareID {
                KnownRobots.pendingProvisionedHardwareID = nil
            }
        }

        let session = await connect(robot, opener: Opener(completed: nil))

        #expect(session.offersFirstRun)
    }

    // MARK: - What is never asked

    /// 1.9.x has no such command on its channel; a peer connection to ask it would only
    /// sit out the reply budget, so its record decides on its own.
    @Test("a daemon before 1.10.0 opens no channel and goes by its record")
    func skipsTheChannelOnAnOlderDaemon() async {
        let robot = LANRobot(version: "1.9.0")
        let opener = Opener(completed: false)

        let session = await connect(robot, opener: opener)

        #expect(opener.opened.isEmpty)
        #expect(session.offersFirstRun, "a robot new to this device")
    }

    @Test("with no way to open a channel, the LAN offers no first run")
    func needsAnOpener() async {
        let session = await connect(LANRobot(), opener: nil)

        #expect(!session.offersFirstRun)
    }
}
