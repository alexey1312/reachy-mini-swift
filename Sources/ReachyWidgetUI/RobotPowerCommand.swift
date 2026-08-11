import Foundation
import ReachyKit
import WidgetKit

/// Everything an intent has to do around the power protocols, once.
///
/// The twin of `RobotAppCommand`, with the same justification: four callers —
/// Control Centre, Siri, the Shortcuts app and the widget's own button — and
/// written out at each of them it would be four copies of the same pending-state,
/// snapshot and timeline-reload dance, the first edit leaving three behind.
///
/// It also closes a gap that predates the widget's button. No power intent used to
/// write a snapshot or reload a timeline, so waking the robot from Control Centre
/// left the widget saying "Asleep" until the app next ran to correct it.
///
/// **Not unit-tested end to end, and the reason is structural.** `perform()`
/// reaches the network through `RobotIntentTarget`, which reads
/// `KnownRobots.all.first` out of a static with no seam to inject through — the
/// same reason `RobotAppCommand` has no test file either. What is testable was
/// pushed out into `RobotPowerTransitionState` and `RobotSnapshotStore.recordPower`,
/// which do have one.
public struct RobotPowerCommand: Sendable {
    public enum Operation: Equatable, Sendable {
        case wake
        case sleep
        case powerOff

        /// What to say while the call is out. Waking opens on `.wakingUp` because
        /// that is the ordinary case and the backend's state is not known until the
        /// daemon has been asked; `perform()` corrects it to `.startingBackend` when
        /// the answer comes back otherwise.
        var opening: RobotSession.PowerTransition {
            switch self {
            case .wake: .wakingUp
            case .sleep: .goingToSleep
            case .powerOff: .stoppingBackend
            }
        }
    }

    /// The whole command, handshake included. A request timeout bounds one period
    /// of inactivity; this bounds the sequence.
    static let executionTimeout: Duration = .seconds(15)

    private let operation: Operation

    public init(_ operation: Operation) {
        self.operation = operation
    }

    /// Non-nil only for `.wake`, whose caller has two different sentences to speak.
    @discardableResult
    public func perform() async throws -> RobotPower.Resumption? {
        let transitions = RobotPowerTransitionStore()

        // Written *before* the request, and the reload right behind it, exactly as
        // `RobotAppCommand` does: this is the only way the widget can say "Waking
        // up…" while the call is still out, and it survives the process being
        // killed mid-call, which a piece of memory would not.
        transitions.begin(operation.opening)
        reload()

        do {
            let operation = operation
            let result = try await RobotIntentTarget.withTimeout(Self.executionTimeout) {
                let target = try await RobotIntentTarget.connection(timeout: 10)
                let resumption = try await operation.run(on: target)
                return (target.robot, resumption)
            }
            record(result.1, robot: result.0, transitions: transitions)
            reload()
            return result.1
        } catch {
            transitions.fail(message: RobotSession.describe(error))
            reload()
            // Rethrown *after* the reload, not instead of it: what the user sees is
            // the widget's own notice, and the thrown error is for Shortcuts and
            // for a debugger.
            throw error
        }
    }

    /// What the command learned, for whatever draws it next.
    ///
    /// **`.startingBackend` claims nothing about the motors and stays pending.** The
    /// robot is up to ninety seconds from awake and `resume()` waited for none of
    /// it, so writing `isAwake: true` here would be the widget's version of
    /// pretending the job is done. The marker is re-opened under the longer window
    /// instead, and the reading is left exactly where it was.
    private func record(
        _ resumption: RobotPower.Resumption?,
        robot: KnownRobot,
        transitions: RobotPowerTransitionStore
    ) {
        let snapshots = RobotSnapshotStore()
        switch (operation, resumption) {
        case (.wake, .startingBackend):
            transitions.begin(.startingBackend)
        case (.wake, _):
            snapshots.recordPower(isAwake: true, robotID: robot.key, robotName: robot.name)
            transitions.succeed()
        case (.sleep, _), (.powerOff, _):
            // Both released the app before parking, so clearing it is truthful —
            // and `recordRunningApp` is the writer that says so.
            snapshots.recordRunningApp(
                title: nil,
                name: nil,
                robotID: robot.key,
                robotName: robot.name,
                isAwake: false
            )
            transitions.succeed()
        }
    }

    /// Both widgets: sleeping and powering off stop the running app, which is what
    /// the apps widget draws.
    private func reload() {
        WidgetCenter.shared.reloadTimelines(ofKind: ReachyWidgetKind.status)
        WidgetCenter.shared.reloadTimelines(ofKind: ReachyWidgetKind.apps)
    }
}

private extension RobotPowerCommand.Operation {
    /// `.widgetIntent` on every branch. `RobotSleep` and `RobotShutdown` default to
    /// it; the wake path used to build `RobotPower` with no configuration at all and
    /// so inherited the session's 10-second move budget in a process that has
    /// seconds.
    func run(on target: RobotIntentTarget.VerifiedConnection) async throws -> RobotPower.Resumption? {
        switch self {
        case .wake:
            return try await RobotPower(client: target.client, configuration: .widgetIntent).resume()
        case .sleep:
            try await RobotSleep(client: target.client).perform()
            return nil
        case .powerOff:
            try await RobotShutdown(client: target.client).perform()
            return nil
        }
    }
}
