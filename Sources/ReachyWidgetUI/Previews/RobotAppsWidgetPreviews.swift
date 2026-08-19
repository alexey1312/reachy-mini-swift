import ReachyKit
import ReachyWidgetUI
import SwiftUI

/// The launcher, in every state a user can land in.
///
/// Dates are fixed for the same reason `robotWidgetPreviewDate` is: the stale
/// list renders a relative time, and taking it from `Date()` would move the
/// reference image on every run. That constant is reused rather than duplicated.
///
/// Every body builds its content from `RobotAppSummary` fixtures directly and
/// names no AppIntents type: Prefire copies each body into a generated file that
/// imports only `testable_imports`.
enum AppsPreview {
    static let dance = RobotAppSummary(
        id: "pollen-robotics/dance",
        name: "reachy_mini_dance",
        title: "Dance Party",
        emoji: "💃",
        gradient: .init(from: "pink", to: "indigo")
    )
    static let faces = RobotAppSummary(
        id: "pollen-robotics/face-tracking",
        name: "face_tracking",
        title: "Face Tracking",
        emoji: "👀",
        gradient: .init(from: "blue", to: "cyan")
    )
    static let chess = RobotAppSummary(
        id: "pollen-robotics/chess",
        name: "chess",
        title: "Chess",
        emoji: "♟️",
        gradient: .init(from: "amber", to: "orange")
    )
    /// An installed app whose metadata the daemon never found: no card, so no
    /// emoji and no palette. The derived gradient is what keeps it legible.
    static let cardless = RobotAppSummary(id: "wobbler", name: "wobbler", title: "wobbler")

    static var all: [RobotAppSummary] {
        [dance, faces, chess, cardless]
    }

    static func cache(_ installed: [RobotAppSummary]? = nil, at date: Date = robotWidgetPreviewDate) -> RobotAppsCache {
        RobotAppsCache(robotID: "preview", installed: installed ?? all, takenAt: date)
    }

    static func snapshot(
        running: RobotAppSummary?,
        failed: RobotAppSummary? = nil,
        error: String? = nil
    ) -> RobotSnapshotState {
        .fresh(RobotSnapshot(
            robotName: "kitchen",
            isAwake: true,
            runningApp: running?.title,
            runningAppName: running?.name,
            failedApp: failed.map { .init(name: $0.name, title: $0.title, error: error) },
            runningAppTakenAt: running == nil && failed == nil ? nil : robotWidgetPreviewDate,
            takenAt: robotWidgetPreviewDate
        ))
    }

    static func content(
        configured: [RobotAppSummary] = [],
        cache: RobotAppsCache? = nil,
        snapshot: RobotSnapshotState = .unknown,
        launch: RobotAppLaunchState? = nil,
        hasKnownRobot: Bool = true,
        limit: Int,
        at date: Date = robotWidgetPreviewDate
    ) -> RobotAppsWidgetContent {
        RobotAppsWidgetContent(
            configured: configured,
            cache: cache ?? Self.cache(),
            snapshot: snapshot,
            launch: launch,
            hasKnownRobot: hasKnownRobot,
            limit: limit,
            at: date
        )
    }
}

/// The three families' own sizes, so a preview shows what lands on the Home
/// Screen rather than a view stretched over a device.
enum AppsPreviewSize {
    static let small = CGSize(width: 158, height: 158)
    static let medium = CGSize(width: 338, height: 158)
    static let large = CGSize(width: 338, height: 354)
}

func reachyAppsPreviewCard(_ content: RobotAppsWidgetContent, size: CGSize) -> some View {
    RobotAppsWidgetView(content: content)
        .padding()
        .frame(width: size.width, height: size.height)
        // The system container radius WidgetKit draws around a widget, not one of
        // ours — the preview stands in for a container this process never sees.
        .background(.background.secondary, in: .rect(cornerRadius: 22))
}

#Preview("Apps — small", traits: .sizeThatFitsLayout) {
    reachyAppsPreviewCard(
        AppsPreview.content(configured: [AppsPreview.dance, AppsPreview.faces], limit: 2),
        size: AppsPreviewSize.small
    )
}

// One installed app on a family with room for two. The ordinary case for a robot
// nobody has loaded a library onto, and the case the configuration used to demand
// exactly two of — which left the widget in WidgetKit's placeholder for good.
#Preview("Apps — small, one app", traits: .sizeThatFitsLayout) {
    reachyAppsPreviewCard(
        AppsPreview.content(cache: AppsPreview.cache([AppsPreview.dance]), limit: 2),
        size: AppsPreviewSize.small
    )
}

#Preview("Apps — medium", traits: .sizeThatFitsLayout) {
    reachyAppsPreviewCard(
        AppsPreview.content(configured: AppsPreview.all, limit: 4),
        size: AppsPreviewSize.medium
    )
}

// Nothing chosen yet: the robot's own list, so the widget is useful the moment it
// lands rather than after a trip through Edit Widget.
#Preview("Apps — large, unconfigured", traits: .sizeThatFitsLayout) {
    reachyAppsPreviewCard(
        AppsPreview.content(limit: 8),
        size: AppsPreviewSize.large
    )
}

