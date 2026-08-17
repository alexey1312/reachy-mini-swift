import AppIntents
import ReachyDesign

/// The robot's sounds, as actions a person can drop into a shortcut.
///
/// **Neither of these carries a Siri phrase, and that is a decision rather than an
/// omission.** `ReachyShortcuts` is at ten of ten — the system takes the first ten App
/// Shortcuts an app declares and drops the rest without saying so — so an eleventh
/// phrase would have to displace one that already works. These stay discoverable in the
/// Shortcuts app, reachable from Spotlight through `IndexedEntity`, and available as a
/// Control Centre button, which is everything except the spoken form.
///
/// The metadata below stays bare `LocalizedStringResource` and the dialogs take
/// `.reachy(_:)`, for the reason `RobotAppShortcutIntents` records: the first is
/// extracted into `Metadata.appintents` at build time, the second is built while the
/// intent runs.
public struct PlaySoundIntent: AppIntent {
    public static let title: LocalizedStringResource = "Play a Reachy Mini sound"
    public static let description = IntentDescription(
        """
        Plays a sound from the robot's library. The robot keeps sounds in temporary \
        storage, so this says so rather than falling silent when one has been forgotten.
        """
    )

    @Parameter(title: "Sound")
    public var sound: SoundEntity

    @Parameter(title: "Robot")
    public var robot: RobotEntity?

    public init() {}

    public init(sound: SoundEntity) {
        self.sound = sound
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let sound = sound
        try await RobotSoundPlayer.perform(robot: robot?.id) { player in
            try await player.play(named: sound.id)
        }
        return .result(dialog: IntentDialog(.reachy("Playing \(sound.title).")))
    }
}

/// No parameter for which sound: the daemon has one media player, so "stop the sound"
/// names it exactly — and no route reports what is in it, so a parameter could only be
/// a guess the caller had to make.
public struct StopSoundIntent: AppIntent {
    public static let title: LocalizedStringResource = "Stop the Reachy Mini sound"
    public static let description = IntentDescription(
        """
        Stops whatever the robot is playing, including the music a recorded move started. \
        Does nothing if it is already quiet.
        """
    )

    @Parameter(title: "Robot")
    public var robot: RobotEntity?

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        try await RobotSoundPlayer.perform(robot: robot?.id) { player in
            try await player.stop()
        }
        // "Stopped" rather than "there was nothing playing": nothing reports whether a
        // sound was playing, and a dialog that guessed would be wrong half the time.
        return .result(dialog: IntentDialog(.reachy("Stopped the sound.")))
    }
}
