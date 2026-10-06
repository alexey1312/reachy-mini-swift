import Foundation
@testable import ReachyKit
import Testing

/// A robot on this network, answering the handshake and nothing else the first run
/// needs — the flag is on its data channel, which the opener under test hands over.
private final class LANRobot: RobotAPIClient, @unchecked Sendable {
    let identity: RobotIdentity

    /// `hardwareID: nil` is the simulator, or a robot without the Pollen audio device.
    init(version: String = "1.11.0", hardwareID: String? = "hw-\(UUID().uuidString)", name: String = "lan-robot") {
        identity = RobotIdentity(hardwareID: hardwareID, name: name, daemonVersion: version)
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
///
/// Serialized because two tests turn on `KnownRobots.pendingProvisionedHardwareID`, one
/// value for the whole process: run beside the test that sets it, the test for a robot
/// with no hardware id passes whether nil matches nil or not.
@MainActor
@Suite("First run on the LAN", .serialized, .timeLimit(.minutes(1)))
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

    /// Nothing is waiting to be provisioned, and the robot reports no hardware id: nil
    /// matched nil, so such a robot read as new to this device on every connect.
    @Test("a robot with no hardware id is not mistaken for one set up over Bluetooth")
    func aRobotWithNoHardwareIDIsNotProvisioned() async {
        let robot = LANRobot(hardwareID: nil, name: "nameless-\(UUID().uuidString)")
        KnownRobots.remember(identity: robot.identity, address: RobotAddress(host: "192.168.1.77"))

        let session = await connect(robot, opener: Opener(completed: nil))

        #expect(!session.offersFirstRun)
        #expect(records.state(for: robot.identity.deduplicationKey) == .settled)
    }

    // MARK: - A connect that ends while the channel opens

    /// Holds the channel's opening until the test lets it go, then reports that it did
    /// not open — the eight seconds a real one can take, at the test's pace.
    @MainActor
    private final class HeldOpener {
        private(set) var opened = 0
        private var waiter: CheckedContinuation<Void, Never>?

        func open(_: RobotAddress) async -> (any FirstWakeUpClient)? {
            opened += 1
            await withCheckedContinuation { waiter = $0 }
            return nil
        }

        func letGo() {
            waiter?.resume()
            waiter = nil
        }
    }

    /// A disconnect resets the session's first-run state while the channel opens. The
    /// stale attempt used to read that reset as "met before" and settle a robot that
    /// never saw its first run, so no later connect ever asked it again.
    @Test("a connect that ends while the channel opens records nothing about the robot")
    func anEndedConnectRecordsNothing() async {
        let robot = LANRobot()
        let held = HeldOpener()
        let session = RobotSession { _ in robot }
        session.firstRunServices = FirstRunServices(
            openLANChannel: { @MainActor address in await held.open(address) },
            records: records
        )
        let connecting = Task { await session.connect(to: RobotAddress(host: "192.168.1.77")) }
        await waitUntil { held.opened == 1 }

        session.disconnect()
        held.letGo()
        await connecting.value

        #expect(records.state(for: robot.identity.deduplicationKey) == nil)
        #expect(!session.offersFirstRun)
        let opener = Opener(completed: false)
        let next = await connect(robot, opener: opener)
        #expect(next.offersFirstRun, "the next connect asks the robot")
        #expect(opener.opened.count == 1)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
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