#Preview("Apps — one running", traits: .sizeThatFitsLayout) {
    reachyAppsPreviewCard(
        AppsPreview.content(
            configured: AppsPreview.all,
            snapshot: AppsPreview.snapshot(running: AppsPreview.dance),
            limit: 4
        ),
        size: AppsPreviewSize.medium
    )
}

// The robot is busy with something this widget does not show, so nothing on
// screen would otherwise explain why every tile is dimmed.
#Preview("Apps — busy elsewhere", traits: .sizeThatFitsLayout) {
    reachyAppsPreviewCard(
        AppsPreview.content(
            configured: [AppsPreview.faces, AppsPreview.chess],
            snapshot: AppsPreview.snapshot(running: AppsPreview.dance),
            limit: 4
        ),
        size: AppsPreviewSize.medium
    )
}

// No spinner crosses a process boundary; the caption and WidgetKit's own dimming
// are the whole progress signal.
#Preview("Apps — starting", traits: .sizeThatFitsLayout) {
    reachyAppsPreviewCard(
        AppsPreview.content(
            configured: AppsPreview.all,
            launch: RobotAppLaunchState(
                pending: .init(appID: AppsPreview.dance.id, isStop: false, since: robotWidgetPreviewDate)
            ),
            limit: 4
        ),
        size: AppsPreviewSize.medium
    )
}

#Preview("Apps — stopping", traits: .sizeThatFitsLayout) {
    reachyAppsPreviewCard(
        AppsPreview.content(
            configured: [AppsPreview.dance, AppsPreview.faces],
            launch: RobotAppLaunchState(
                pending: .init(appID: AppsPreview.dance.id, isStop: true, since: robotWidgetPreviewDate)
            ),
            limit: 2
        ),
        size: AppsPreviewSize.small
    )
}

// An intent cannot open the app on iOS 18, so this is where the offer has to
// live: the notice explains, and the tap falls through to the widget's own URL.
#Preview("Apps — launch failed", traits: .sizeThatFitsLayout) {
    reachyAppsPreviewCard(
        AppsPreview.content(
            configured: AppsPreview.all,
            launch: RobotAppLaunchState(
                failure: .init(
                    appID: AppsPreview.dance.id,
                    message: "Could not connect to the server.",
                    at: robotWidgetPreviewDate
                )
            ),
            limit: 4
        ),
        size: AppsPreviewSize.medium
    )
}

// The app died on the robot rather than at the user's hand. The tile says that
// much, the notice says what the daemon said, and the tap falls through to the
// page carrying the logs — a tile quietly back at idle would explain nothing.
#Preview("Apps — one crashed", traits: .sizeThatFitsLayout) {
    reachyAppsPreviewCard(
        AppsPreview.content(
            configured: AppsPreview.all,
            snapshot: AppsPreview.snapshot(
                running: nil,
                failed: AppsPreview.dance,
                error: "ImportError: no module named cv2"
            ),
            limit: 4
        ),
        size: AppsPreviewSize.medium
    )
}

// The same on the smallest family, where the caption is all there is room for and
// the badge is what carries the news.
#Preview("Apps — crashed, small", traits: .sizeThatFitsLayout) {
    reachyAppsPreviewCard(
        AppsPreview.content(
            configured: [AppsPreview.dance, AppsPreview.faces],
            snapshot: AppsPreview.snapshot(running: nil, failed: AppsPreview.dance),
            limit: 2
        ),
        size: AppsPreviewSize.small
    )
}

// Configured once, removed from the robot since. The tile stays so the
// configuration is not rewritten behind the user's back.
#Preview("Apps — one uninstalled", traits: .sizeThatFitsLayout) {
    reachyAppsPreviewCard(
        AppsPreview.content(
            configured: AppsPreview.all,
            cache: AppsPreview.cache([AppsPreview.dance, AppsPreview.faces, AppsPreview.cardless]),
            limit: 4
        ),
        size: AppsPreviewSize.medium
    )
}

// A stale menu is merely old, so it still renders and still launches — it just
// says how old it is.
#Preview("Apps — old list", traits: .sizeThatFitsLayout) {
    reachyAppsPreviewCard(
        AppsPreview.content(
            cache: AppsPreview.cache(at: robotWidgetPreviewDate.addingTimeInterval(-3 * 24 * 60 * 60)),
            limit: 4
        ),
        size: AppsPreviewSize.medium
    )
}

#Preview("Apps — no robot", traits: .sizeThatFitsLayout) {
    reachyAppsPreviewCard(
        AppsPreview.content(hasKnownRobot: false, limit: 4),
        size: AppsPreviewSize.small
    )
}

#Preview("Apps — no apps yet", traits: .sizeThatFitsLayout) {
    reachyAppsPreviewCard(
        AppsPreview.content(cache: AppsPreview.cache([]), limit: 4),
        size: AppsPreviewSize.small
    )
}
