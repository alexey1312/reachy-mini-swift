import Foundation
import ReachyKit
import WidgetKit

/// Everything an intent has to do around `RobotAppLauncher`, once.
///
/// The launcher is the robot half — find out what holds it, wake it, start. This
/// is the bookkeeping half, and there are four callers for it now: the widget's
/// tile and the three actions Shortcuts offers. Written out at each of them it
/// would be four copies of the same pending-state, snapshot and timeline-reload
/// dance, and the first edit would leave three of them behind.
public struct RobotAppCommand: Sendable {
    public enum Operation: Equatable, Sendable {
        case start(name: String)
        case stop
        case toggle(name: String)
    }

    /// The whole command, handshake included. A request timeout bounds one period
    /// of inactivity; this bounds the sequence.
    static let executionTimeout: Duration = .seconds(15)

    private let operation: Operation
    /// The tile's bookkeeping key — `RobotApp.id`, which is what a saved widget
    /// configuration holds. `nil` when the caller has no tile behind it, and then
    /// no pending caption is filed: `RobotAppLaunchState` is keyed by app, and
    /// "stop whatever is running" names none.
    private let appID: String?
    /// `RobotEntity.id` where the caller named a robot. See `RobotPowerCommand`.
    private let robot: String?

    public init(_ operation: Operation, appID: String? = nil, robot: String? = nil) {
        self.operation = operation
        self.appID = appID
        self.robot = robot
    }

    /// `nil` means there was nothing to stop, which is not a failure — see
    /// `RobotAppLauncher.stop()`.
    @discardableResult
    public func perform() async throws -> RobotAppLauncher.Outcome? {
        let snapshots = RobotSnapshotStore()
        let launches = RobotAppLaunchStateStore()

        // Written *before* the request, and the reload right behind it: this is the
        // only way the tile can say "Starting…" while the call is still out. It
        // also survives the process being killed mid-call, which a piece of memory
        // would not — `pendingWindow` is what expires it instead.
        if let appID {
            launches.begin(appID: appID, isStop: looksLikeAStop(snapshots: snapshots))
            reload()
        }

        do {
            // A reading inside its window and about *this* robot is worth a round
            // trip saved; anything else, ask. `RobotAppLauncher` treats nil as
            // "find out".
            let assumeAwake = snapshots.freshReading(for: robot)?.isAwake
            let operation = operation
            let robot = robot
            let result = try await RobotIntentTarget.withTimeout(Self.executionTimeout) {
                let target = try await RobotIntentTarget.connection(to: robot, timeout: 6)
                let launcher = RobotAppLauncher(client: target.client, assumeAwake: assumeAwake)
                let outcome = try await operation.run(on: launcher)
                return (target.robot, outcome)
            }
            record(result.1, robot: result.0, in: snapshots)
            if let appID {
                launches.succeed(appID: appID)
            }
            reload()
            return result.1
        } catch {
            if let appID {
                launches.fail(appID: appID, message: RobotSession.describe(error))
            }
            reload()
            // Rethrown *after* the reload, not instead of it. On iOS 18 what the
            // user sees is the widget's own notice; the thrown error is for
            // Shortcuts and for a debugger.
            throw error
        }
    }

    /// Which caption the pending tile should carry. A toggle's guess is wrong only
    /// when there is no reading about this robot to make it from, and then the
    /// launcher corrects the outcome a second later.
    private func looksLikeAStop(snapshots: RobotSnapshotStore) -> Bool {
        switch operation {
        case .start:
            false
        case .stop:
            true
        case let .toggle(name):
            snapshots.freshReading(for: robot)?.runningAppName(at: Date()) == name
        }
    }

    /// What the command learned about the robot, for whatever draws it next.
    ///
    /// A stop that found nothing to stop claims nothing about the motors: it never
    /// asked, and `isAwake: nil` leaves the previous reading where it was rather
    /// than inventing one.
    private func record(
        _ outcome: RobotAppLauncher.Outcome?,
        robot: KnownRobot,
        in snapshots: RobotSnapshotStore
    ) {
        switch outcome {
        case let .started(name, title):
            snapshots.recordRunningApp(
                title: title,
                name: name,
                robotID: robot.key,
                robotName: robot.name,
                isAwake: true
            )
        case .stopped:
            snapshots.recordRunningApp(
                title: nil,
                name: nil,
                robotID: robot.key,
                robotName: robot.name,
                isAwake: true
            )
        case .none:
            snapshots.recordRunningApp(
                title: nil,
                name: nil,
                robotID: robot.key,
                robotName: robot.name
            )
        }
    }

    /// Both widgets: a running app is also what `RobotWidgetContent` puts in front
    /// of the awake reading.
    private func reload() {
        WidgetCenter.shared.reloadTimelines(ofKind: ReachyWidgetKind.apps)
        WidgetCenter.shared.reloadTimelines(ofKind: ReachyWidgetKind.status)
    }
}

private extension RobotAppCommand.Operation {
    func run(on launcher: RobotAppLauncher) async throws -> RobotAppLauncher.Outcome? {
        switch self {
        case let .start(name):
            try await launcher.start(name: name)
        case .stop:
            try await launcher.stop()
        case let .toggle(name):
            try await launcher.toggle(name: name)
        }
    }
}
