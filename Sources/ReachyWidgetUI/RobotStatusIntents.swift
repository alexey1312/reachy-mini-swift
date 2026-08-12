import AppIntents
import Foundation
import ReachyDesign
import ReachyKit

/// What the App Group snapshot can honestly be said to mean, in words.
///
/// **The first intents here that answer a question rather than issue a command**,
/// and the only ones that reach no robot at all: the reading is already on disk,
/// written by whichever process last spoke to one. So there is no
/// `RobotIntentTarget.connection`, no timeout budget and no failure mode beyond
/// having nothing to report.
///
/// Split out of the intents for the reason `RobotAppTitles` and
/// `RobotPowerTransitionState` are: the wording is the part worth pinning, and a
/// test can hold this without an `AppIntent` around it.
///
/// **The rule this type exists to enforce**: `RobotSnapshot.isAwake` is false for a
/// parked robot *and* for a torn-down backend, and those are opposite situations
/// with opposite ways out (`ReachyWidgetUI/AGENTS.md`). A tile may gloss that as
/// "Asleep" — it is one word beside a wake button that resolves both meanings by
/// itself. **A spoken sentence may not**, because it is a claim, and it is the
/// whole answer the listener gets. So a false `isAwake` is reported as *not awake*
/// with both readings named, and a reading past its window is reported as not
/// having answered rather than as anything about the present.
///
/// **Every sentence stays a `LocalizedStringResource` to the last moment.**
/// Flattening to `String` first and handing that back as a dialog would put the
/// finished sentence through format substitution a second time — and a robot's name
/// is free text somebody typed, so a robot called "100% Reachy" is all it takes.
/// Interpolating into the resource keeps the name an argument rather than part of
/// the key.
struct RobotStatusReport: Equatable, Sendable {
    /// How much the reading is worth, which is the only fork in here.
    enum Reading: Equatable, Sendable {
        /// No robot has been connected, the last one was let go of, or the reading
        /// on disk belongs to a robot other than the one asked about.
        ///
        /// Spelled out rather than `none`, which every optional in scope also
        /// answers to.
        case noRobot
        /// Inside `RobotSnapshotStore.freshness`, so the present tense is allowed.
        case current(RobotSnapshot)
        /// Past it. The robot may have been switched off since and nothing would
        /// have said so.
        case remembered(RobotSnapshot)
    }

    let reading: Reading
    let date: Date

    init(reading: Reading, at date: Date) {
        self.reading = reading
        self.date = date
    }

    init(state: RobotSnapshotState, at date: Date = Date()) {
        switch state {
        case .unknown: self.init(reading: .noRobot, at: date)
        case let .fresh(snapshot): self.init(reading: .current(snapshot), at: date)
        case let .stale(snapshot): self.init(reading: .remembered(snapshot), at: date)
        }
    }

    /// "Is Reachy awake?" — the motors alone, with the ambiguity stated rather than
    /// resolved by guessing.
    var powerDialog: LocalizedStringResource {
        switch reading {
        case .noRobot:
            Self.noRobotSentence
        case let .current(snapshot):
            snapshot.isAwake ? Self.awake(Self.name(of: snapshot)) : Self.notAwake(Self.name(of: snapshot))
        case let .remembered(snapshot):
            Self.unreachable(Self.name(of: snapshot), age: Self.age(of: snapshot, at: date))
        }
    }

    /// "What's running on Reachy?" — the app, the crash that replaced it, or the
    /// absence of both.
    ///
    /// `title` joins an entry point to its human name. The daemon files a running
    /// app as `AppInfo(name:source_kind:)` with an empty `extra`, so a snapshot
    /// written by an intent carries the Python entry point and nothing else —
    /// speaking `dance_party` where the robot's own store says "Dance Party" is the
    /// gap `RobotAppTitles` exists to close, and it is passed in rather than reached
    /// for so this type keeps no cache.
    func appDialog(title: (String) -> String) -> LocalizedStringResource {
        switch reading {
        case .noRobot:
            return Self.noRobotSentence
        case let .remembered(snapshot):
            return Self.unreachable(Self.name(of: snapshot), age: Self.age(of: snapshot, at: date))
        case let .current(snapshot):
            let name = Self.name(of: snapshot)
            if let app = runningApp(of: snapshot, title: title) {
                return Self.running(name, app: app)
            }
            // Its own, much shorter window. A crash is a fact about a moment and
            // nothing will ever arrive to contradict it, so it must not be spoken
            // past `failureFreshness` (`RobotSnapshotStore`).
            if let failed = snapshot.failedApp(at: date) {
                return Self.stopped(name, app: failed.title ?? title(failed.name))
            }
            return snapshot.isAwake ? Self.idle(name) : Self.notAwake(name)
        }
    }

    /// The app still worth naming, with the title joined on where the snapshot
    /// carried only an entry point.
    ///
    /// `runningAppTitle(at:)` cannot do the join by itself: it answers
    /// `runningApp ?? runningAppName`, so a missing title is indistinguishable from
    /// a title that happens to equal the entry point. The freshness gate is taken
    /// from `runningAppName(at:)`, which applies the same window.
    private func runningApp(of snapshot: RobotSnapshot, title: (String) -> String) -> String? {
        guard let name = snapshot.runningAppName(at: date) else {
            // A snapshot written before `runningAppName` existed carries only a
            // title, and there is nothing to join it to.
            return snapshot.runningAppTitle(at: date)
        }
        return snapshot.runningApp ?? title(name)
    }

