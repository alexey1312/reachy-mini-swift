import AppIntents
import ReachyDesign
import ReachyWidgetUI
import SwiftUI
import WidgetKit

/// The robot's sounds, from Control Centre, the Lock Screen or the Action button.
///
/// The pair mirrors `RobotActivityControls` exactly, and for the same two reasons: a
/// configurable control may draw the name the reader chose, because that is not a claim
/// about the robot and cannot go stale; and a stop needs no parameter, because the daemon
/// has one media player and "stop the sound" names its target by being the only thing
/// there is to stop.
///
/// **Neither draws whether anything is playing, and here that is not even a choice.** No
/// route reports it — `GET /api/media/status` describes the media server, not what is
/// coming out of the speaker — so a two-state control could only ever be guessing.
struct PlaySoundControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "PlaySound", provider: Provider()) { sound in
            ControlWidgetButton(action: SoundControlConfigurationIntent(sound: sound)) {
                Label(Self.title(for: sound), systemImage: "speaker.wave.2")
            }
        }
        .displayName("Play a Reachy Mini sound")
        // Says the temporary storage out loud. A control that silently stopped working
        // after the robot restarted would read as broken rather than as empty-handed,
        // and the intent's own refusal is the only other place this is said.
        .description("Plays a sound you choose. The robot forgets uploaded sounds when it restarts.")
        // Without this the control ships unconfigured and its first tap reaches a
        // `perform` that throws `needsValueError` with nowhere in Control Centre to
        // prompt from — a button that fails in silence.
        .promptsForUserConfiguration()
    }

    /// The sound's own name once there is one, so a reader with three of these can tell
    /// them apart without opening any. Spelled out rather than inlined into the `Label`
    /// so the interpolated title stays an *argument* of the resource rather than part of
    /// its key — the rule a robot called "100% Reachy" made necessary.
    static func title(for sound: SoundEntity?) -> LocalizedStringResource {
        guard let sound else { return .reachy("Play a sound") }
        return .reachy("Play \(sound.title)")
    }

    struct Provider: AppIntentControlValueProvider {
        func previewValue(configuration: SoundControlConfigurationIntent) -> SoundEntity? {
            configuration.sound
        }

        /// Touches nothing: the configuration is the answer. So the button renders with
        /// the robot switched off, on another network, or asleep in a bag.
        func currentValue(configuration: SoundControlConfigurationIntent) async throws -> SoundEntity? {
            configuration.sound
        }
    }
}

/// Stops the speaker, whatever put something on it — a soundboard tap, or the music a
/// recorded move started and the daemon never ends by itself.
///
/// It is not a quieter spelling of `StopMoveControl`: that one cancels the motion and
/// parks the robot, and the two are separate daemon tasks precisely because a track
/// outlives the dance it came with.
struct StopSoundControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "StopSound") {
            ControlWidgetButton(action: StopSoundIntent()) {
                Label(.reachy("Stop the sound"), systemImage: "speaker.slash")
            }
        }
        .displayName("Stop the Reachy Mini sound")
        .description("Stops whatever the robot is playing, including a move's music. Does nothing if it is quiet.")
    }
}
