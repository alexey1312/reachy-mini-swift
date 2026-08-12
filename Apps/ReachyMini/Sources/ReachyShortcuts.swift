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
/// described side by side there. Eight of the ten App Shortcuts an app may declare
/// are used here.
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
        AppShortcut(
            intent: ToggleRobotAppIntent(),
            phrases: ["Toggle \(\.$app) on \(.applicationName)"],
            shortTitle: "Start or stop app",
            systemImageName: "playpause.circle",
            parameterPresentation: AppShortcutParameterPresentation(
                for: \.$app,
                summary: Summary("Start or stop \(\.$app)"),
                optionsCollections: {
                    AppShortcutOptionsCollection(
                        RobotAppQuery(),
                        title: "Apps",
                        systemImageName: "square.grid.2x2"
                    )
                }
            )
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
    }
}
