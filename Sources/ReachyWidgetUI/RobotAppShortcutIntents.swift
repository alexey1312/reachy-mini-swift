import AppIntents
import ReachyDesign

/// The robot's apps, as actions a person can drop into a shortcut.
///
/// Three of them rather than one toggle, because an automation says what it wants
/// rather than what it wants flipped: "start the conversation app when I get home"
/// is not "start it unless it is already on, in which case stop it". The toggle is
/// here too, for the shortcut that is a button.
///
/// They take a `RobotAppEntity`, which is what makes the picker in Shortcuts, and
/// `RobotAppQuery` already fills it — cache first, live list when the robot
/// answers within two seconds. `RobotAppTileIntent` deliberately does not; the
/// reasons are written beside it.
///
/// **Each dialog names the app by the entity's own title, never by anything the
/// outcome carries**: the daemon's word for a running app is the Python entry
/// point, and `RobotAppTitles` records why. `StopRobotAppIntent` has no entity, so
/// it is the one that has to ask.
///
/// The dialogs themselves localize, unlike an intent's title or description — they
/// are built and resolved here at runtime rather than extracted into
/// `Metadata.appintents`, so the exemption in `ReachyDesign/AGENTS.md` does not
/// reach them and project rule 9 applies as everywhere else.
public struct StartRobotAppIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start a Reachy Mini app"
    public static let description = IntentDescription(
        "Starts an app on your robot, waking it first if it is asleep."
    )

    @Parameter(title: "App")
    public var app: RobotAppEntity

    @Parameter(title: "Robot")
    public var robot: RobotEntity?

    public init() {}

    public init(app: RobotAppEntity) {
        self.app = app
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        try await RobotAppCommand(.start(name: app.name), appID: app.id, robot: robot?.id).perform()
        return .result(dialog: IntentDialog(.reachy("Started \(app.title).")))
    }
}

/// No parameter: the robot runs one app at a time, so "stop the app" names it
/// exactly. Asking which one would be asking the user to repeat something the
/// robot already knows — and to get it wrong when they misremember.
public struct StopRobotAppIntent: AppIntent {
    public static let title: LocalizedStringResource = "Stop the Reachy Mini app"
    public static let description = IntentDescription(
        "Stops whichever app is running on your robot. Does nothing if none is."
    )

    @Parameter(title: "Robot")
    public var robot: RobotEntity?

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard case let .stopped(name) = try await RobotAppCommand(.stop, robot: robot?.id).perform() else {
            return .result(dialog: IntentDialog(.reachy("No app was running.")))
        }
        let title = RobotAppTitles(robot: robot?.id).title(for: name)
        return .result(dialog: IntentDialog(.reachy("Stopped \(title).")))
    }
}

public struct ToggleRobotAppIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start or stop a Reachy Mini app"
    public static let description = IntentDescription(
        "Starts an app on your robot, or stops it if it is the one already running."
    )

    @Parameter(title: "App")
    public var app: RobotAppEntity

    @Parameter(title: "Robot")
    public var robot: RobotEntity?

    public init() {}

    public init(app: RobotAppEntity) {
        self.app = app
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = try await RobotAppCommand(.toggle(name: app.name), appID: app.id, robot: robot?.id).perform()
        guard case .started = outcome else {
            return .result(dialog: IntentDialog(.reachy("Stopped \(app.title).")))
        }
        return .result(dialog: IntentDialog(.reachy("Started \(app.title).")))
    }
}
