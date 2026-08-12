import Foundation

/// What the app last saw of a robot, for a process that cannot look for itself.
///
/// A widget extension is woken for a moment, renders, and is gone. It can hold
/// neither the state WebSocket nor a WebRTC session, so it shows what the app
/// wrote the last time it was connected — and `takenAt` is what keeps that
/// honest rather than merely confident.
public struct RobotSnapshot: Codable, Sendable, Equatable {
    /// An app that died on the robot, as the last reading found it.
    ///
    /// Deliberately not folded into `runningApp`: a dead process holds nothing, and
    /// naming it there would have every other tile dim itself on behalf of
    /// something that no longer exists.
    public struct FailedApp: Codable, Sendable, Equatable {
        /// The installed name — the identity `start-app` is keyed by, and therefore
        /// the only thing that finds the tile this belongs to.
        public let name: String
        public let title: String?
        /// The daemon's own last line, when it gave one.
        public let error: String?

        public init(name: String, title: String? = nil, error: String? = nil) {
            self.name = name
            self.title = title
            self.error = error
        }
    }

    /// Stable identity of the robot that produced this reading. Optional only so
    /// snapshots written before identity was persisted still decode.
    public let robotID: String?
    /// Nil for a robot whose daemon never answered a name — the same daemons
    /// that cannot be renamed at all.
    public let robotName: String?
    public let isAwake: Bool
    /// The app the robot is running, when it is running one — its display title,
    /// which is what a widget puts on screen.
    public let runningApp: String?
    /// The same app's installed name, which is the identity `start-app` and
    /// `stop-current-app` are keyed by. A title cannot stand in for it: the two
    /// are chosen independently (`RobotApp.matches(installed:)`).
    ///
    /// Defaulted so a blob written before this field existed decodes as a robot
    /// running nothing identifiable rather than failing.
    public let runningAppName: String?
    /// The app the same reading found dead. Mutually exclusive with the two above —
    /// one app holds the robot at a time, and a crashed one holds it no longer.
    public let failedApp: FailedApp?
    /// When the app situation was last checked, running or crashed. Status polling
    /// refreshes `takenAt`, but cannot refresh this without another robot round
    /// trip.
    public let runningAppTakenAt: Date?
    /// When the app saw this. Not decoration: everything below turns on it.
    public let takenAt: Date

    public init(
        robotID: String? = nil,
        robotName: String?,
        isAwake: Bool,
        runningApp: String?,
        runningAppName: String? = nil,
        failedApp: FailedApp? = nil,
        runningAppTakenAt: Date? = nil,
        takenAt: Date
    ) {
        self.robotID = robotID
        self.robotName = robotName
        self.isAwake = isAwake
        self.runningApp = runningApp
        self.runningAppName = runningAppName
        self.failedApp = failedApp
        self.runningAppTakenAt = runningAppTakenAt
        self.takenAt = takenAt
    }

    /// The app observation expires independently of the daemon status. For a
    /// legacy snapshot without its own date, the snapshot date is the safest
    /// compatible approximation.
    public func runningAppName(at date: Date) -> String? {
        guard runningAppIsFresh(at: date) else { return nil }
        return runningAppName
    }

    public func runningAppTitle(at date: Date) -> String? {
        guard runningAppIsFresh(at: date) else { return nil }
        return runningApp ?? runningAppName
    }

    /// The crash, while it is still worth reporting.
    ///
    /// On its own window, which is much the shorter of the two — see
    /// `RobotSnapshotStore.failureFreshness`.
    public func failedApp(at date: Date) -> FailedApp? {
        guard let expiry = failedAppExpiresAt, date <= expiry else { return nil }
        return failedApp
    }

    public var runningAppExpiresAt: Date? {
        guard runningApp != nil || runningAppName != nil else { return nil }
        return (runningAppTakenAt ?? takenAt).addingTimeInterval(RobotSnapshotStore.freshness)
    }

    public var failedAppExpiresAt: Date? {
        guard failedApp != nil else { return nil }
        return (runningAppTakenAt ?? takenAt).addingTimeInterval(RobotSnapshotStore.failureFreshness)
    }

    private func runningAppIsFresh(at date: Date) -> Bool {
        guard let expiry = runningAppExpiresAt else { return false }
        return date <= expiry
    }
}

/// Whether a snapshot is still worth stating as fact.
public enum RobotSnapshotState: Sendable, Equatable {
    /// No robot has been connected, or the last one was let go of. Nothing to
    /// show, and nothing to guess.
    case unknown
    /// Recent enough to describe in the present tense.
    case fresh(RobotSnapshot)
    /// Old enough that the robot may have been switched off since — a robot
    /// leaving does not announce itself. Say when it was seen, not what it is
    /// doing.
    case stale(RobotSnapshot)
}

/// The snapshot, in storage both processes can reach.
public struct RobotSnapshotStore {
    static let key = "ReachyKit.robotSnapshot"

    /// How long a reading is repeated as current.
    ///
    /// A robot switched off, unplugged or carried out of range tells nobody, and
    /// the app is not running to notice. Half an hour is long enough to cover a
    /// phone put down mid-session and short enough that a widget does not
    /// describe yesterday's robot in the present tense.
    public static let freshness: TimeInterval = 30 * 60

