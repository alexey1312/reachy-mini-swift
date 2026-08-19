import ReachyKit
import ReachyWidgetUI
import SwiftUI

/// The macOS menu bar popover, in every state a user can land in.
///
/// **What these references prove, and what they cannot.** They render on an *iOS*
/// simulator at iPhone 16 Pro and iPad Pro 11 traits, so they certify the layout,
/// the wording, which rows appear in which state and that the action button is
/// conditional. They say nothing about the AppKit chrome behind a `MenuBarExtra`,
/// about its sizing, or about the menu bar label — the same standing
/// `reachySheet()` has, and all three are device checks.
///
/// Dates are fixed for the reason `robotWidgetPreviewDate` records: the stale state
/// renders a relative time, and taking it from `Date()` would move the image on
/// every run. That constant and the `AppsPreview` fixtures are reused rather than
/// duplicated — both are visible target-wide, which is what Prefire needs, since it
/// copies each body into a generated file of its own.
func menuBarPreviewCard(_ content: MenuBarContent) -> some View {
    MenuBarContentView(content: content) { _ in }
        // The popover corner AppKit draws around a `MenuBarExtra`, not one of
        // ours — the preview stands in for chrome this process never sees.
        .background(.background.secondary, in: .rect(cornerRadius: 12))
}

func menuBarPreviewContent(
    snapshot: RobotSnapshotState,
    power: RobotPowerTransitionState? = nil,
    launch: RobotAppLaunchState? = nil,
    cache: RobotAppsCache? = AppsPreview.cache(),
    hasKnownRobot: Bool = true,
    at date: Date = robotWidgetPreviewDate
) -> MenuBarContent {
    MenuBarContent(
        snapshot: snapshot,
        power: power,
        launch: launch,
        cache: cache,
        hasKnownRobot: hasKnownRobot,
        at: date
    )
}

func menuBarPreviewSnapshot(isAwake: Bool) -> RobotSnapshotState {
    .fresh(RobotSnapshot(
        robotName: "kitchen",
        isAwake: isAwake,
        runningApp: nil,
        takenAt: robotWidgetPreviewDate
    ))
}

#Preview("Menu bar — awake", traits: .sizeThatFitsLayout) {
    menuBarPreviewCard(menuBarPreviewContent(snapshot: menuBarPreviewSnapshot(isAwake: true)))
}

#Preview("Menu bar — asleep", traits: .sizeThatFitsLayout) {
    menuBarPreviewCard(menuBarPreviewContent(snapshot: menuBarPreviewSnapshot(isAwake: false)))
}

// One app holds the robot: the only row with a caption, and the reason this
// surface tones "Running" green where a widget tile leaves it quiet.
#Preview("Menu bar — running an app", traits: .sizeThatFitsLayout) {
    menuBarPreviewCard(menuBarPreviewContent(snapshot: AppsPreview.snapshot(running: AppsPreview.dance)))
}

// A tap that has not come back yet. The button is gone rather than dimmed — the
// same call `RobotWidgetContent` makes for the widget.
#Preview("Menu bar — waking up", traits: .sizeThatFitsLayout) {
    menuBarPreviewCard(menuBarPreviewContent(
        snapshot: menuBarPreviewSnapshot(isAwake: false),
        power: robotWidgetPreviewTransition(.wakingUp)
    ))
}

// A refused command. The button stays, because the robot is still there to try
// again on, and the message is the one the command itself wrote to the store —
// which is why this popover needs no error slot of its own.
#Preview("Menu bar — command failed", traits: .sizeThatFitsLayout) {
    menuBarPreviewCard(menuBarPreviewContent(
        snapshot: menuBarPreviewSnapshot(isAwake: true),
        power: RobotPowerTransitionState(
            failure: .init(message: "The robot took too long to answer.", at: robotWidgetPreviewDate)
        )
    ))
}

// An app that died on its own, which the row says in one word and the notice
// under the list explains.
#Preview("Menu bar — app crashed", traits: .sizeThatFitsLayout) {
    menuBarPreviewCard(menuBarPreviewContent(
        snapshot: AppsPreview.snapshot(
            running: nil,
            failed: AppsPreview.faces,
            error: "ImportError: no module named cv2"
        )
    ))
}

// The state the popover spends most of its life in: nobody has opened a window
// for a while, so it reports when it last looked rather than what the robot is
// doing — and offers `.wake` and never `.sleep`.
#Preview("Menu bar — last seen", traits: .sizeThatFitsLayout) {
    menuBarPreviewCard(menuBarPreviewContent(
        snapshot: .stale(RobotSnapshot(
            robotName: "kitchen",
            isAwake: true,
            runningApp: nil,
            takenAt: robotWidgetPreviewDate
        )),
        at: robotWidgetPreviewDate.addingTimeInterval(2 * 60 * 60)
    ))
}

// Nothing to command and nothing to list. The one state where the popover is a
// single sentence and a way into the app.
#Preview("Menu bar — no robot", traits: .sizeThatFitsLayout) {
    menuBarPreviewCard(menuBarPreviewContent(
        snapshot: .unknown,
        cache: nil,
        hasKnownRobot: false
    ))
}
