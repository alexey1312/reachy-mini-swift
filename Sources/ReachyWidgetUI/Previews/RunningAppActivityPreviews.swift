import Prefire
import ReachyKit
import ReachyWidgetUI
import SwiftUI

/// The same fixed instant every other widget preview uses. The stale card renders a
/// relative time, so a date taken from `Date()` would move its reference on every
/// run — and unlike a widget, an activity's age is drawn by the *system*, which is
/// exactly why it has to be pinned here.
let runningAppActivityPreviewDate = robotWidgetPreviewDate

/// Live Activity geometry, and it is **not measured**.
///
/// The Lock Screen presentation is laid out by the system inside a container this
/// process never sees; what is documented is only the ceiling — above 160 pt the
/// card is truncated. So these are the sizes the references are captured at, not a
/// claim about what a device draws. Confirming the real height is a device check,
/// like every other thing about this surface.
enum RunningAppActivityPreviewSize {
    static let lockScreen = CGSize(width: 360, height: 96)
    static let expanded = CGSize(width: 360, height: 64)
    static let compact = CGSize(width: 44, height: 36)
    static let minimal = CGSize(width: 36, height: 36)
}

func runningAppActivityPreviewCard(
    _ content: RunningAppActivityContent,
    app: RunningAppActivityApp = .previewDancing,
    isStale: Bool = false,
    layout: RunningAppActivityLayout = .lockScreen
) -> some View {
    let size = runningAppActivityPreviewSize(for: layout)
    return RunningAppActivityView(
        app: app,
        content: content,
        isStale: isStale,
        layout: layout
    ) {
        EmptyView()
    }
    .frame(width: size.width, height: size.height)
    .background(.background.secondary, in: .rect(cornerRadius: 22))
}

/// The same card with its Stop button, which is what the reader actually gets. A
/// plain `Button` rather than the real `LiveActivityIntent` one: an intent-backed
/// button cannot be built outside the extension, and what a reference can prove
/// about it is its placement, not its wiring.
func runningAppActivityPreviewCardWithStop(
    _ content: RunningAppActivityContent,
    app: RunningAppActivityApp = .previewDancing,
    isStale: Bool = false
) -> some View {
    RunningAppActivityView(app: app, content: content, isStale: isStale, layout: .lockScreen) {
        Button {} label: {
            Label("Stop", systemImage: "stop.fill").labelStyle(.iconOnly)
        }
        .buttonBorderShape(.circle)
    }
    .frame(
        width: RunningAppActivityPreviewSize.lockScreen.width,
        height: RunningAppActivityPreviewSize.lockScreen.height
    )
    .background(.background.secondary, in: .rect(cornerRadius: 22))
}

private func runningAppActivityPreviewSize(
    for layout: RunningAppActivityLayout
) -> CGSize {
    switch layout {
    case .lockScreen: RunningAppActivityPreviewSize.lockScreen
    case .compactLeading, .compactTrailing, .expandedTrailing: RunningAppActivityPreviewSize.compact
    case .minimal: RunningAppActivityPreviewSize.minimal
    case .expandedLeading, .expandedBottom: RunningAppActivityPreviewSize.expanded
    }
}

extension RunningAppActivityApp {
    static let previewDancing = RunningAppActivityApp(
        robotID: "kitchen",
        robotName: "Kitchen Reachy",
        appName: "dance_party",
        appTitle: "Dance Party",
        emoji: "💃",
        gradientFrom: "pink",
        gradientTo: "indigo",
        artworkKey: "pollen-robotics/dance-party"
    )
}

extension RunningAppActivityContent {
    static func preview(
        _ caption: String,
        symbol: String = "square.grid.2x2.fill",
        isFailed: Bool = false,
        canStop: Bool = true
    ) -> RunningAppActivityContent {
        RunningAppActivityContent(
            caption: caption,
            symbolName: symbol,
            isFailed: isFailed,
            canStop: canStop,
            readAt: runningAppActivityPreviewDate
        )
    }
}

#Preview("Activity — running", traits: .sizeThatFitsLayout) {
    runningAppActivityPreviewCardWithStop(.preview("Running"))
}

#Preview("Activity — starting", traits: .sizeThatFitsLayout) {
    runningAppActivityPreviewCardWithStop(
        .preview("Starting…", symbol: "arrow.trianglehead.clockwise")
    )
}

#Preview("Activity — stopping", traits: .sizeThatFitsLayout) {
    runningAppActivityPreviewCard(
        .preview("Stopping…", symbol: "stop.circle", canStop: false)
    )
}

// The card the reader meets after putting the phone down: no present tense, no
// verdict, and an age the system keeps drawing with no process running.
//
// `prefireIgnored()` — and it is the age that forces it. `Text(_, style: .relative)`
// is measured against the *current* date, so this card renders "4 mths, 13 days"
// today and something else tomorrow: a reference for it would fail every day it was
// not re-recorded. It is the one preview here with a live date.
//
// **So the stale card has no reference, deliberately** (project rule 8 asks for that
// to be said rather than left silent). The layout is the same row every other
// Activity reference captures, and the wording rule — no present tense, no verdict —
// is recorded in `ReachyWidgetUI/AGENTS.md`, held by nothing executable. The one
// thing that could only ever have been a device check is the age counting up with no
// process running, which is the whole point of it.
#Preview("Activity — stale", traits: .sizeThatFitsLayout) {
    runningAppActivityPreviewCardWithStop(.preview("Running"), isStale: true)
        .prefireIgnored()
}

// A crash, carried as the daemon's summary line alone. The stderr tail stays in
// the app, where there is room for it.
#Preview("Activity — crashed", traits: .sizeThatFitsLayout) {
    runningAppActivityPreviewCard(
        .preview(
            "Process exited with code 1",
            symbol: "exclamationmark.triangle.fill",
            isFailed: true,
            canStop: false
        )
    )
}

// A robot reached only over the relay. The card still says what is running; it
// draws no Stop, because an intent has no LAN address to dial and a button that
// silently does nothing is worse than none.
#Preview("Activity — no stop over the relay", traits: .sizeThatFitsLayout) {
    runningAppActivityPreviewCard(.preview("Running", canStop: false))
}

#Preview("Activity — refused stop", traits: .sizeThatFitsLayout) {
    runningAppActivityPreviewCardWithStop(
        .preview(
            "The robot refused to stop the app",
            symbol: "exclamationmark.triangle.fill",
            isFailed: true
        )
    )
}

#Preview("Activity — island compact", traits: .sizeThatFitsLayout) {
    HStack {
        runningAppActivityPreviewCard(.preview("Running"), layout: .compactLeading)
        runningAppActivityPreviewCard(.preview("Running"), layout: .compactTrailing)
    }
}

#Preview("Activity — island expanded", traits: .sizeThatFitsLayout) {
    VStack(alignment: .leading) {
        runningAppActivityPreviewCard(.preview("Running"), layout: .expandedLeading)
        runningAppActivityPreviewCard(.preview("Running"), layout: .expandedBottom)
    }
}
