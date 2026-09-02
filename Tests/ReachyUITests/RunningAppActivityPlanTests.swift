import Foundation
import ReachyKit
@testable import ReachyUI
import ReachyWidgetUI
import Testing

/// The Live Activity's whole job is to say something true about a robot nobody is
/// looking at, on a card that cannot fetch anything and freezes the moment the phone
/// goes in a pocket. So most of these assert what it *refuses* to do: start on an
/// edge it did not observe, end on a silence, come back after it was waved away, or
/// state a verdict it inferred from a timer.
@Suite("Running app activity plan")
struct RunningAppActivityPlanTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let robot = "kitchen"

    private func plan() -> RunningAppActivityPlan {
        var plan = RunningAppActivityPlan()
        plan.isPermitted = true
        return plan
    }

    private func reading(
        _ state: RobotAppStatus.State?,
        app: RobotApp = RobotApp.previewInstalled[0],
        robot: String? = "kitchen",
        error: String? = nil,
        at offset: TimeInterval = 0,
        isReachable: Bool = true,
        wedged: Bool = false,
        isRestarting: Bool = false,
        canStop: Bool = true
    ) -> RunningAppActivityPlan.Reading {
        RunningAppActivityPlan.Reading(
            status: state.map { RobotAppStatus(app: app, state: $0, error: error) },
            robotID: robot,
            robotName: "Reachy",
            isReachable: isReachable,
            wedged: wedged,
            canStop: canStop,
            isRestarting: isRestarting,
            at: now.addingTimeInterval(offset)
        )
    }

    // MARK: - Starting

    @Test("one card per run, on the edge the app observed and not on every poll after it")
    func startsOnceOnTheBusyEdge() {
        var plan = plan()
        let first = plan.handle(.read(reading(.running)))
        let second = plan.handle(.read(reading(.running, at: 1)))
        #expect(first.count == 1)
        guard case .start = first[0] else { return #expect(Bool(false), "expected a start, got \(first)") }
        #expect(second.isEmpty)
    }

    /// A cold launch that finds a finished or crashed app has missed the run. A card
    /// created only to be ended is a flash of noise, and the dock and the widget
    /// already carry the crash.
    @Test("a terminal first reading starts nothing")
    func doesNotStartForATerminalFirstReading() {
        var plan = plan()
        #expect(plan.handle(.read(reading(.done))).isEmpty)
        #expect(plan.handle(.read(reading(.error, error: "Process exited with code 1"))).isEmpty)
        #expect(plan.live == nil)
    }

    /// The daemon reports a status only while an app is loaded, so a word this build
    /// has never heard of is a later daemon's name for running, not an app that
    /// finished quietly.
    @Test("an unfamiliar state still holds the robot, and keeps the daemon's own word")
    func anUnknownStateHoldsTheRobot() throws {
        var plan = plan()
        let effects = plan.handle(.read(reading(.unknown("pausing"))))
        guard case let .start(_, content, _) = try #require(effects.first) else {
            return #expect(Bool(false), "expected a start")
        }
        #expect(content.caption == "pausing")
    }

    @Test("switched off in Settings, or backgrounded, the plan does no work and throws nothing")
    func permissionOffStartsNothing() {
        var plan = RunningAppActivityPlan()
        #expect(plan.handle(.read(reading(.running))).isEmpty)
        #expect(plan.live == nil)
    }

    // MARK: - Ending

    @Test("a clean finish leaves immediately and says nothing")
    func aCleanFinishLeavesQuietly() throws {
        var plan = plan()
        _ = plan.handle(.read(reading(.running)))
        let effects = plan.handle(.read(reading(.done, at: 10)))
        guard case let .end(_, content, dismissal) = try #require(effects.first) else {
            return #expect(Bool(false), "expected an end")
        }
        #expect(content == nil)
        #expect(dismissal == .immediate)
        #expect(effects.contains {
            if case .update = $0 {
                true
            } else {
                false
            }
        } == false)
    }

    @Test("the app letting go is noticed once, not on every idle poll after it")
    func endsExactlyOncePerRun() {
        var plan = plan()
        _ = plan.handle(.read(reading(.running)))
        #expect(plan.handle(.read(reading(nil, at: 10))).isEmpty == false)
        #expect(plan.handle(.read(reading(nil, at: 20))).isEmpty)
    }

    /// `restart-current-app` is stop-then-start behind one request. Ending in the gap
    /// is a false "stopped" and a card that reappears 1.5 s later.
    @Test("a restart is not the app letting go")
    func aRestartDoesNotEndTheActivity() {
        var plan = plan()
        _ = plan.handle(.read(reading(.running)))
        #expect(plan.handle(.read(reading(nil, at: 2, isRestarting: true))).isEmpty)
        #expect(plan.live != nil)
    }

    /// The one transition the phone is obliged to announce, and the alert rides an
    /// update because `end` takes no alert configuration.
    @Test("a crash is reported once, with the summary line, and the card is left to be read")
    func aCrashAlertsAndThenLingers() {
        var plan = plan()
        _ = plan.handle(.read(reading(.running)))
        let effects = plan.handle(.read(reading(
            .error,
            error: "Process exited with code 1\nTraceback (most recent call last):",
            at: 30
        )))
        let alerts = effects.compactMap { effect -> RunningAppActivityPlan.Alert? in
            if case let .update(_, _, _, alert) = effect {
                alert
            } else {
                nil
            }
        }
        #expect(alerts.count == 1)
        #expect(alerts.first?.body == "Process exited with code 1")
        #expect(alerts.first?.title.contains("Reachy") == true)
        let ends = effects.compactMap { effect -> RunningAppActivityPlan.Dismissal? in
            if case let .end(_, _, dismissal) = effect {
                dismissal
            } else {
                nil
            }
        }
        #expect(ends == [.after(now.addingTimeInterval(30 + RobotAppLaunchState.failureWindow))])
    }

    @Test("a second reading of the same crash does not alert again")
    func aRepeatedCrashDoesNotAlertTwice() {
        var plan = plan()
        _ = plan.handle(.read(reading(.running)))
        _ = plan.handle(.read(reading(.error, error: "Process exited with code 1", at: 30)))
        #expect(plan.handle(.read(reading(.error, error: "Process exited with code 1", at: 45))).isEmpty)
    }

    // MARK: - What silence may not conclude

    /// The app is probably still running; the reading simply stopped moving. Ending
    /// here would claim the robot became free because the network did not answer.
    @Test("an unreachable robot keeps the card rather than claiming the app stopped")
    func anUnreachableRobotKeepsTheActivity() {
        var plan = plan()
        _ = plan.handle(.read(reading(.running)))
        _ = plan.handle(.read(reading(.running, at: 90, isReachable: false)))
        #expect(plan.live != nil)
    }

    @Test("a reading about another robot ends the card rather than renaming it")
    func aReadingAboutAnotherRobotEndsTheActivity() throws {
        var plan = plan()
        _ = plan.handle(.read(reading(.running)))
        let effects = plan.handle(.read(reading(.running, robot: "study", at: 10)))
        guard case let .end(_, _, dismissal) = try #require(effects.first) else {
            return #expect(Bool(false), "expected an end")
        }
        #expect(dismissal == .immediate)
        #expect(plan.live == nil)
    }

    /// `ActivityAttributes` are fixed at request time and the app's identity lives
    /// there, so a card cannot be renamed in place. Two apps are two runs anyway; what
    /// this pins is that the old card is ended rather than left behind, and that the
    /// new one really starts.
    @Test("another app on the same robot replaces the card rather than leaving two")
    func anotherAppReplacesTheCard() throws {
        var plan = plan()
        _ = plan.handle(.read(reading(.running)))
        let effects = plan.handle(.read(reading(.running, app: RobotApp.previewConversation, at: 10)))
        guard case let .end(endedKey, _, dismissal) = try #require(effects.first) else {
            return #expect(Bool(false), "expected the old card to end first, got \(effects)")
        }
        #expect(dismissal == .immediate)
        #expect(effects.contains {
            if case .start = $0 {
                true
            } else {
                false
            }
        })
        #expect(plan.live?.app.runKey != endedKey)
    }

    // MARK: - Staleness

    /// The widget's reading and this one come from the same status, so they must go
    /// quiet together or one Lock Screen carries two claims about one robot.
    @Test("a running card goes stale on the snapshot's own freshness boundary")
    func staleDateForRunningIsTheSnapshotBoundary() throws {
        var plan = plan()
        guard case let .start(_, _, stale) = try #require(plan.handle(.read(reading(.running))).first) else {
            return #expect(Bool(false), "expected a start")
        }
        #expect(stale == now.addingTimeInterval(RobotSnapshotStore.freshness))
    }

    @Test("a transition goes stale on its own deadline, measured from when it was first seen")
    func staleDateForATransitionIsItsDeadline() throws {
        var startingPlan = plan()
        var stoppingPlan = plan()
        let configuration = RunningAppModel.Configuration()
        guard case let .start(_, _, starting) = try #require(startingPlan.handle(.read(reading(.starting))).first),
              case let .start(_, _, stopping) = try #require(stoppingPlan.handle(.read(reading(.stopping))).first)
        else { return #expect(Bool(false), "expected a start from each") }
        #expect(starting == now.addingTimeInterval(configuration.startingDeadline.components.seconds.toSeconds))
        #expect(stopping == now.addingTimeInterval(configuration.stoppingDeadline.components.seconds.toSeconds))
        // The two budgets differ by an order of magnitude; one window would be wrong
        // twice over, so swapping them has to go red.
        #expect(starting != stopping)
    }

    /// A transition joined late has no start this device observed, so the clock runs
    /// from first sight rather than from each poll.
    @Test("a transition still in flight keeps the deadline it was first given")
    func aTransitionKeepsItsFirstSight() throws {
        var plan = plan()
        _ = plan.handle(.read(reading(.starting)))
        let effects = plan.handle(.read(reading(.starting, at: 70)))
        guard case let .update(_, _, stale, _) = try #require(effects.first) else {
            return #expect(Bool(false), "expected an update, got \(effects)")
        }
        let configuration = RunningAppModel.Configuration()
        #expect(stale == now.addingTimeInterval(configuration.startingDeadline.components.seconds.toSeconds))
    }

    /// Skipping identical updates would let a healthy app polled every ten seconds go
    /// grey on screen; pushing every tick would spend the budget on nothing.
    @Test("an unchanged reading moves the stale date, but no more often than the floor")
    func anUnchangedReadingIsRewrittenAtAFloor() {
        var plan = plan()
        _ = plan.handle(.read(reading(.running)))
        #expect(plan.handle(.read(reading(.running, at: 10))).isEmpty)
        #expect(plan.handle(.read(reading(.running, at: 30))).isEmpty)
        #expect(plan.handle(.read(reading(.running, at: RunningAppActivityPlan.refreshFloor))).isEmpty == false)
    }

    // MARK: - The reader's own actions

    /// The refusal reaches the card the way every other sentence does — through a
    /// reading — rather than through an event of its own. `RunningAppCaption` already
    /// gives `actionFailure` precedence over the state, so a second path here would be
    /// a second answer to the same question, which is what that type exists to prevent.
    ///
    /// What it pins is that a refusal **updates and never ends**: ending on a failed
    /// Stop reads as the Stop having worked, which is the bug that caption was written
    /// to fix, in a second place.
    @Test("a refused Stop is reported rather than ending the card")
    func aRefusedStopIsReportedRatherThanEnding() throws {
        var plan = plan()
        _ = plan.handle(.read(reading(.running)))
        var refused = reading(.running, at: 5)
        refused.actionFailure = "The robot refused to stop the app"
        let effects = plan.handle(.read(refused))
        guard case let .update(_, content, _, _) = try #require(effects.first) else {
            return #expect(Bool(false), "expected an update, got \(effects)")
        }
        #expect(content.caption == "The robot refused to stop the app")
        #expect(content.isFailed)
        #expect(content.canStop, "a refusal must leave the reader able to try again")
        #expect(plan.live != nil)
    }

    // MARK: - Dismissal and the eight-hour cap

    /// Without a memory the next foreground pass sees a running app and no card, and
    /// resurrects exactly what the reader waved away.
    @Test("a card the reader swiped away does not come back for the same run")
    func aDismissedRunDoesNotComeBack() {
        var plan = plan()
        _ = plan.handle(.read(reading(.running)))
        #expect(plan.handle(.dismissed).contains {
            if case .remember = $0 {
                true
            } else {
                false
            }
        })
        #expect(plan.handle(.read(reading(.running, at: 60))).isEmpty)
    }

    /// Re-creating it starts a fresh eight hours, so a conversation app left running
    /// all day would reappear every eight hours for ever. The system ending it is the
    /// system's decision about attention.
    @Test("the eight-hour cap is not argued with")
    func aSystemEndedActivityIsNotReplaced() {
        var plan = plan()
        _ = plan.handle(.read(reading(.running)))
        _ = plan.handle(.systemEnded)
        #expect(plan.handle(.read(reading(.running, at: 60))).isEmpty)
    }

    /// The run is over, so the next one is news again.
    @Test("the memory is cleared when the run ends")
    func aDismissalClearsWhenTheRunDoes() {
        var plan = plan()
        _ = plan.handle(.read(reading(.running)))
        let ended = plan.handle(.read(reading(nil, at: 10)))
        #expect(ended.contains {
            if case .forget = $0 {
                true
            } else {
                false
            }
        })
    }

    /// A card gone from `Activity.activities` without this process ending it was
    /// taken by the reader or by the cap; both mean the same thing here.
    @Test("a card that vanished while the app was away is not resurrected")
    func reconciliationDropsAVanishedCard() {
        var plan = plan()
        _ = plan.handle(.read(reading(.running)))
        #expect(plan.handle(.observed([], at: now.addingTimeInterval(30))).isEmpty == false)
        #expect(plan.live == nil)
        #expect(plan.handle(.read(reading(.running, at: 60))).isEmpty)
    }

    @Test("a card still on screen is left alone by the reconciliation pass")
    func reconciliationKeepsALiveCard() throws {
        var plan = plan()
        _ = plan.handle(.read(reading(.running)))
        let app = try #require(plan.live?.app)
        #expect(plan.handle(.observed([app], at: now.addingTimeInterval(30))).isEmpty)
        #expect(plan.live != nil)
    }
}

private extension Int64 {
    var toSeconds: TimeInterval {
        TimeInterval(self)
    }
}
