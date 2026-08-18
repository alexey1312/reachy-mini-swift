import Foundation

/// Which kind of Reachy answered.
///
/// One daemon serves all of them. Upstream's desktop app bundles
/// `reachy_mini.daemon.app.main` as a sidecar and runs it on the user's own
/// computer for a Lite robot (`--serialport`) and for a simulator (`--sim`), so
/// there is no USB or simulation *transport* for a client to speak — both arrive
/// as plain HTTP, on loopback rather than on the robot. What separates the four is
/// three booleans in the status payload, and the routes that follow from them:
/// `--wireless-version` is what mounts `/wifi/*`, `/update/*` and `/cache/*`, and
/// nothing but a Wireless unit passes it.
public enum DaemonFlavour: Sendable, Hashable, CaseIterable {
    /// The daemon runs on the robot's own computer, under `--wireless-version`.
    case wireless
    /// The robot is wired to a computer over USB and the daemon runs there.
    case lite
    /// `--sim`: MuJoCo.
    case simulation
    /// `--mockup-sim`: no physics at all.
    case mockup
    /// Reached through the Hugging Face relay, where the question is not asked.
    case remote
}

public extension RobotSession {
    /// Which kind of robot answered, or `nil` before one has.
    ///
    /// **Presentation only.** The capability gates next door — `hasCamera`,
    /// `supportsWirelessFeatures`, `canPerformMaintenance` — go on reading the raw
    /// flags they always read. This value exists to *name* what the reader is
    /// connected to, and routing a gate through it would turn a caption into
    /// behaviour, which is a change of a different kind wearing a refactor's
    /// clothes.
    var flavour: DaemonFlavour? {
        // Asked before the status, because a relayed status is synthesised rather
        // than reported: `RemoteRobotConnection` sets `wireless_version: false` on
        // purpose, to keep `/wifi/*` and `/update/*` closed. Read in the order
        // below that is indistinguishable from a Lite unit.
        if isRemote {
            return .remote
        }
        guard let status = lastStatus else { return nil }
        // `Daemon.start` assigns these from two independent argparse flags, so
        // nothing forbids a daemon started with both. The order is a tie-break, and
        // mockup wins because "no physics at all" is the more restrictive of the
        // two claims and the one a reader would want to be told.
        if status.mockupSimEnabled == true {
            return .mockup
        }
        if status.simulationEnabled == true {
            return .simulation
        }
        // What is left: no simulation, and no `--wireless-version`.
        //
        // **A stopped backend reads as Lite even on a simulator**, and there is no
        // second signal to fix it with. `Daemon.__init__` builds the status with
        // both simulation flags `None` and only `start()` fills them, while
        // `wireless_version` is a constructor argument and is therefore right from
        // the first status poll. So this answer is wrong for exactly as long as a
        // simulator's backend is down, and corrects itself on the next poll after
        // it comes up. `desktop_app_daemon` cannot help — it says who *launched*
        // the daemon, and `mise run sim-daemon` does not pass it.
        return status.wirelessVersion ? .wireless : .lite
    }
}

public extension DaemonFlavour {
    /// Whether the daemon behind this flavour runs on a computer the reader owns
    /// rather than on the robot.
    ///
    /// Both halves of "the daemon is somewhere else" — a Lite robot is plugged into
    /// a computer, a simulator has no robot at all — and it is the same answer to
    /// the same question a reader asks when the Wi-Fi and Update cards are missing.
    var runsOnAComputer: Bool {
        switch self {
        case .lite, .simulation, .mockup: true
        case .wireless, .remote: false
        }
    }
}
