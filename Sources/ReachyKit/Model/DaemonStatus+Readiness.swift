import Foundation

/// Reading readiness off a status, with no session holding it.
///
/// `RobotSession` derives the same two things from the status it polls, and an
/// App Intent has to derive them from a status it fetched once — a second copy of
/// the rule is how the two would come to disagree about what "awake" means.
public extension Components.Schemas.DaemonStatus {
    /// Reported by all three backend flavours (robot, MuJoCo, mockup sim).
    var motorControlMode: Components.Schemas.MotorControlMode? {
        guard let status = backendStatus else { return nil }
        return status.value1?.motorControlMode
            ?? status.value2?.motorControlMode
            ?? status.value3?.motorControlMode
    }

    var isBackendRunning: Bool {
        state == .running
    }

    /// Gate for anything that moves the robot. Both halves matter: a robot parked
    /// in `disabled` accepts every move command, plays the sound, and does not
    /// move.
    var isAwake: Bool {
        isBackendRunning && motorControlMode == .enabled
    }

    /// Whether this daemon puts the robot to sleep by itself once the app slot
    /// frees.
    ///
    /// From 1.10.0 a freed slot calls `request_idle_reset()`, which waits
    /// `IDLE_RESET_DEBOUNCE_S` (1.5 s) and then runs `reset_to_sleep()`: the head
    /// lifts to the zero pose, the sleep animation plays and the motors are cut.
    /// Two conditions, each imposed by the daemon's own code:
    /// - **1.10.0 or newer, known rather than guessed.** A version this client
    ///   cannot read keeps the parking it always had, like every gate built on
    ///   `DaemonCompatibilityPolicy`.
    /// - **A media server.** The reset runs on the loop `setup_media_server`
    ///   builds, and `request_idle_reset()` returns at once without one — so a
    ///   `--no-media` daemon leaves the robot wherever the app did.
    ///
    /// A status cannot say which transport read it, and the relay is the third
    /// condition: every data-channel frame cancels the reset before it runs, so
    /// there a command replaces the daemon's sleep instead of racing it. Each
    /// caller adds that one itself (`RobotSession.daemonParksAfterApps`,
    /// `RobotSleep`).
    var resetsToSleepAfterApps: Bool {
        noMedia != true && DaemonCompatibilityPolicy.isKnownAtLeast("1.10.0", reported: version)
    }
}
