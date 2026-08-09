import Foundation
import ReachyKit
@testable import ReachyWidgetUI
import Testing

/// One tap has to mean the whole sequence: find out what holds the robot, wake it
/// if it is parked, then start. Getting the order or the refusals wrong is how a
/// Home Screen button evicts somebody else's app or drops a head on a desk.
@Suite("Robot app launcher", .timeLimit(.minutes(1)))
struct RobotAppLauncherTests {
    private func launcher(_ client: StubAppsClient, assumeAwake: Bool? = true) -> RobotAppLauncher {
        RobotAppLauncher(client: client, assumeAwake: assumeAwake)
    }

    @Test("tapping the app that is running stops it")
    func stopsTheRunningApp() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party", title: "Dance Party")

        let outcome = try await launcher(client).toggle(name: "dance_party")

        #expect(outcome == .stopped(name: "dance_party"))
        #expect(client.calls == [.currentAppStatus, .stopCurrentApp])
    }

    /// The daemon would evict it without asking, and `start-app/{app}/no-evict` is
    /// in the spec but not mounted on 1.9.0 — so refusing is the client's job.
    @Test("tapping another app while one is running refuses instead of evicting")
    func refusesWhileAnotherAppHoldsTheRobot() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party", title: "Dance Party")

        await #expect(throws: RobotAppLauncher.Failure.busy(title: "Dance Party")) {
            try await launcher(client).toggle(name: "face_tracking")
        }
        #expect(client.calls == [.currentAppStatus])
    }

    /// An app that finished is not an app holding the robot.
    @Test("a finished app does not block the next one")
    func startsOverAFinishedApp() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party", state: "done")

        let outcome = try await launcher(client).toggle(name: "face_tracking")

        #expect(outcome == .started(name: "face_tracking", title: "face tracking"))
    }

    @Test("nothing running means the app just starts")
    func startsWhenIdle() async throws {
        let client = StubAppsClient()

        let outcome = try await launcher(client).toggle(name: "face_tracking")

        #expect(outcome == .started(name: "face_tracking", title: "face tracking"))
        #expect(client.calls == [.currentAppStatus, .startApp("face_tracking")])
    }

    /// Motors first, then the animation, then the app — the order `RobotPower`
    /// exists to keep. Reversed, the head drops.
    ///
    /// The status read is not redundant despite the caller having said "not awake":
    /// a snapshot's `isAwake` is false for a parked robot *and* for a torn-down
    /// backend, and those need different sequences — see `startsTheBackendItFindsDown`.
    @Test("a parked robot is woken before the app starts")
    func wakesAParkedRobot() async throws {
        let client = StubAppsClient()
        client.isAwake = false

        let outcome = try await launcher(client, assumeAwake: false).toggle(name: "face_tracking")

        #expect(outcome == .started(name: "face_tracking", title: "face tracking"))
        #expect(client.calls == [
            .currentAppStatus,
            .daemonStatus,
            .setMotorMode(.enabled),
            .wakeUp,
            .startApp("face_tracking"),
        ])
    }

    /// The other half of the power-off ladder. `motors/set_mode` sits behind
    /// `get_backend`, so waking a robot whose backend is gone can only 503 — the
    /// tap has to bring the backend back instead, and say so.
    @Test("a stopped backend is started rather than sent motor commands")
    func startsTheBackendItFindsDown() async throws {
        let client = StubAppsClient()
        client.isBackendRunning = false

        await #expect(throws: RobotAppLauncher.Failure.startingBackend) {
            try await launcher(client, assumeAwake: nil).toggle(name: "face_tracking")
        }

        // `wake_up: true`: the daemon enables the motors and plays the animation
        // itself once the backend is up, so nothing here has to wait for it.
        #expect(client.calls == [
            .currentAppStatus,
            .daemonStatus,
            .startDaemon(wakeUp: true),
        ])
    }

    /// A stale snapshot saying "asleep" is the same reading a stopped backend
    /// produces, so it must not be trusted into the wake branch.
    @Test("a snapshot that says asleep does not skip the backend check")
    func doesNotTrustASnapshotsAsleep() async throws {
        let client = StubAppsClient()
        client.isBackendRunning = false

        await #expect(throws: RobotAppLauncher.Failure.startingBackend) {
            try await launcher(client, assumeAwake: false).toggle(name: "face_tracking")
        }
        #expect(client.calls.contains(.setMotorMode(.enabled)) == false)
        #expect(client.calls.contains(.startApp("face_tracking")) == false)
    }

    /// A fresh reading of the robot's state is worth a round trip saved: the whole
    /// budget here is a few seconds.
    @Test("a caller that already knows the robot is awake skips the check")
    func skipsTheReadinessCheckWhenTold() async throws {
        let client = StubAppsClient()

        _ = try await launcher(client, assumeAwake: true).toggle(name: "face_tracking")

        #expect(client.calls.contains(.daemonStatus) == false)
        #expect(client.calls.contains(.setMotorMode(.enabled)) == false)
    }

    @Test("a caller that does not know asks the daemon once")
    func asksTheDaemonWhenUnsure() async throws {
        let client = StubAppsClient()
        client.isAwake = false

        _ = try await launcher(client, assumeAwake: nil).toggle(name: "face_tracking")

        #expect(client.calls.filter { $0 == .daemonStatus }.count == 1)
        #expect(client.calls.contains(.wakeUp))
    }

    /// Shortcuts says what it wants rather than what it wants flipped, so the same
    /// three refusals have to hold for an explicit start and an explicit stop.
    @Test("starting an app that is already the one running changes nothing")
    func startIsIdempotent() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party", title: "Dance Party")

        let outcome = try await launcher(client).start(name: "dance_party")

        #expect(outcome == .started(name: "dance_party", title: "Dance Party"))
        #expect(client.calls == [.currentAppStatus])
    }

    @Test("starting while another app holds the robot refuses instead of evicting")
    func startRefusesWhileBusy() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party", title: "Dance Party")

        await #expect(throws: RobotAppLauncher.Failure.busy(title: "Dance Party")) {
            try await launcher(client).start(name: "face_tracking")
        }
    }

    /// The entry point name and nothing else: a real `current-app-status` carries
    /// no card, so anything this claimed to be a title would be that same name in
    /// disguise. `RobotAppTitlesTests` covers the join that finds the real one.
    @Test("stopping names whatever holds the robot, whichever app that is")
    func stopsWhateverIsRunning() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party", title: "Dance Party")

        let outcome = try await launcher(client).stop()

        #expect(outcome == .stopped(name: "dance_party"))
        #expect(client.calls == [.currentAppStatus, .stopCurrentApp])
    }

    /// An automation ending by clearing the robot must not go red because the robot
    /// was already clear.
    @Test("stopping with nothing running is not a failure")
    func stopIsIdempotent() async throws {
        let client = StubAppsClient()

        let outcome = try await launcher(client).stop()

        #expect(outcome == nil)
        #expect(client.calls == [.currentAppStatus])
    }

    /// Stopping a process needs no motors, and waking a parked robot in order to
    /// park it again would be the wrong way round.
    @Test("stopping never wakes the robot")
    func stopDoesNotWake() async throws {
        let client = StubAppsClient()
        client.running = StubAppsClient.status(name: "dance_party")

        _ = try await launcher(client, assumeAwake: nil).stop()

        #expect(client.calls.contains(.wakeUp) == false)
        #expect(client.calls.contains(.daemonStatus) == false)
    }

    /// The whole budget is a few seconds, so no path may ask the daemon what is
    /// running more than once.
    @Test("each path reads the running app exactly once")
    func readsTheStatusOnce() async throws {
        let toggled = StubAppsClient()
        _ = try await launcher(toggled).toggle(name: "face_tracking")
        #expect(toggled.calls.filter { $0 == .currentAppStatus }.count == 1)

        let started = StubAppsClient()
        _ = try await launcher(started).start(name: "face_tracking")
        #expect(started.calls.filter { $0 == .currentAppStatus }.count == 1)
    }

    @Test("a name that would split the path is refused before anything is sent")
    func refusesANameWithASlash() async throws {
        let client = StubAppsClient()

        await #expect(throws: RobotAppLauncher.Failure.unusableName("owner/app")) {
            try await launcher(client).toggle(name: "owner/app")
        }
        #expect(client.calls.isEmpty)
    }

    /// Both budgets end in the same place — the app starts either way — and differ
    /// only in how long the wait takes, so the duration *is* the assertion
    /// (project rule 7). Ten seconds apart from four leaves room for a loaded
    /// runner.
    @Test("a wake animation that never finishes does not eat the intent's budget")
    func boundsTheWakeAnimation() async throws {
        let client = StubAppsClient()
        client.isAwake = false
        client.moveNeverFinishes = true

        let start = ContinuousClock.now
        _ = try await RobotAppLauncher(client: client, assumeAwake: false).toggle(name: "face_tracking")
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .seconds(8))
        #expect(RobotSession.Configuration.widgetIntent.moveCompletionTimeout
            < RobotSession.Configuration().moveCompletionTimeout)
    }

    @Test("an intent refuses an address now occupied by another robot")
    func verifiesTheRememberedIdentity() async throws {
        let client = StubAppsClient()
        let base = try await client.handshake()
        let expected = KnownRobot(
            key: "expected-hardware",
            name: "kitchen",
            address: .init(host: "127.0.0.1"),
            lastConnected: Date()
        )
        let handshake = RobotConnection.Handshake(
            identity: .init(hardwareID: "different-hardware", name: "office", daemonVersion: "1.9.0"),
            status: base.status
        )

        #expect(throws: RobotIntentError.wrongRobot) {
            try RobotIntentTarget.validate(handshake, expected: expected)
        }
    }

    @Test("an intent refuses an unsupported daemon before commands")
    func verifiesDaemonCompatibility() async throws {
        let client = StubAppsClient()
        let base = try await client.handshake()
        let expected = KnownRobot(
            key: "expected-hardware",
            name: "kitchen",
            address: .init(host: "127.0.0.1"),
            lastConnected: Date()
        )
        let handshake = RobotConnection.Handshake(
            identity: .init(hardwareID: expected.key, name: "kitchen", daemonVersion: "1.8.0"),
            status: base.status
        )

        #expect(throws: RobotIntentError.unsupportedDaemon(
            "Daemon 1.8.0 is unsupported; version 1.9.0 is required."
        )) {
            try RobotIntentTarget.validate(handshake, expected: expected)
        }
    }

    @Test("the whole intent sequence has one deadline")
    func boundsTheWholeIntent() async {
        let start = ContinuousClock.now

        await #expect(throws: RobotIntentError.timedOut) {
            try await RobotIntentTarget.withTimeout(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(30))
                return true
            }
        }

        #expect(ContinuousClock.now - start < .seconds(2))
    }
}
