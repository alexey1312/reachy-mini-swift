import Foundation
import Observation
import ReachyKit

/// The one control on the Robot screen that needs asking twice.
///
/// A model rather than `@State` on the screen, for the reasons `MaintenanceModel`
/// records: the interesting part is the sentence in front of the button — which
/// app is about to be stopped, and what else goes with the backend — and that is
/// worth asserting without rendering anything. A preview can open the dialog too,
/// which a `@State` bool cannot.
@MainActor
@Observable
final class RobotPowerOffModel {
    /// Not `private(set)`: the dialog's binding writes it back on dismissal.
    var isConfirming = false

    /// The app set to start on wake-up, as last read — the one reason Power off
    /// has a second choice (``PowerOffPlan``).
    ///
    /// Read when the screen appears and again when the button is tapped — see
    /// `confirm(_:budget:)` for why the first is not enough.
    private(set) var startupApp: String?
    /// The robot `startupApp` was read from, so a reading never outlives the
    /// connection it came from.
    private var readFrom: String?

    /// How long a tap on Power off waits for a fresh reading before the dialog opens
    /// on the last one. A LAN round trip is tens of milliseconds; this only bounds a
    /// robot that has stopped answering.
    static let confirmationReadBudget: Duration = .milliseconds(800)

    /// The seam a preview reaches for: a model that has already read the robot.
    init(startupApp: String? = nil) {
        self.startupApp = startupApp
    }

    /// Opens the dialog on a reading taken at the tap.
    ///
    /// The one taken on appearance is not enough. The switch that sets a startup app
    /// is also on the running app's page, which the dock presents as a sheet over
    /// every tab — this one included — and a sheet does not make the screen under it
    /// disappear, so nothing re-reads when it closes. Another client can set it too.
    /// So the tap reads again, and waits only `budget` for the answer: a dialog that
    /// never opens would be worse than one opened on the previous reading.
    func confirm(_ session: RobotSession, budget: Duration = confirmationReadBudget) async {
        let reading = Task { await refresh(session) }
        let deadline = Task {
            try await Task.sleep(for: budget)
            reading.cancel()
        }
        await reading.value
        deadline.cancel()
        isConfirming = true
    }

    /// Only a reading that arrived replaces the last one. `try?` would fold "no
    /// startup app" and "no answer" into the same `nil`, and a Wi-Fi blip must not
    /// quietly put the teardown back as the only choice. A robot that has never
    /// answered leaves `nil` — the dialog it always had.
    func refresh(_ session: RobotSession) async {
        let robot = session.connectedIdentity?.deduplicationKey
        if robot != readFrom {
            startupApp = nil
            readFrom = robot
        }
        do {
            startupApp = try await session.startupApp()
        } catch {
            // Keep the last reading, per the rule above.
        }
    }

    /// Decided on the backend's live state rather than once, so a robot powered off
    /// from here stops being offered a sleep it would refuse with a 503.
    func plan(_ session: RobotSession) -> PowerOffPlan {
        PowerOffPlan(startupApp: startupApp, isBackendRunning: session.isBackendRunning)
    }

    /// Whether the dialog offers sleep as its first choice. Only to an awake robot:
    /// one already asleep is already where that choice would take it, and Cancel
    /// says so without playing the sleep animation at limp motors.
    func offersSleep(_ session: RobotSession) -> Bool {
        if case .sleep = plan(session) {
            return session.isAwake
        }
        return false
    }

    /// The app that powering off will take down with the backend.
    ///
    /// Not a reason to refuse, unlike `MaintenanceModel.blockingApp` — uninstalling
    /// deletes an environment out from under a live process, while this stops it
    /// first and on purpose. It is a reason to *say so*, because the reader may
    /// have left it running deliberately.
    ///
    /// An unfamiliar process state counts as running, the same way
    /// `RobotAppStatus.State.isBusy` treats it.
    func runningApp(_ session: RobotSession) -> RobotApp? {
        guard let status = session.runningApp, status.isBusy else { return nil }
        return status.app
    }

    /// The sentence in the dialog, which is the whole point of it and captures as
    /// nothing headless — so it is built here, where a test can read it.
    ///
    /// A `String` rather than a resource because a startup app with a running app
    /// is two sentences, and only the one naming the app interpolates: kept apart,
    /// the other stays in the catalogue and is translated.
    func confirmationMessage(_ session: RobotSession) -> String {
        let app = runningApp(session)
        switch plan(session) {
        case .stopBackend:
            if let app {
                return String(localized: .reachy(
                    "\(app.title) stops first, then the robot goes to sleep and its motors and camera shut down."
                ))
            }
            return String(localized: .reachy("The robot goes to sleep first, then its motors and camera shut down."))
        case .sleep:
            let cost = String(localized: .reachy(
                // swiftlint:disable:next line_length
                "Touching an antenna starts the app set to start on wake-up, and a sleeping robot still notices it. A powered-off one does not, until you wake it from here."
            ))
            guard let app else { return cost }
            return String(localized: .reachy("\(app.title) stops first.")) + " " + cost
        }
    }

    /// Available on a LAN session only. `/api/daemon/stop` is an HTTP route, and the
    /// relay's command vocabulary has no equivalent — which is just as well, since
    /// tearing the backend down through a remote connection would leave nobody able
    /// to bring it back.
    func canPowerOff(_ session: RobotSession) -> Bool {
        session.address != nil && session.powerTransition == nil
    }

    func perform(_ session: RobotSession) async {
        await session.powerOff()
    }
}
