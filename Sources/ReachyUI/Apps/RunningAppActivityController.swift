import Foundation
import ReachyKit
import ReachyWidgetUI
import SwiftUI

/// Everything about the robot the Live Activity's decisions turn on, as one
/// `Equatable` value.
///
/// The shape `RobotWidgetFacts` already has, and for the reason written there:
/// keyed into a `.task(id:)`, it makes the work follow the fact rather than
/// accompany it. Nothing here is read from the environment or from a store — the
/// caller assembles it from the session and the dock's model, both of which are
/// already observable.
struct RunningAppActivityFacts: Equatable {
    var status: RobotAppStatus?
    var robotID: String?
    var robotName: String?
    var isReachable = true
    var wedged = false
    var actionFailure: String?
    /// A relay session has no address, and an intent can only dial a LAN one — so
    /// this is what decides whether the card draws a Stop button at all.
    var hasLocalAddress = false
    var isRestarting = false
    /// Foreground. ActivityKit refuses a request from anywhere else, and the dock's
    /// poll is gated on the same thing, so the two agree by construction.
    var isActive = false
}

/// Performs the plan's effects, and owns the one thing a pure reducer cannot know:
/// what `Activity.activities` currently holds.
///
/// Every ActivityKit call arrives as an injected `@Sendable` closure whose default is
/// the adapter below — `RunningAppActivityKit` on iOS, a no-op everywhere else. That
/// is what lets the whole state machine be exercised by `mise run test`, which is
/// SwiftPM on macOS where ActivityKit does not exist, and it is the same seam
/// `MenuBarModel` uses for its commands.
@MainActor
@Observable
final class RunningAppActivityController {
    typealias IsEnabled = @Sendable () -> Bool
    typealias LiveActivities = @Sendable () -> [RunningAppActivityApp]
    typealias Start = @Sendable (RunningAppActivityApp, RunningAppActivityContent, Date) -> Void
    typealias Update = @Sendable (
        String, RunningAppActivityContent, Date, RunningAppActivityPlan.Alert?
    ) async -> Void
    typealias End = @Sendable (String, RunningAppActivityContent?, Date?) async -> Void

    private var plan: RunningAppActivityPlan
    private let dismissals: RunningAppActivityDismissalStore
    private let isEnabled: IsEnabled
    private let liveActivities: LiveActivities
    private let start: Start
    private let update: Update
    private let end: End

    init(
        configuration: RunningAppModel.Configuration = .init(),
        dismissals: RunningAppActivityDismissalStore = .init(),
        isEnabled: @escaping IsEnabled = RunningAppActivitySystem.isEnabled,
        liveActivities: @escaping LiveActivities = RunningAppActivitySystem.live,
        start: @escaping Start = RunningAppActivitySystem.start,
        update: @escaping Update = RunningAppActivitySystem.update,
        end: @escaping End = RunningAppActivitySystem.end
    ) {
        plan = RunningAppActivityPlan(configuration: configuration)
        self.dismissals = dismissals
        self.isEnabled = isEnabled
        self.liveActivities = liveActivities
        self.start = start
        self.update = update
        self.end = end
    }

    /// One pass: reconcile with what the system holds, then decide on the reading.
    ///
    /// The reconciliation runs first and on every pass, because it is the only thing
    /// that can notice three separate hazards at once — the process was killed and
    /// relaunched, the eight-hour cap ended the card, and the reader swiped it away
    /// while this process was not running to be told.
    func sync(_ facts: RunningAppActivityFacts, at date: Date = Date()) async {
        plan.isPermitted = facts.isActive && isEnabled()
        plan.dismissed = dismissals.current(at: date)
        await perform(plan.handle(.observed(liveActivities(), at: date)))
        await perform(plan.handle(.read(reading(from: facts, at: date))))
    }

    private func reading(
        from facts: RunningAppActivityFacts,
        at date: Date
    ) -> RunningAppActivityPlan.Reading {
        RunningAppActivityPlan.Reading(
            status: facts.status,
            robotID: facts.robotID,
            robotName: facts.robotName,
            isReachable: facts.isReachable,
            wedged: facts.wedged,
            actionFailure: facts.actionFailure,
            canStop: facts.hasLocalAddress,
            isRestarting: facts.isRestarting,
            at: date
        )
    }

    private func perform(_ effects: [RunningAppActivityPlan.Effect]) async {
        for effect in effects {
            switch effect {
            case let .start(app, content, staleDate):
                start(app, content, staleDate)
            case let .update(key, content, staleDate, alert):
                await update(key, content, staleDate, alert)
            case let .end(key, content, dismissal):
                await end(key, content, dismissal.date)
            case let .remember(key):
                dismissals.remember(key)
            case let .forget(key):
                dismissals.forget(key)
            }
        }
    }
}

extension RunningAppActivityPlan.Dismissal {
    /// `nil` is `.immediate` at the ActivityKit boundary, which keeps this type free
    /// of `ActivityUIDismissalPolicy` — an iOS-only value.
    var date: Date? {
        switch self {
        case .immediate: nil
        case let .after(date): date
        }
    }
}

/// The boundary itself: five functions, each a one-liner over
/// `RunningAppActivityKit` on iOS and a no-op elsewhere.
///
/// Separate from the controller so the `#if` fence encloses nothing that decides
/// anything — the same division `RunningAppActivityAttributes.swift` makes on the
/// other side of it.
enum RunningAppActivitySystem {
    static let isEnabled: RunningAppActivityController.IsEnabled = {
        #if os(iOS)
            RunningAppActivityKit.isEnabled
        #else
            false
        #endif
    }

    static let live: RunningAppActivityController.LiveActivities = {
        #if os(iOS)
            RunningAppActivityKit.live()
        #else
            []
        #endif
    }

    static let start: RunningAppActivityController.Start = { app, content, staleDate in
        #if os(iOS)
            RunningAppActivityKit.start(app: app, content: content, staleDate: staleDate)
        #endif
    }

    static let update: RunningAppActivityController.Update = { key, content, staleDate, alert in
        #if os(iOS)
            await RunningAppActivityKit.update(
                runKey: key,
                content: content,
                staleDate: staleDate,
                alert: alert.map { (title: $0.title, body: $0.body) }
            )
        #endif
    }

    static let end: RunningAppActivityController.End = { key, content, date in
        #if os(iOS)
            await RunningAppActivityKit.end(runKey: key, content: content, after: date)
        #endif
    }
}
