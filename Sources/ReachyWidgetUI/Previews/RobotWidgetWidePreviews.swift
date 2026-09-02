import ReachyKit
import ReachyWidgetUI
import SwiftUI

// The medium family with an app running, beside `RobotWidgetPreviews.swift`, which
// is at the file limit. Same fixed date, same card.
// The medium family with an app running and the apps cache holding it: the app is
// drawn as a tile beside the words, the way the apps widget draws it.
#Preview("Widget — running an app, wide", traits: .sizeThatFitsLayout) {
    robotWidgetPreviewCard(
        RobotWidgetContent(
            state: .fresh(RobotSnapshot(
                robotName: "kitchen",
                isAwake: true,
                runningApp: "Hand Tracker",
                takenAt: robotWidgetPreviewDate
            )),
            apps: RobotAppsCache(
                robotID: "preview",
                installed: [
                    RobotAppSummary(
                        id: "pollen-robotics/hand-tracker",
                        name: "hand_tracker",
                        title: "Hand Tracker",
                        emoji: "🖐️"
                    ),
                ],
                takenAt: robotWidgetPreviewDate
            ),
            at: robotWidgetPreviewDate
        ),
        layout: .wide
    )
}

// The same reading with no cache — a widget woken before the app ever listed the
// robot's apps — keeps the words and draws no tile.
#Preview("Widget — running an app, wide, no cache", traits: .sizeThatFitsLayout) {
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
