import ReachyKit
import ReachyWidgetUI
import SwiftUI

/// Every date here is fixed. The stale state renders a relative time, and taking
/// it from `Date()` would move the reference image on every run.
let robotWidgetPreviewDate = Date(timeIntervalSince1970: 1_800_000_000)

/// The system-family sizes come from `AppsPreviewSize` next door — the apps
/// previews already reuse `robotWidgetPreviewDate` in the other direction, so one
/// set of widget dimensions serves both files. The three accessory sizes have no
/// twin there, because no other widget offers those families.
enum AccessoryPreviewSize {
    static let circular = CGSize(width: 76, height: 76)
    static let rectangular = CGSize(width: 172, height: 76)
    /// One line beside the clock. The width is the frame it is given rather than
    /// anything the system guarantees — an inline widget is laid out by the Lock
    /// Screen, and this only has to be wide enough to show whether the text fits.
    static let inline = CGSize(width: 200, height: 26)
}

func robotWidgetPreviewCard(
    _ content: RobotWidgetContent,
    layout: RobotWidgetView.Layout = .compact
) -> some View {
    let size = robotWidgetPreviewSize(for: layout)
    return RobotWidgetView(content: content, layout: layout)
        // An accessory family is a fraction of the size, so the system padding
        // would be most of it.
        .padding(robotWidgetPreviewPadding(for: layout))
        // A widget's own size, so the preview shows what the user gets rather than
        // a view stretched over a device.
        .frame(width: size.width, height: size.height)
        .background(.background.secondary, in: .rect(cornerRadius: 22))
}

private func robotWidgetPreviewSize(for layout: RobotWidgetView.Layout) -> CGSize {
    switch layout {
    case .compact: AppsPreviewSize.small
    case .wide: CGSize(width: AppsPreviewSize.medium.width, height: AppsPreviewSize.small.height)
    case .circular: AccessoryPreviewSize.circular
    case .rectangular: AccessoryPreviewSize.rectangular
    case .inline: AccessoryPreviewSize.inline
    }
}

private func robotWidgetPreviewPadding(for layout: RobotWidgetView.Layout) -> CGFloat {
    switch layout {
    case .compact, .wide: 16
    case .circular, .rectangular: 4
    case .inline: 0
    }
}

/// A robot mid-transition, which is the state the widget holds for up to ninety
/// seconds after a tap and the one nothing used to be able to show.
func robotWidgetPreviewTransition(_ transition: RobotSession.PowerTransition) -> RobotPowerTransitionState {
    RobotPowerTransitionState(pending: .init(transition: transition, since: robotWidgetPreviewDate))
}

#Preview("Widget — no robot", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(RobotWidgetContent(state: .unknown, at: robotWidgetPreviewDate))
}

#Preview("Widget — awake", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(RobotWidgetContent(
        state: .fresh(RobotSnapshot(
            robotName: "kitchen",
            isAwake: true,
            runningApp: nil,
            takenAt: robotWidgetPreviewDate
        )),
        at: robotWidgetPreviewDate
    ))
}

#Preview("Widget — asleep", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(RobotWidgetContent(
        state: .fresh(RobotSnapshot(
            robotName: "kitchen",
            isAwake: false,
            runningApp: nil,
            takenAt: robotWidgetPreviewDate
        )),
        at: robotWidgetPreviewDate
    ))
}

#Preview("Widget — running an app", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(RobotWidgetContent(
        state: .fresh(RobotSnapshot(
            robotName: "kitchen",
            isAwake: true,
            runningApp: "Hand Tracker",
            takenAt: robotWidgetPreviewDate
        )),
        at: robotWidgetPreviewDate
    ))
}

// An app that died on its own. Falling back to "Awake" here would be the widget
// pretending nothing happened.
#Preview("Widget — app crashed", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(RobotWidgetContent(
        state: .fresh(RobotSnapshot(
            robotName: "kitchen",
            isAwake: true,
            runningApp: nil,
            failedApp: .init(name: "hand_tracker", title: "Hand Tracker", error: "ImportError: no module named cv2"),
            runningAppTakenAt: robotWidgetPreviewDate,
            takenAt: robotWidgetPreviewDate
        )),
        at: robotWidgetPreviewDate
    ))
}

