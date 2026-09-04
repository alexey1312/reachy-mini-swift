import ReachyKit
@testable import ReachyUI
import Testing

/// The app had two power paths and marked only the lesser one: every
/// `RobotPowerTransitionStore.begin` in the tree was `RobotPowerCommand`'s, so the
/// Robot tab's ladder, Start on an app's page and the connection stepper left the
/// widget saying "Asleep" under an unchanged **Wake up** for the whole of a 90 s
/// cold start.
///
/// What is asserted here is the *edges* — which change of a two-field fact means
/// begin, succeed or fail. The writing that follows an answer is three lines against
/// a store; the decision is the part that can be wrong, and it is the part no
/// `UserDefaults` suite would have told you was wrong.
@Suite("Robot power mirror")
struct RobotPowerMirrorTests {
    private func facts(
        _ transition: RobotSession.PowerTransition? = nil,
        error: String? = nil
    ) -> RobotPowerFacts {
        RobotPowerFacts(transition: transition, error: error)
    }

    @Test("a transition starting is written down")
    func opensAMarker() {
        #expect(RobotPowerMirror.write(from: facts(), to: facts(.goingToSleep)) == .begin(.goingToSleep))
    }

    /// `wake()` claims `.wakingUp` before its first suspension point and becomes
    /// `.startingBackend` the moment it finds the backend down. Those two windows are
    /// 30 s and 120 s, so leaving the first one in place would retire the marker a
    /// minute and a half into a job it is still watching.
    @Test("a transition changing under the marker re-opens it")
    func reopensOnAChangedTransition() {
        #expect(
            RobotPowerMirror.write(from: facts(.wakingUp), to: facts(.startingBackend))
                == .begin(.startingBackend)
        )
    }

    @Test("the same transition twice writes nothing")
    func ignoresARepeat() {
        #expect(RobotPowerMirror.write(from: facts(.wakingUp), to: facts(.wakingUp)) == nil)
    }

    @Test("a transition ending clears the marker")
    func closesAMarker() {
        #expect(RobotPowerMirror.write(from: facts(.stoppingBackend), to: facts()) == .succeed)
    }

    /// Every rung of the ladder clears `robotError` on entry and `report(_:)` fills it
    /// in ahead of the `defer` that ends the transition, so the sentence is already
    /// here at the moment this reads as ended.
    @Test("a transition ending with a new sentence reports it")
    func reportsAFailure() {
        let write = RobotPowerMirror.write(
            from: facts(.stoppingBackend),
            to: facts(error: "Robot backend did not stop within 60.0 seconds.")
        )

        #expect(write == .fail("Robot backend did not stop within 60.0 seconds."))
    }

    /// `claimRobotForApp` wakes the robot without clearing `robotError` — it throws to
    /// the Apps model rather than reporting onto the Robot tab — so a sentence from
    /// this morning is still there when its transition ends. Apologising for it would
    /// put a stale failure on the Lock Screen over a wake that worked.
    @Test("an error that was already there is not reported as this transition's")
    func ignoresAStaleFailure() {
        let write = RobotPowerMirror.write(
            from: facts(.wakingUp, error: "Yesterday."),
            to: facts(error: "Yesterday.")
        )

        #expect(write == .succeed)
    }

    /// The fact carries the session's error, which moves for reasons that have nothing
    /// to do with power — a failed listing, a refused rename. With no transition either
    /// side of the change there is nothing about the widget's marker to say.
    @Test("an error moving outside a transition writes nothing")
    func ignoresErrorsOutsideATransition() {
        #expect(RobotPowerMirror.write(from: facts(), to: facts(error: "Something else.")) == nil)
    }
}
