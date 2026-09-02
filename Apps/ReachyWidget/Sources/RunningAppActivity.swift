#if os(iOS)
    import ActivityKit
    import AppIntents
    import ReachyDesign
    import ReachyKit
    import ReachyWidgetUI
    import SwiftUI
    import WidgetKit

    /// The running-app card, in the four presentations ActivityKit asks for.
    ///
    /// iOS only, and not by preference: the macOS SDK ships ActivityKit for Mac
    /// Catalyst alone, and this app's Mac target is native. So **only
    /// `mise run build:app:ios` compiles this file** — a macOS build reports success
    /// over every line of it, which is the same trap the nine Control Centre controls
    /// already carry.
    ///
    /// Every slot hands its work to `RunningAppActivityView`, which takes its layout
    /// as an argument. Nothing here decides anything: the app resolved the caption,
    /// the tone and whether a Stop can be honoured before it ever handed the content
    /// over, because a Live Activity has no network and no timeline to ask with.
    struct RunningAppActivity: Widget {
        var body: some WidgetConfiguration {
            ActivityConfiguration(for: RunningAppActivityAttributes.self) { context in
                view(context, layout: .lockScreen)
                    .reachyTheme(ThemeStore(defaults: KnownRobots.defaults).theme)
                    // Every pixel the Stop button does not claim opens the app at the
                    // running-app page — which is where a robot the intent cannot
                    // reach over the LAN is actually dealt with, and where the whole
                    // crash output is readable.
                    .widgetURL(ReachyDeepLink.runningApp.url)
            } dynamicIsland: { context in
                DynamicIsland {
                    DynamicIslandExpandedRegion(.leading) {
                        view(context, layout: .expandedLeading)
                    }
                    DynamicIslandExpandedRegion(.trailing) {
                        view(context, layout: .expandedTrailing)
                    }
                    DynamicIslandExpandedRegion(.bottom) {
                        view(context, layout: .expandedBottom)
                    }
                } compactLeading: {
                    view(context, layout: .compactLeading)
                } compactTrailing: {
                    view(context, layout: .compactTrailing)
                } minimal: {
                    view(context, layout: .minimal)
                }
                .widgetURL(ReachyDeepLink.runningApp.url)
                .keylineTint(context.state.isFailed ? .red : nil)
            }
        }

        /// One builder for all seven slots, so a change to how the card is fed cannot
        /// reach one of them and miss another.
        private func view(
            _ context: ActivityViewContext<RunningAppActivityAttributes>,
            layout: RunningAppActivityLayout
        ) -> some View {
            RunningAppActivityView(
                app: context.attributes.app,
                content: context.state,
                // The system's own answer to "has this content stopped moving",
                // driven by the stale date the app set. It is the only scheduled
                // change a card gets with no process running, which is why the view
                // takes it rather than trying to work it out from a timestamp.
                isStale: context.isStale,
                layout: layout
            ) {
                AnyView(stop(context))
            }
        }

        /// A `LiveActivityIntent`, so the system performs it in the **app's** process
        /// rather than in this one — which is where the Local Network permission was
        /// granted and where the session lives.
        private func stop(_ context: ActivityViewContext<RunningAppActivityAttributes>) -> some View {
            Button(intent: StopRunningAppActivityIntent(robot: context.attributes.app.robotID)) {
                Label(.reachy("Stop"), systemImage: "stop.fill")
                    .labelStyle(.iconOnly)
            }
            .tint(Tone.danger.style)
            .buttonBorderShape(.circle)
        }
    }
#endif
