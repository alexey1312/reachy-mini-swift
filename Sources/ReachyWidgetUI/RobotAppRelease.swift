import Foundation
import ReachyKit

/// Handing the robot back from whatever app holds it, with no session around it.
///
/// The step `RobotSleep` and `RobotShutdown` both take before they park anything,
/// and a type rather than three lines in each because it is a stop *and* a wait —
/// and a wait that is skipped fails silently, with the robot parked on top of an
/// app that was still handing it back.
///
/// `RobotSession.releaseRunningApp` is the twin on the session side, and not shared
/// code for the reason none of the twins here are: that one reads state the session
/// already holds and reports each failure onto a screen, while this asks the daemon
/// afresh and has nowhere to put a sentence.
struct RobotAppRelease: Sendable {
    private let apps: any RobotAppsClient
    private let configuration: RobotSession.Configuration

    init(apps: any RobotAppsClient, configuration: RobotSession.Configuration = .widgetIntent) {
        self.apps = apps
        self.configuration = configuration
    }

    /// Stops the app holding the robot and waits for the daemon to let go of it.
    ///
    /// Answers whether the robot is free, and no caller aborts on `false`: parking
    /// the body matters more than proof that the app let go, and an intent has one
    /// sentence which belongs to the transition rather than to this.
    ///
    /// An app that already finished is not stopped again — `isBusy` is what says
    /// the robot is still held, and an unfamiliar state counts as held.
    @discardableResult
    func perform() async -> Bool {
        guard let running = try? await apps.currentAppStatus(), running.isBusy else { return true }
        do {
            try await apps.stopCurrentApp()
        } catch {
            return false
        }
        return await waitForRelease()
    }

    /// **A 200 from `stop-current-app` does not mean the app is gone.** The daemon
    /// sets `stopping` before any I/O and clears its own slot on the last line,
    /// past the return-to-zero it performs on the app's behalf
    /// (`apps/manager.py:283`, `:355`), so the reading is what says the robot is
    /// free — not the reply.
    ///
    /// The status is read before the first sleep, so a stop that was already
    /// complete costs one request rather than a poll interval. A read that throws
    /// concludes nothing and is asked again; only the deadline ends the wait.
    private func waitForRelease() async -> Bool {
        let deadline = ContinuousClock.now + configuration.appStopTimeout
        while !Task.isCancelled {
            do {
                let status = try await apps.currentAppStatus()
                if status?.isBusy != true { return true }
            } catch {
                // A reading that never arrived is not evidence either way.
            }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: configuration.appStopPollInterval)
        }
        return false
    }
}
