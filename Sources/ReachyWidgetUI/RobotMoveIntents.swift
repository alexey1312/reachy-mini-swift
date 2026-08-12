import AppIntents
import ReachyDesign

/// The robot's recorded moves, as actions a person can speak or drop into a
/// shortcut.
///
/// The Moves tab was the one part of this app with no intent coverage at all,
/// while the daemon route behind it is a single call and the move index already
/// survives across launches. "Hey Siri, play the happy dance on Hey Reachy" is
/// what that gap cost.
///
/// The metadata below stays bare `LocalizedStringResource` and the dialogs take
/// `.reachy(_:)`, for the reason `RobotAppShortcutIntents` records: the first is
/// extracted into `Metadata.appintents` at build time, the second is built while
/// the intent runs.
public struct PlayMoveIntent: AppIntent {
    public static let title: LocalizedStringResource = "Play a Reachy Mini move"
    public static let description = IntentDescription(
        "Plays one of the robot's recorded moves, waking it first if it is asleep and stopping whatever it was doing."
    )

    @Parameter(title: "Move")
    public var move: MoveEntity

    @Parameter(title: "Robot")
    public var robot: RobotEntity?

    public init() {}

    public init(move: MoveEntity) {
        self.move = move
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let move = move
        try await RobotMoveCommand(.play(dataset: move.dataset, move: move.move), robot: robot?.id).perform()
        return .result(dialog: IntentDialog(.reachy("Playing \(move.title).")))
    }
}

/// No parameter for which move: the daemon has one move slot, so "stop the move"
/// names it exactly — and `GET /api/move/running` could not tell them apart in any
/// case, since it answers with task ids and nothing else.
public struct StopMoveIntent: AppIntent {
    public static let title: LocalizedStringResource = "Stop the Reachy Mini move"
    public static let description = IntentDescription(
        "Stops whichever move is playing and returns the robot to its neutral pose. Does nothing if none is."
    )

    @Parameter(title: "Robot")
    public var robot: RobotEntity?

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard try await RobotMoveCommand(.stop, robot: robot?.id).perform() == .stopped else {
            return .result(dialog: IntentDialog(.reachy("No move was playing.")))
        }
        return .result(dialog: IntentDialog(.reachy("Stopped the move.")))
    }
}
