// Control Centre controls, and the Mac does not get them. `ControlWidget` is
// `@available(iOS 18.0, macOS 26.0, …)` rather than iOS-only as it once was, but
// this app deploys to macOS 15 — so the ceiling is the deployment target, not the
// platform. Raise it to 26 and these can come back behind an availability check.
#if os(iOS)
    import AppIntents
    import ReachyDesign
    import ReachyWidgetUI
    import SwiftUI
    import WidgetKit

    /// What the robot is *doing*, from Control Centre — the neighbours of the three
    /// power controls next door.
    ///
    /// `RobotPowerControls` argues that a control here must be a button and never a
    /// toggle, because a `StaticControlConfiguration` has no data behind it and this
    /// process cannot ask the robot what it is up to. Both controls in this file are
    /// imperatives with no parameter at all, which is the case that reasoning was
    /// written for: "stop whatever is running" names its target by being the only
    /// thing there is to stop, so there is nothing to draw and nothing to go stale.
    ///
    /// The two glyphs are deliberately close — both actions are a stop, and pretending
    /// otherwise would be inventing a distinction. What tells them apart is the word,
    /// which is the whole of what Control Centre's gallery shows.
    struct StopMoveControl: ControlWidget {
        var body: some ControlWidgetConfiguration {
            StaticControlConfiguration(kind: "StopMove") {
                ControlWidgetButton(action: StopMoveIntent()) {
                    Label(.reachy("Stop the move"), systemImage: "stop.circle")
                }
            }
            .displayName("Stop the Reachy Mini move")
            // Says the parking out loud: `RobotMovePlayer` returns the robot to its
            // neutral pose after a stop, which is not something a reader would assume
            // of a button called Stop.
            .description("Stops whichever move is playing and returns the robot to its neutral pose.")
        }
    }

    /// The robot runs one app at a time, so this needs no more of a target than the
    /// move control does — `StopRobotAppIntent` says so where it declines to take a
    /// parameter, and the reasoning is the same: asking which app is asking somebody
    /// to repeat something the robot already knows.
    ///
    /// Stopping parks the robot at zero and never sleeps it (`RobotAppLauncher.stop()`),
    /// which is why this is not a quieter spelling of the Sleep control beside it.
    struct StopRobotAppControl: ControlWidget {
        var body: some ControlWidgetConfiguration {
            StaticControlConfiguration(kind: "StopRobotApp") {
                ControlWidgetButton(action: StopRobotAppIntent()) {
                    Label(.reachy("Stop the app"), systemImage: "stop.fill")
                }
            }
            .displayName("Stop the Reachy Mini app")
            .description("Stops whichever app is running on your robot and parks it. Does nothing if none is.")
        }
    }

    /// The other half of the file, and the rule above bends exactly once for it.
    ///
    /// A `StaticControlConfiguration` may not draw state because this process cannot
    /// ask the robot anything. An `AppIntentControlConfiguration` reads its own saved
    /// configuration, which is not a claim about the robot at all — it is what the
    /// reader chose, and it cannot go stale. So these two draw a name and stay
    /// imperatives: the button says which move it plays, never whether one is playing.
    ///
    /// **The provider touches nothing.** It answers out of the configuration it is
    /// handed, so a control renders on a phone with the robot switched off, on another
    /// network, or asleep in a bag — the same rule `RobotAppQuery.entities(for:)`
    /// follows for a widget's saved selection.
    struct PlayMoveControl: ControlWidget {
        var body: some ControlWidgetConfiguration {
            AppIntentControlConfiguration(kind: "PlayMove", provider: Provider()) { move in
                ControlWidgetButton(action: MoveControlConfigurationIntent(move: move)) {
                    Label(Self.title(for: move), systemImage: "play.circle")
                }
            }
            .displayName("Play a Reachy Mini move")
            .description("Plays a move you choose. Wakes the robot first if it is asleep.")
            // Without this the control ships unconfigured and its first tap is an
            // error the reader has no way to read — `perform` throws
            // `needsValueError` with nowhere in Control Centre to prompt from.
            .promptsForUserConfiguration()
        }

        /// The move's own name once there is one, so a reader with three of these can
        /// tell them apart without opening any of them. Spelled out rather than
        /// inlined into the `Label` so the interpolated title stays an *argument* of
        /// the resource rather than part of its key — the rule
        /// `RobotStatusIntents` follows for a robot somebody called "100% Reachy".
        static func title(for move: MoveEntity?) -> LocalizedStringResource {
            guard let move else { return .reachy("Play a move") }
            return .reachy("Play \(move.title)")
        }

        struct Provider: AppIntentControlValueProvider {
            func previewValue(configuration: MoveControlConfigurationIntent) -> MoveEntity? {
                configuration.move
            }

            func currentValue(configuration: MoveControlConfigurationIntent) async throws -> MoveEntity? {
                configuration.move
            }
        }
    }

    /// Named apps get the same treatment, and this is the one #66 calls a toggle.
    /// It is not one: it names an app and flips it, which is what the widget's tile
    /// means by a tap. A control that drew "running" or "stopped" would be claiming
    /// to know something this process cannot ask about.
    struct ToggleRobotAppControl: ControlWidget {
        var body: some ControlWidgetConfiguration {
            AppIntentControlConfiguration(kind: "ToggleRobotApp", provider: Provider()) { app in
                ControlWidgetButton(action: RobotAppControlConfigurationIntent(app: app)) {
                    Label(Self.title(for: app), systemImage: "app.badge")
                }
            }
            .displayName("Start a Reachy Mini app")
            // Says the second tap out loud: the word on the button is "Start", and a
            // control that quietly stopped what it started would read as broken.
            .description("Starts an app you choose, or stops it if it is the one already running.")
            .promptsForUserConfiguration()
        }

        /// `RobotAppEntity.title` and never the entry point name: a status the daemon
        /// sends carries the Python symbol (`dance_party`), and `RobotAppTitles` exists
        /// because nothing user-facing may speak it. An entity has been through the
        /// picker, so its title is already the store's.
        static func title(for app: RobotAppEntity?) -> LocalizedStringResource {
            guard let app else { return .reachy("Start an app") }
            return .reachy("Start \(app.title)")
        }

        struct Provider: AppIntentControlValueProvider {
            func previewValue(configuration: RobotAppControlConfigurationIntent) -> RobotAppEntity? {
                configuration.app
            }

            func currentValue(configuration: RobotAppControlConfigurationIntent) async throws -> RobotAppEntity? {
                configuration.app
            }
        }
    }
#endif
