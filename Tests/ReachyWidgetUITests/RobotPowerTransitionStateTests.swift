import Foundation
import ReachyKit
@testable import ReachyWidgetUI
import Testing

/// The marker exists because `RobotPower.resume()` does not wait: a cold backend
/// start is ninety seconds and the intent returns in one. What is written down here
/// is the only thing standing between the reader and a widget that says "Asleep"
/// under an unchanged button while the robot is starting.
@Suite("Robot power transition state")
struct RobotPowerTransitionStateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func store() throws -> RobotPowerTransitionStore {
        try RobotPowerTransitionStore(
            defaults: #require(UserDefaults(suiteName: "RobotPowerTransitionStateTests.\(UUID().uuidString)"))
        )
    }

    @Test("what an intent wrote before the call survives to the next render")
    func roundTripsAPending() throws {
        let store = try store()

        store.begin(.goingToSleep, at: now)

        let pending = try #require(store.current?.pending)
        #expect(pending.transition == .goingToSleep)
        #expect(pending.since == now)
    }

    /// The reason `RobotAppLaunchStateStore.begin` clears too: showing why the last
    /// attempt failed while this one is in flight reads as this one failing.
    @Test("retrying clears the previous failure")
    func beginningClearsAFailure() throws {
        let store = try store()
        store.fail(message: "Took too long.", at: now)

        store.begin(.wakingUp, at: now)

        #expect(store.current?.failure == nil)
        #expect(store.current?.pending != nil)
    }

    @Test("a failure replaces the pending it came out of")
    func failingClearsThePending() throws {
        let store = try store()
        store.begin(.wakingUp, at: now)

        store.fail(message: "Took too long.", at: now)

        #expect(store.current?.pending == nil)
        #expect(store.current?.failure?.message == "Took too long.")
    }

    @Test("success leaves nothing behind")
    func succeedingClearsBoth() throws {
        let store = try store()
        store.begin(.wakingUp, at: now)

        store.succeed()

        #expect(store.current?.pending == nil)
        #expect(store.current?.failure == nil)
    }

    /// One window would be wrong twice — too short for a cold start, or long enough
    /// to leave "Going to sleep…" up for two minutes after a four-second operation.
    @Test("a cold start is given a longer window than any other transition")
    func windowsAreOrdered() {
        let starting = RobotPowerTransitionState.window(for: .startingBackend)

        for transition in [RobotSession.PowerTransition.wakingUp, .goingToSleep, .stoppingBackend] {
            #expect(RobotPowerTransitionState.window(for: transition) < starting)
        }
    }

    @Test("a transition and a failure each expire on their own clock")
    func expiryUsesTheRightWindow() {
        let wake = RobotPowerTransitionState(pending: .init(transition: .wakingUp, since: now))
        let past = now.addingTimeInterval(RobotPowerTransitionState.window(for: .wakingUp) + 1)

        #expect(wake.pending(at: now) != nil)
        #expect(wake.pending(at: past) == nil)

        let failed = RobotPowerTransitionState(failure: .init(message: "boom", at: now))
        #expect(failed.failure(at: now) != nil)
        #expect(failed.failure(at: now.addingTimeInterval(RobotPowerTransitionState.failureWindow + 1)) == nil)
    }
}
