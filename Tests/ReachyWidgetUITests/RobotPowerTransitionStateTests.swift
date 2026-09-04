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

    // MARK: - Who wrote it

    /// The app is the other writer now, and the flag is the only thing that can
    /// tell the two apart once the record is on disk.
    @Test("the app's own marker says so, and an intent's still does not")
    func recordsTheWriter() throws {
        let store = try store()

        store.begin(.startingBackend, writer: .session, at: now)
        #expect(store.current?.pending?.writer == .session)

        store.begin(.startingBackend, at: now)
        #expect(store.current?.pending?.writer == .intent)
    }

    /// Additive under the `.stored` freeze (project rule 11): records written by
    /// shipped builds are on disk, and the only process that wrote one then was an
    /// intent. Synthesised decoding would throw on the missing key, and
    /// `RobotPowerTransitionStore.current` swallows that with `try?` — so the whole
    /// symptom would be a widget that had quietly stopped showing transitions.
    @Test("a record written before the writer existed decodes as an intent's")
    func decodesALegacyRecord() throws {
        let defaults = try #require(
            UserDefaults(suiteName: "RobotPowerTransitionStateTests.\(UUID().uuidString)")
        )
        let legacy = """
        {"pending":{"transition":"startingBackend","since":\(now.timeIntervalSinceReferenceDate)}}
        """
        defaults.set(Data(legacy.utf8), forKey: RobotPowerTransitionStore.key)

        let pending = try #require(RobotPowerTransitionStore(defaults: defaults).current?.pending)

        #expect(pending.writer == .intent)
        #expect(pending.transition == .startingBackend)
        #expect(pending.since == now)
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