    /// How long a crash is worth repeating, which is far less.
    ///
    /// "It is running" goes wrong because the robot left without saying so. "It
    /// crashed" goes wrong for the opposite reason: it is a fact about a moment,
    /// and nothing will ever arrive to contradict it — a widget still reporting
    /// this morning's traceback is exactly as unhelpful as one still reporting this
    /// morning's running app. Fifteen minutes is what the launcher already gives a
    /// failure the user caused (`RobotAppLaunchState.failureWindow`, which cannot be
    /// named from here); one they did not deserves no longer.
    public static let failureFreshness: TimeInterval = 15 * 60

    private let defaults: UserDefaults

    /// Defaults to the shared group, which is the only store the widget can read.
    public init(defaults: UserDefaults = KnownRobots.defaults) {
        self.defaults = defaults
    }

    public var current: RobotSnapshot? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(RobotSnapshot.self, from: data)
    }

    public func write(_ snapshot: RobotSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// Called when the session ends: a reading left behind would have the widget
    /// describe a robot the user deliberately disconnected from.
    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    public func state(at date: Date = Date()) -> RobotSnapshotState {
        guard let current else { return .unknown }
        // A negative age is a clock that moved backwards — a timezone change, a
        // manual correction — not a reading from the future gone stale.
        let age = date.timeIntervalSince(current.takenAt)
        return age <= Self.freshness ? .fresh(current) : .stale(current)
    }

    /// The fresh reading, but only where it describes the robot the caller is about
    /// to command.
    ///
    /// **There is one snapshot and it belongs to whichever robot the app last
    /// talked to**, while an App Intent may name another one. `isAwake` is what
    /// every caller reads to decide whether to wake, so believing another robot's
    /// answer is how a command reaches a robot over disabled motors — accepted,
    /// reported as success, and doing nothing.
    ///
    /// `nil` for `robotID` is "whichever robot this is", which is what the widget's
    /// own buttons mean. A named robot against a snapshot written before identity
    /// was persisted matches nothing, and asking the daemon is the safe way to be
    /// wrong.
    public func freshReading(for robotID: String?, at date: Date = Date()) -> RobotSnapshot? {
        guard case let .fresh(reading) = state(at: date),
              robotID == nil || reading.robotID == robotID
        else { return nil }
        return reading
    }

    /// Folds what a caller just learned about the running app into the reading
    /// already there, inventing nothing else about it.
    ///
    /// `takenAt` moves to `date` because whoever calls this has just spoken to the
    /// robot — the reading genuinely is that fresh, even though only one field of
    /// it was re-checked. Both name parameters nil is "nothing is running", not "I
    /// do not know", so it clears rather than leaves the last app behind.
    ///
    /// `isAwake` is for a caller that learned it in the same breath; nil keeps
    /// what was already there. The `true` floor is only reached when no reading
    /// exists at all, and every caller here has just commanded a robot
    /// successfully — which a parked one does not answer.
    ///
    /// `failed` is written the same way and for the same reason: this is one
    /// reading of one question, so a caller that saw a live app has thereby seen no
    /// crash, and a nil here clears the last one rather than leaving it standing
    /// behind a robot that has moved on.
    ///
    /// Re-reading the same failure does not make the crash new. Its original date
    /// is preserved so polling a terminal daemon status cannot keep the widget's
    /// shorter failure window alive forever; a changed failure starts a new window.
    public func recordRunningApp(
        title: String?,
        name: String?,
        failed: RobotSnapshot.FailedApp? = nil,
        robotID: String? = nil,
        robotName: String? = nil,
        isAwake: Bool? = nil,
        at date: Date = Date()
    ) {
        let previous = current
        let resolvedID = robotID ?? previous?.robotID
        let sameRobot = robotID == nil || previous?.robotID == robotID
        let sawAnApp = title != nil || name != nil || failed != nil
        let repeatsFailure = failed != nil && sameRobot && previous?.failedApp == failed
        let appTakenAt: Date? = if repeatsFailure {
            previous.map { $0.runningAppTakenAt ?? $0.takenAt }
        } else {
            sawAnApp ? date : nil
        }
        write(RobotSnapshot(
            robotID: resolvedID,
            robotName: robotName ?? (sameRobot ? previous?.robotName : nil),
            isAwake: isAwake ?? (sameRobot ? previous?.isAwake : nil) ?? true,
            runningApp: title,
            runningAppName: name,
            failedApp: failed,
            runningAppTakenAt: appTakenAt,
            takenAt: date
        ))
    }

    /// What a caller learned about the motors alone, leaving the app reading where
    /// it was.
    ///
    /// `recordRunningApp` cannot stand in for this. It is one reading of one
    /// question and therefore *clears* the app fields when handed nils — correct
    /// for a caller that just stopped something, wrong for waking up, which stops
    /// nothing. Sleeping and powering off do release the app first and so keep
    /// using `recordRunningApp`; only the wake path needs this.
    ///
    /// A reading about a *different* robot carries nothing forward, for the same
    /// reason `recordRunningApp` gates on `sameRobot`: the previous app belonged to
    /// the previous robot.
    public func recordPower(
        isAwake: Bool,
        robotID: String? = nil,
        robotName: String? = nil,
        at date: Date = Date()
    ) {
        let previous = current
        let sameRobot = robotID == nil || previous?.robotID == robotID
        write(RobotSnapshot(
            robotID: robotID ?? previous?.robotID,
            robotName: robotName ?? (sameRobot ? previous?.robotName : nil),
            isAwake: isAwake,
            runningApp: sameRobot ? previous?.runningApp : nil,
            runningAppName: sameRobot ? previous?.runningAppName : nil,
            failedApp: sameRobot ? previous?.failedApp : nil,
            runningAppTakenAt: sameRobot ? previous?.runningAppTakenAt : nil,
            takenAt: date
        ))
    }
}
