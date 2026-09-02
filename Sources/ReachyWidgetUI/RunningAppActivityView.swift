import ReachyDesign
import ReachyKit
import SwiftUI

/// Which slot of the Live Activity is being drawn.
///
/// A top-level type rather than one nested in the generic view, because a type
/// nested in a generic inherits its parameters: `RunningAppActivityView<AnyView>.Layout`
/// and `RunningAppActivityView<EmptyView>.Layout` would be two different types, and a
/// caller passing one to the other gets an error about the *stop button's* type.
public enum RunningAppActivityLayout: Sendable {
    /// The whole card, under 160 pt because above that the system truncates it.
    case lockScreen
    /// The two halves of the Dynamic Island's collapsed form. They are separate
    /// views that read as one, so neither may repeat what the other says.
    case compactLeading
    case compactTrailing
    /// One glyph, shared with another app's activity.
    case minimal
    /// The three regions of the expanded form worth filling.
    case expandedLeading
    case expandedTrailing
    case expandedBottom
}

/// The Dynamic Island's slots are much smaller than any tile elsewhere, and 20 pt is
/// a one-off of this component rather than a role: both users of it are the view's
/// own slots, which is one consumer and not two (root rule 10).
///
/// File-scoped rather than a `static let` on the view, which a generic type cannot
/// have.
private let islandArtwork: CGFloat = 20

/// The face of the running-app Live Activity, in every slot ActivityKit asks for.
///
/// The layout is **handed in and never read from the environment**, the same rule
/// `RobotWidgetView` follows and for a sharper version of the same reason: outside a
/// widget `\.widgetFamily` defaults to `.systemMedium`, and here there is no
/// equivalent key at all — the Dynamic Island's slots are separate builder closures
/// rather than one view asked what it is.
///
/// The Stop button arrives as a `@ViewBuilder` rather than being built here, so this
/// type stays free of App Intents and of `#if os(iOS)`: the extension hands it a
/// `Button(intent:)`, a preview hands it whatever renders. `AppRowLabel` takes its
/// badge the same way.
public struct RunningAppActivityView<Stop: View>: View {
    private let app: RunningAppActivityApp
    private let content: RunningAppActivityContent
    /// Whether the content is past its stale date — handed in from
    /// `ActivityViewContext.isStale`, so this type needs no ActivityKit either.
    private let isStale: Bool
    private let layout: RunningAppActivityLayout
    private let stop: Stop

    public init(
        app: RunningAppActivityApp,
        content: RunningAppActivityContent,
        isStale: Bool = false,
        layout: RunningAppActivityLayout,
        @ViewBuilder stop: () -> Stop
    ) {
        self.app = app
        self.content = content
        self.isStale = isStale
        self.layout = layout
        self.stop = stop()
    }

    public var body: some View {
        switch layout {
        case .lockScreen: lockScreen
        case .compactLeading: AppArtworkTile(artwork: artwork, size: islandArtwork)
        case .compactTrailing, .minimal: glyph
        case .expandedLeading: expandedLeading
        case .expandedTrailing: glyph
        case .expandedBottom: expandedBottom
        }
    }

    private var artwork: AppArtwork {
        AppArtwork(
            emoji: app.emoji,
            gradient: app.gradientFrom.flatMap { from in
                app.gradientTo.map { RobotApp.Gradient(from: from, to: $0) }
            },
            key: app.artworkKey
        )
    }

    private var glyph: some View {
        Image(systemName: content.symbolName)
            .foregroundStyle(content.isFailed ? Tone.danger.style : Tone.quiet.style)
    }

    /// The dock strip, on the Lock Screen.
    ///
    /// Composed from `AppArtworkTile` and the typography tokens rather than through
    /// `AppRowLabel`, and the reason is the age line: that row takes a
    /// `ReachyStatusLabel`, which holds a `String`. A frozen string is exactly what
    /// this surface may not show — a widget re-renders on a timeline and can restate
    /// an age, while an activity gets no process at all, so "2 minutes ago" would
    /// stay two minutes ago for the rest of the day.
    private var lockScreen: some View {
        HStack(spacing: Space.md) {
            AppArtworkTile(artwork: artwork, size: Metrics.artworkCompact)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.appTitle)
                    .font(Typography.rowTitleCompact)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                caption
            }
            Spacer(minLength: Space.xs)
            if content.canStop {
                stop
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
    }

    /// What the card is allowed to say, and the whole difference between the two
    /// states.
    ///
    /// Fresh, it is the same sentence the dock shows. Stale, it stops making a claim
    /// about the present and shows **when the reading arrived** instead —
    /// system-rendered, so it goes on being true with nothing running. What it must
    /// never become is a verdict: the stale flip is a timer, not a reading, so
    /// "stuck", "failed" and "unreachable" are unavailable here however long the
    /// silence lasts.
    @ViewBuilder
    private var caption: some View {
        if isStale {
            HStack(spacing: Space.xxs) {
                Text(.reachy("Last checked"))
                Text(content.readAt, style: .relative)
            }
            .font(Typography.status)
            .foregroundStyle(Tone.quiet.style)
            .lineLimit(1)
        } else {
            ReachyStatusLabel(
                text: content.caption,
                tone: content.isFailed ? .failed : .idle,
                font: Typography.status,
                lineLimit: 2
            )
        }
    }

    private var expandedLeading: some View {
        HStack(spacing: Space.sm) {
            AppArtworkTile(artwork: artwork, size: islandArtwork)
            Text(app.appTitle)
                .font(Typography.rowTitleCompact)
                .lineLimit(1)
        }
    }

    /// The robot's name and the state, under the camera. The name is identity rather
    /// than state, so it is the one thing here that stays true while frozen.
    private var expandedBottom: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(app.displayName)
                    .font(Typography.detail)
                    .foregroundStyle(Tone.quiet.style)
                    .lineLimit(1)
                caption
            }
            Spacer(minLength: Space.xs)
            if content.canStop {
                stop
            }
        }
    }
}
