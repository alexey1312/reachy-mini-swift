import Foundation
@testable import ReachyKit
import Testing

/// From 1.10.0 the daemon parks the robot itself once an app lets go: 1.5 s after
/// the slot frees it lifts the head to zero, plays the sleep animation and cuts the
/// motors (`request_idle_reset` → `reset_to_sleep`). No motion or motor route
/// cancels that, so anything this session sends over the LAN runs alongside it
/// rather than instead of it (#154). The double plays the daemon's part with
/// `park()`.
@MainActor
@Suite("RobotSession parking on a daemon that parks itself", .timeLimit(.minutes(1)))
struct RobotSessionDaemonParkingTests {
    static let parkingDaemon = "1.11.0"

    /// **The duration is the second assertion** (project rule 7). A loop that missed
    /// the asleep reading ends at the 12 s deadline in exactly the same state.
    @Test("an app on an awake robot is left to the daemon's own sleep, shown as one")
    func leavesTheZeroPoseToTheDaemon() async throws {
        let client = AppLifecycleClient(daemonVersion: Self.parkingDaemon)
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        try await session.stopCurrentApp()
        await AppLifecycle.waitUntil(session.powerTransition == .goingToSleep)
        #expect(session.powerTransition == .goingToSleep)

        let parked = ContinuousClock.now
        client.park()
        await AppLifecycle.waitUntil(session.powerTransition == nil)

        #expect(parked.duration(to: .now) < .seconds(5))
        #expect(session.isAwake == false)
        #expect(client.recordedSteps == [.startApp(AppLifecycle.installedApp), .stopApp])
        session.disconnect()
    }

    @Test("a robot woken for the app is put to sleep by the daemon, not a second time")
    func leavesTheSleepToTheDaemon() async throws {
        let client = AppLifecycleClient(motorMode: .disabled, daemonVersion: Self.parkingDaemon)
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)
        #expect(session.appLifecycle.wakeOwner != nil)
        let woken = client.recordedSteps

        try await session.stopCurrentApp()
        await AppLifecycle.waitUntil(session.powerTransition == .goingToSleep)
        client.park()
        await AppLifecycle.waitUntil(session.powerTransition == nil)