// The state the widget spends most of its life in: nobody has opened the app for
// a while, so it reports when it last looked instead of what the robot is doing.
#Preview("Widget — last seen", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(RobotWidgetContent(
        state: .stale(RobotSnapshot(
            robotName: "kitchen",
            isAwake: true,
            runningApp: nil,
            takenAt: robotWidgetPreviewDate
        )),
        at: robotWidgetPreviewDate.addingTimeInterval(2 * 60 * 60)
    ))
}

// Daemon 1.9.0 reports an empty name and cannot be renamed, so this is what most
// robots actually look like.
#Preview("Widget — unnamed robot", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(RobotWidgetContent(
        state: .fresh(RobotSnapshot(robotName: nil, isAwake: true, runningApp: nil, takenAt: robotWidgetPreviewDate)),
        at: robotWidgetPreviewDate
    ))
}

// The medium family, which until now rendered the compact layout stretched over
// twice the width and had no reference at all.
#Preview("Widget — awake, wide", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(
        RobotWidgetContent(
            state: .fresh(RobotSnapshot(
                robotName: "kitchen",
                isAwake: true,
                runningApp: nil,
                takenAt: robotWidgetPreviewDate
            )),
            at: robotWidgetPreviewDate
        ),
        layout: .wide
    )
}

#Preview("Widget — asleep, wide", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(
        RobotWidgetContent(
            state: .fresh(RobotSnapshot(
                robotName: "kitchen",
                isAwake: false,
                runningApp: nil,
                takenAt: robotWidgetPreviewDate
            )),
            at: robotWidgetPreviewDate
        ),
        layout: .wide
    )
}

// "Go to sleep" over a running app — the destructive tap, and the one state where
// the wide layout has a second line the compact one drops.
#Preview("Widget — running an app, wide", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(
        RobotWidgetContent(
            state: .fresh(RobotSnapshot(
                robotName: "kitchen",
                isAwake: true,
                runningApp: "Hand Tracker",
                takenAt: robotWidgetPreviewDate
            )),
            at: robotWidgetPreviewDate
        ),
        layout: .wide
    )
}

// A cold backend start: ninety seconds during which `resume()` has already
// returned and nothing else would say the robot is on its way.
#Preview("Widget — starting up", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(RobotWidgetContent(
        state: .fresh(RobotSnapshot(
            robotName: "kitchen",
            isAwake: false,
            runningApp: nil,
            takenAt: robotWidgetPreviewDate
        )),
        power: robotWidgetPreviewTransition(.startingBackend),
        at: robotWidgetPreviewDate
    ))
}

#Preview("Widget — going to sleep", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(RobotWidgetContent(
        state: .fresh(RobotSnapshot(
            robotName: "kitchen",
            isAwake: true,
            runningApp: nil,
            takenAt: robotWidgetPreviewDate
        )),
        power: robotWidgetPreviewTransition(.goingToSleep),
        at: robotWidgetPreviewDate
    ))
}

// MARK: - Accessory families

//
// The Lock Screen and StandBy. **What these references can and cannot prove:**
// the layout, the wording and what each family drops are all here, and the
// rendering is not — `AccessoryWidgetBackground` is a system material, and a
// material does not render headless (`ReachyDesign/AGENTS.md`). The vibrant
// treatment the Lock Screen applies is a device check.

#Preview("Widget — circular, awake", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(
        RobotWidgetContent(
            state: .fresh(RobotSnapshot(
                robotName: "kitchen",
                isAwake: true,
                runningApp: nil,
                takenAt: robotWidgetPreviewDate
            )),
            at: robotWidgetPreviewDate
        ),
        layout: .circular
    )
}

