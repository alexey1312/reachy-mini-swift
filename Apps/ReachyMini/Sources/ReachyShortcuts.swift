import AppIntents
import ReachyWidgetUI

/// Siri phrases for the intents themselves, which live in `ReachyWidgetUI` so the
/// widget extension can reach them too.
///
/// This provider stays in the app: Apple resolves shortcuts from the main bundle,
/// and one declared in an extension is not offered.
///
/// **These do not reach the Home Screen icon's menu.** That menu is UIKit's, holds
/// its own items, and is built by `ReachyQuickAction` — the two systems are
/// described side by side there.
///
/// **All ten App Shortcuts an app may declare are now used**, so the next intent
/// worth speaking has to displace one rather than join them. The system takes the
/// first ten and drops the rest silently, which is exactly the kind of failure that
/// shows up as "Siri stopped hearing that phrase" months later — count before
/// adding.
///
/// **`PlaySoundIntent`, `StopSoundIntent` and `ToggleRobotAppIntent` are the three
/// turned away by that**, and each was a decision rather than an oversight: displacing
/// a working phrase for a new one is a trade nobody asked for. The two sound intents
/// stay discoverable in the Shortcuts app, reachable from Spotlight as `SoundEntity`
/// rows, and available as Control Centre buttons — everything but the spoken form.
/// `ToggleRobotAppIntent` gave its slot to `CallRobotIntent` (#78): its spoken form
/// duplicated the Start/Stop pair above it, while its real home — the Control Centre
/// toggle button — is untouched. Whichever of the ten below is judged least used is
/// where the next phrase would go.
///
/// `\(.applicationName)` is `CFBundleDisplayName`, so every phrase below reads
/// "… Hey Reachy". `INAlternativeAppNames` in `Project.swift` adds "Reachy" beside
/// it, which is the spoken form these were written for; changing the display name
/// silently rewrites all eight phrases.
struct ReachyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WakeRobotIntent(),
            phrases: ["Wake up \(.applicationName)"],
            shortTitle: "Wake up",
            systemImageName: "figure.wave"
        )
        AppShortcut(
            intent: SleepRobotIntent(),
            phrases: ["Put \(.applicationName) to sleep"],
            shortTitle: "Sleep",
            systemImageName: "moon.zzz.fill"
        )
        AppShortcut(
            intent: PowerOffRobotIntent(),
            phrases: ["Power off \(.applicationName)"],
            shortTitle: "Power off",
            systemImageName: "power"
        )
        // Siri fills the app slot from `RobotAppQuery.suggestedEntities()`, so a
        // robot that cannot be reached leaves the phrase with nothing to match. The
        // action itself is unaffected — the Shortcuts app builds its picker when
        // the shortcut is edited, not when it is spoken.
        AppShortcut(
            intent: StartRobotAppIntent(),
            phrases: ["Start \(\.$app) on \(.applicationName)"],
            shortTitle: "Start app",
            systemImageName: "play.circle",
            parameterPresentation: AppShortcutParameterPresentation(
                for: \.$app,
                summary: Summary("Start \(\.$app)"),
                optionsCollections: {
                    AppShortcutOptionsCollection(
                        RobotAppQuery(),
                        title: "Apps",
                        systemImageName: "square.grid.2x2"
                    )
                }
            )
        )
        AppShortcut(
            intent: StopRobotAppIntent(),
            phrases: ["Stop the app on \(.applicationName)"],
            shortTitle: "Stop app",
            systemImageName: "stop.circle"
        )
        // "Call the robot" is what opening the camera and unmuting is; the
        // phrase lands in `CallRequestInbox` and `RootCallLifecycle` does the
        // rest (#78). This is the one shortcut whose intent lives in the app
        // target rather than in `ReachyWidgetUI` — its own header says why.
        AppShortcut(
            intent: CallRobotIntent(),
            phrases: ["Call \(.applicationName)"],
            shortTitle: "Call",
            systemImageName: "video.fill"
        )
        // The move slot is filled from `MoveEntityQuery`, which reads the cached
        // index and never the robot — so unlike the app phrases above, this one has
        // something to match whether or not the robot is reachable. What it needs
        // instead is the app to have listed that library at least once.
        AppShortcut(
            intent: PlayMoveIntent(),
            phrases: ["Play \(\.$move) on \(.applicationName)"],
            shortTitle: "Play move",
            systemImageName: "figure.dance",
            parameterPresentation: AppShortcutParameterPresentation(
                for: \.$move,
                summary: Summary("Play \(\.$move)"),
                optionsCollections: {
                    AppShortcutOptionsCollection(
                        MoveEntityQuery(),
                        title: "Moves",
                        systemImageName: "music.note.list"
                    )
                }
            )
        )
        AppShortcut(
            intent: StopMoveIntent(),
            phrases: ["Stop the move on \(.applicationName)"],
            shortTitle: "Stop move",
            systemImageName: "stop.circle"
        )
        // The two that answer rather than command, and the only ones here that
        // reach no robot: both reply out of the App Group snapshot, so they are
        // instant and cannot fail on an unreachable robot. What they cost instead
        // is honesty about age — `RobotStatusReport` is where that is enforced.
        AppShortcut(
            intent: RobotAwakeIntent(),
            phrases: ["Is \(.applicationName) awake"],
            shortTitle: "Is it awake",
            systemImageName: "questionmark.circle"
        )
        AppShortcut(
            intent: RunningAppIntent(),
            phrases: ["What is running on \(.applicationName)"],
            shortTitle: "What is running",
            systemImageName: "questionmark.app"
        )
    }
}