        #expect(client.recordedSteps == woken + [.stopApp])
        #expect(session.appLifecycle.wakeOwner == nil)
        #expect(session.isAwake == false)
        session.disconnect()
    }

    /// Whoever cancelled the reset owns the robot now; putting the head down late
    /// would do it under them.
    @Test("a reset that never comes is not chased with a parking of our own")
    func doesNotChaseAMissingReset() async throws {
        let client = AppLifecycleClient(daemonVersion: Self.parkingDaemon)
        let session = await AppLifecycle.connected(client, idleResetTimeout: .milliseconds(200))
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        try await session.stopCurrentApp()
        await AppLifecycle.waitUntil(session.powerTransition == .goingToSleep)
        await AppLifecycle.waitUntil(session.powerTransition == nil)

        #expect(session.isAwake)
        #expect(client.recordedSteps == [.startApp(AppLifecycle.installedApp), .stopApp])
        session.disconnect()
    }

    /// Starting an app cancels the reset daemon-side, so the robot stays up for it.
    /// The duration is the assertion again: a loop that ignored the app would end
    /// at its deadline in the same state.
    @Test("an app taking the robot during the daemon's sleep ends the transition")
    func anotherAppEndsTheWait() async throws {
        let client = AppLifecycleClient(daemonVersion: Self.parkingDaemon)
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)
        try await session.stopCurrentApp()
        await AppLifecycle.waitUntil(session.powerTransition == .goingToSleep)

        // Started from somewhere this session did not — the widget, another phone.
        client.setRunning(.preview(.running))
        try await session.refreshCurrentApp()
        let taken = ContinuousClock.now
        await AppLifecycle.waitUntil(session.powerTransition == nil)

        #expect(taken.duration(to: .now) < .seconds(5))
        #expect(session.isAwake)
        session.disconnect()
    }

    /// The button is greyed during a transition; this is the guard behind it, and
    /// what it protects is the point — a sleep sent over HTTP does not cancel the
    /// daemon's, it runs beside it.
    @Test("Go to sleep during the daemon's own sleep sends nothing over it")
    func aSleepDoesNotJoinIn() async throws {
        let client = AppLifecycleClient(daemonVersion: Self.parkingDaemon)
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)
        try await session.stopCurrentApp()
        await AppLifecycle.waitUntil(session.powerTransition == .goingToSleep)

        await session.sleep()

        #expect(client.recordedSteps == [.startApp(AppLifecycle.installedApp), .stopApp])
        client.park()
        await AppLifecycle.waitUntil(session.powerTransition == nil)
        session.disconnect()
    }

    /// The daemon leaves a robot that is limp at the sleep pose alone
    /// (`_already_idle`), so there is nothing to show. Absence has no condition to
    /// wait for, so the transition is sampled for half the window a wrong branch
    /// would hold it open — one poll interval, stretched to 400 ms here.
    @Test("an app that put the robot to sleep itself announces no transition")
    func anAsleepRobotAnnouncesNothing() async throws {
        let client = AppLifecycleClient(daemonVersion: Self.parkingDaemon)
        let session = await AppLifecycle.connected(client, appStopPollInterval: .milliseconds(400))
        _ = try await session.startApp(named: AppLifecycle.installedApp)
        client.park()
        let readsBefore = client.statusReadCount

        try await session.stopCurrentApp()
        await AppLifecycle.waitUntil(client.statusReadCount > readsBefore)
        var seen: [RobotSession.PowerTransition] = []
        for _ in 0 ..< 20 {
            if let transition = session.powerTransition {
                seen.append(transition)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(seen.isEmpty)
        #expect(session.isAwake == false)
        session.disconnect()
    }

    // MARK: - A deliberate sleep with an app running (#166)

    /// Go to sleep stops the app first, and on a parking daemon that stop is itself
    /// a sleep 1.5 s later. The session watches it under the transition it already
    /// holds and sends nothing of its own.
    @Test("Go to sleep over a running app leaves the sleep to the daemon")
    func aSleepOverAnAppIsTheDaemons() async throws {
        let client = AppLifecycleClient(daemonVersion: Self.parkingDaemon)
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        // Nothing in a sleep reads the daemon's status before the watch does.
        let readsBefore = client.statusReadCount
        let sleeping = Task { await session.sleep() }
        await AppLifecycle.waitUntil(client.statusReadCount > readsBefore)
        #expect(client.recordedSteps.contains(.stopApp))
        #expect(session.powerTransition == .goingToSleep)
        client.park()
        await sleeping.value

        #expect(client.recordedSteps == [.startApp(AppLifecycle.installedApp), .stopApp])
        #expect(session.isAwake == false)
        #expect(session.powerTransition == nil)
        session.disconnect()
    }

    /// The user asked for sleep, so a reset that never comes is chased — the one
    /// place the session parts from `doesNotChaseAMissingReset`.
    @Test("a reset that never comes is chased with the sleep that was asked for")
    func aSleepChasesAMissingReset() async throws {
        let client = AppLifecycleClient(daemonVersion: Self.parkingDaemon)
        let session = await AppLifecycle.connected(client, idleResetTimeout: .milliseconds(200))
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        await session.sleep()

        #expect(client.recordedSteps == [
            .startApp(AppLifecycle.installedApp),
            .stopApp,
            .gotoSleep,
            .motorMode(.disabled),
        ])
        session.disconnect()
    }

    /// Starting an app cancels the reset daemon-side, and whoever started it after
    /// Go to sleep was pressed is the later instruction. Sleeping under it is the
    /// bug the release exists to prevent.
    @Test("an app taking the robot during that wait keeps it")
    func anAppTakingTheRobotKeepsIt() async throws {
        let client = AppLifecycleClient(daemonVersion: Self.parkingDaemon)
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        // Taken once the watch is running, not before the release has seen the
        // slot clear — that would be an app that never let go, which is another test.
        let readsBefore = client.statusReadCount
        let sleeping = Task { await session.sleep() }
        await AppLifecycle.waitUntil(client.statusReadCount > readsBefore)
        client.setRunning(.preview(.running))
        try await session.refreshCurrentApp()
        await sleeping.value

        #expect(client.recordedSteps.contains(.gotoSleep) == false)
        #expect(session.isAwake)
        session.disconnect()
    }

    /// Only a release schedules the reset. **The duration is the assertion**
    /// (project rule 7): a sleep that waited anyway would end at the 12 s deadline
    /// and then send exactly these steps.
    @Test(
        "with no app released the sleep is played at once",
        arguments: [
            ("1.11.0" as String?, false, false),
            ("1.9.0", true, false),
            ("1.11.0", true, true),
        ]
    )
    func playsTheSleepWhereNoResetIsComing(version: String?, withApp: Bool, overRelay: Bool) async throws {
        let client = AppLifecycleClient(daemonVersion: version)
        let session = await AppLifecycle.connected(client, overRelay: overRelay)
        if withApp {
            _ = try await session.startApp(named: AppLifecycle.installedApp)
        }

        let started = ContinuousClock.now
        await session.sleep()

        #expect(started.duration(to: .now) < .seconds(5))
        #expect(Array(client.recordedSteps.suffix(2)) == [.gotoSleep, .motorMode(.disabled)])
        session.disconnect()
    }

    // MARK: - Where the session keeps its own parking

    @Test(
        "only a LAN daemon known to be 1.10.0 or newer, with media, parks itself",
        arguments: [
            (nil as String?, nil as Bool?, false),
            ("1.9.0", nil, false),
            ("1.10.0", nil, true),
            ("1.11.0", false, true),
            ("1.11.0", true, false),
        ]
    )
    func gate(version: String?, noMedia: Bool?, parks: Bool) async {
        let client = AppLifecycleClient(daemonVersion: version, noMedia: noMedia)
        let session = await AppLifecycle.connected(client)

        #expect(session.daemonParksAfterApps == parks)
        session.disconnect()
    }

    @Test("a daemon before 1.10.0 still gets the zero pose")
    func anOlderDaemonStillGetsTheZeroPose() async throws {
        let client = AppLifecycleClient(daemonVersion: "1.9.0")
        let session = await AppLifecycle.connected(client)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        try await session.stopCurrentApp()
        await AppLifecycle.waitUntil(client.neutralCalls == 1)

        #expect(client.neutralCalls == 1)
        #expect(session.powerTransition == nil)
        session.disconnect()
    }

    /// Every relayed command is a data-channel frame, and the daemon cancels a
    /// pending or running reset on any of them — so here the session's sleep
    /// replaces the daemon's instead of racing it, and stays.
    @Test("over the relay the session puts the robot it woke back to sleep itself")
    func theRelayKeepsItsOwnParking() async throws {
        let client = AppLifecycleClient(motorMode: .disabled, daemonVersion: Self.parkingDaemon)
        let session = await AppLifecycle.connected(client, overRelay: true)
        #expect(session.isRemote)
        #expect(session.daemonParksAfterApps == false)
        _ = try await session.startApp(named: AppLifecycle.installedApp)

        try await session.stopCurrentApp()
        await AppLifecycle.waitUntil(client.recordedSteps.contains(.gotoSleep))

        #expect(client.recordedSteps.contains(.motorMode(.disabled)))
        session.disconnect()
    }
}
