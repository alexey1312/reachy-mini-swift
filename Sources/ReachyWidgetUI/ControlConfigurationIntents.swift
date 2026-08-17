import AppIntents
import ReachyDesign

/// What "Choose a move" and "Choose an app" offer when a control is configured —
/// and what the tap then runs.
///
/// **One type each rather than a picker plus an action, unlike the widget's.**
/// `RobotAppsConfigurationIntent` is a `WidgetConfigurationIntent` and performs
/// nothing: a widget's configuration decides what a *view* draws, and the tap on
/// it runs `RobotAppTileIntent`. A control has no view to decide — its
/// configuration **is** its argument, so the intent that holds the parameter is
/// the one with something to do.
///
/// Both are `isDiscoverable = false` for the reason `RobotAppTileIntent` is: these
/// are a control's own bookkeeping, and Shortcuts is already offered the same work
/// through `PlayMoveIntent` and `ToggleRobotAppIntent`, which is where a spoken
/// phrase belongs. Neither shares code with its twin beyond the command — the
/// split every intent in this target makes.
///
/// **These do depend on metadata extraction**, which the widget's *buttons*
/// deliberately do not. A configuration intent is how the system builds the
/// control's Edit sheet, so a failed extraction costs the picker; that is the
/// trade a configurable control makes and the reason both are asserted by
/// `Scripts/check-appintents-metadata.sh` rather than left to a green build.
public struct MoveControlConfigurationIntent: ControlConfigurationIntent {
    public static let title: LocalizedStringResource = "Play a chosen Reachy Mini move"
    public static let description = IntentDescription(
        "Plays the move this control is set to, waking the robot first if it is asleep."
    )
    public static let isDiscoverable = false

    @Parameter(title: "Move")
    public var move: MoveEntity?

    /// Optional, like the robot parameter on all six intents next door: an unfilled
    /// one means the last robot this app connected to, so somebody with one robot
    /// configures a move and nothing else.
    @Parameter(title: "Robot")
    public var robot: RobotEntity?

    public init() {}

    public init(move: MoveEntity?, robot: RobotEntity? = nil) {
        self.move = move
        self.robot = robot
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let move else {
            throw $move.needsValueError()
        }
        try await RobotMoveCommand(.play(dataset: move.dataset, move: move.move), robot: robot?.id).perform()
        return .result(dialog: IntentDialog(.reachy("Playing \(move.title).")))
    }
}

/// The app half. Toggling rather than starting, because a control is tapped from
/// the same place twice: `RobotAppCommand.toggle` stops the app if it is the one
/// already running, which is what the widget's tile means by a tap too.
///
/// It draws no state while doing it — `RobotPowerControls` explains why a control
/// in this process may not claim to know what the robot is up to. This one names
/// an app and flips it; it is not the two-state toggle #66 asks about, and cannot
/// be for that reason.
public struct RobotAppControlConfigurationIntent: ControlConfigurationIntent {
    public static let title: LocalizedStringResource = "Start or stop a chosen Reachy Mini app"
    public static let description = IntentDescription(
        "Starts the app this control is set to, or stops it if it is the one already running."
    )
    public static let isDiscoverable = false

    @Parameter(title: "App")
    public var app: RobotAppEntity?

    @Parameter(title: "Robot")
    public var robot: RobotEntity?

    public init() {}

    public init(app: RobotAppEntity?, robot: RobotEntity? = nil) {
        self.app = app
        self.robot = robot
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let app else {
            throw $app.needsValueError()
        }
        let outcome = try await RobotAppCommand(.toggle(name: app.name), appID: app.id, robot: robot?.id).perform()
        guard case .started = outcome else {
            return .result(dialog: IntentDialog(.reachy("Stopped \(app.title).")))
        }
        return .result(dialog: IntentDialog(.reachy("Started \(app.title).")))
    }
}