    /// Daemon 1.9.0 mounts no rename route and reports an empty name, so a robot
    /// without one is ordinary rather than exceptional. Same fallback as
    /// `RobotWidgetContent.name(of:)`, and the same catalogue key.
    private static func name(of snapshot: RobotSnapshot) -> String {
        snapshot.robotName ?? String(localized: .reachy("Reachy Mini"))
    }

    private static func age(of snapshot: RobotSnapshot, at date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: snapshot.takenAt, relativeTo: date)
    }

    private static func awake(_ name: String) -> LocalizedStringResource {
        .reachy("\(name) is awake.")
    }

    /// Both meanings, because the snapshot holds one bit and they take opposite
    /// sequences to undo — parking is a motor mode, a stopped backend is a job.
    private static func notAwake(_ name: String) -> LocalizedStringResource {
        .reachy("\(name) is not awake. It is either asleep or its backend is switched off.")
    }

    private static func unreachable(_ name: String, age: String) -> LocalizedStringResource {
        .reachy("\(name) has not answered since \(age), so I cannot say what it is doing now.")
    }

    private static func running(_ name: String, app: String) -> LocalizedStringResource {
        .reachy("\(name) is running \(app).")
    }

    private static func stopped(_ name: String, app: String) -> LocalizedStringResource {
        .reachy("\(app) stopped on \(name).")
    }

    private static func idle(_ name: String) -> LocalizedStringResource {
        .reachy("\(name) is awake and is not running an app.")
    }

    private static var noRobotSentence: LocalizedStringResource {
        .reachy("No robot. Open Reachy Mini to connect.")
    }
}

/// "Is Reachy awake?"
///
/// Costs nothing: the answer is in the App Group snapshot the app and the widget
/// already share, so this never opens a socket and cannot time out. That is also
/// what makes it safe in the extension's own process, which has no screen to raise
/// a Local Network prompt from.
public struct RobotAwakeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Check whether Reachy Mini is awake"
    /// One literal rather than two joined with `+`: `IntentDescription` takes a
    /// `LocalizedStringResource`, and concatenating two literals collapses the pair
    /// into a `String`, which matches none of its initialisers. Same shape every
    /// long sentence in this repo uses — the disable sits on the literal's own line,
    /// because swiftformat wraps the call and would otherwise leave it pointing at
    /// the declaration.
    public static let description = IntentDescription(
        // swiftlint:disable:next line_length
        "Answers out of the last reading this app took. It never contacts the robot, so it reports what was last seen rather than what is true right now."
    )

    /// Optional like every other robot parameter here, so an unfilled slot means
    /// the last robot connected to and the existing phrases keep working.
    @Parameter(title: "Robot")
    public var robot: RobotEntity?

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: RobotStatusDialog.power(for: robot?.id))
    }
}

/// "What's running on Reachy?"
public struct RunningAppIntent: AppIntent {
    public static let title: LocalizedStringResource = "Check what Reachy Mini is running"
    public static let description = IntentDescription(
        // swiftlint:disable:next line_length
        "Names the app the robot was last seen running, or the one that stopped. Answers from the last reading this app took rather than by contacting the robot."
    )

    @Parameter(title: "Robot")
    public var robot: RobotEntity?

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: RobotStatusDialog.runningApp(for: robot?.id))
    }
}

/// The few lines both intents would otherwise repeat: read the store, wrap the
/// sentence.
///
/// **`freshReading(for:)` is not what is called here, and that is deliberate.** It
/// collapses stale and wrong-robot into one `nil`, which is right for a caller
/// about to command a robot and wrong for one about to describe it — "I have no
/// reading" and "my reading is old" are different answers. `state(at:)` keeps them
/// apart, and the robot check is made explicitly below.
enum RobotStatusDialog {
    static func power(for robotID: String?, at date: Date = Date()) -> IntentDialog {
        IntentDialog(report(for: robotID, at: date).powerDialog)
    }

    static func runningApp(for robotID: String?, at date: Date = Date()) -> IntentDialog {
        let titles = RobotAppTitles(robot: robotID)
        return IntentDialog(report(for: robotID, at: date).appDialog(title: titles.title(for:)))
    }

    /// **There is one snapshot and it belongs to whichever robot the app last
    /// talked to**, while an intent may name another one. Reporting the connected
    /// robot's reading under a different robot's name is the reading equivalent of
    /// the bug `RobotSnapshotStore.freshReading(for:)` was added to stop — so a
    /// mismatch reports having nothing to say about that robot, rather than a
    /// confident sentence about the wrong one.
    ///
    /// A snapshot written before identity was persisted carries no `robotID` and so
    /// matches no named robot, which is the same way `freshReading(for:)` is wrong
    /// on purpose: asking again is safe, guessing is not.
    static func report(for robotID: String?, at date: Date) -> RobotStatusReport {
        report(RobotSnapshotStore().state(at: date), for: robotID, at: date)
    }

    /// The seam. `RobotSnapshotStore()` defaults to the shared group suite, which
    /// every `--parallel` suite would otherwise share.
    static func report(_ state: RobotSnapshotState, for robotID: String?, at date: Date) -> RobotStatusReport {
        guard let robotID else { return RobotStatusReport(state: state, at: date) }
        switch state {
        case .unknown:
            return RobotStatusReport(reading: .noRobot, at: date)
        case let .fresh(snapshot), let .stale(snapshot):
            guard snapshot.robotID == robotID else { return RobotStatusReport(reading: .noRobot, at: date) }
            return RobotStatusReport(state: state, at: date)
        }
    }
}