#Preview("Widget — circular, asleep", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(
        RobotWidgetContent(
            state: .fresh(RobotSnapshot(
                robotName: "kitchen",
                isAwake: false,
                runningApp: nil,
                takenAt: robotWidgetPreviewDate
            )),
            at: robotWidgetPreviewDate
        ),
        layout: .circular
    )
}

// The longest title the ring has to hold, and the one that says whether
// `minimumScaleFactor` is doing its job.
#Preview("Widget — circular, running an app", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(
        RobotWidgetContent(
            state: .fresh(RobotSnapshot(
                robotName: "kitchen",
                isAwake: true,
                runningApp: "Hand Tracker",
                takenAt: robotWidgetPreviewDate
            )),
            at: robotWidgetPreviewDate
        ),
        layout: .circular
    )
}

#Preview("Widget — circular, no robot", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(
        RobotWidgetContent(state: .unknown, at: robotWidgetPreviewDate),
        layout: .circular
    )
}

#Preview("Widget — rectangular, awake", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(
        RobotWidgetContent(
            state: .fresh(RobotSnapshot(
                robotName: "kitchen",
                isAwake: true,
                runningApp: nil,
                takenAt: robotWidgetPreviewDate
            )),
            at: robotWidgetPreviewDate
        ),
        layout: .rectangular
    )
}

#Preview("Widget — rectangular, asleep", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(
        RobotWidgetContent(
            state: .fresh(RobotSnapshot(
                robotName: "kitchen",
                isAwake: false,
                runningApp: nil,
                takenAt: robotWidgetPreviewDate
            )),
            at: robotWidgetPreviewDate
        ),
        layout: .rectangular
    )
}

#Preview("Widget — rectangular, running an app", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(
        RobotWidgetContent(
            state: .fresh(RobotSnapshot(
                robotName: "kitchen",
                isAwake: true,
                runningApp: "Hand Tracker",
                takenAt: robotWidgetPreviewDate
            )),
            at: robotWidgetPreviewDate
        ),
        layout: .rectangular
    )
}

// The state the Lock Screen spends most of its life in, and the one that needs
// two lines: nobody has opened the app for a while, so it reports when it last
// looked rather than what the robot is doing.
#Preview("Widget — rectangular, last seen", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(
        RobotWidgetContent(
            state: .stale(RobotSnapshot(
                robotName: "kitchen",
                isAwake: true,
                runningApp: nil,
                takenAt: robotWidgetPreviewDate
            )),
            at: robotWidgetPreviewDate.addingTimeInterval(2 * 60 * 60)
        ),
        layout: .rectangular
    )
}

#Preview("Widget — inline, awake", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(
        RobotWidgetContent(
            state: .fresh(RobotSnapshot(
                robotName: "kitchen",
                isAwake: true,
                runningApp: nil,
                takenAt: robotWidgetPreviewDate
            )),
            at: robotWidgetPreviewDate
        ),
        layout: .inline
    )
}

#Preview("Widget — inline, running an app", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(
        RobotWidgetContent(
            state: .fresh(RobotSnapshot(
                robotName: "kitchen",
                isAwake: true,
                runningApp: "Hand Tracker",
                takenAt: robotWidgetPreviewDate
            )),
            at: robotWidgetPreviewDate
        ),
        layout: .inline
    )
}

#Preview("Widget — inline, no robot", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(
        RobotWidgetContent(state: .unknown, at: robotWidgetPreviewDate),
        layout: .inline
    )
}

// A refused command. The button stays, because the robot is still there to try
// again on — unlike a transition, which is the one state with nothing to tap.
#Preview("Widget — command failed", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(RobotWidgetContent(
        state: .fresh(RobotSnapshot(
            robotName: "kitchen",
            isAwake: true,
            runningApp: nil,
            takenAt: robotWidgetPreviewDate
        )),
        power: RobotPowerTransitionState(
            failure: .init(message: "The robot took too long to answer.", at: robotWidgetPreviewDate)
        ),
        at: robotWidgetPreviewDate
    ))
}
