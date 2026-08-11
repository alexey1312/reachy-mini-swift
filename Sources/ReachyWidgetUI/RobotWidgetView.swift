import ReachyDesign
import SwiftUI
import WidgetKit

/// The widget's face.
///
/// It imports `WidgetKit` for `invalidatableContent()` alone — the one signal a
/// widget has that a button's intent is still running — exactly as
/// `RobotAppsWidgetView` does. Both are inert outside a widget, so previews and the
/// snapshot suite render this like any other view. The container background and the
/// timeline still belong to the extension.
///
/// The layout is handed in rather than read from `\.widgetFamily`, which defaults
/// to `.systemMedium` outside a widget and would draw every small preview card
/// wide. `RobotStatusWidget` is the one place the family is read — the same
/// division `ReachyAppsProvider.limit(for:)` already draws.
public struct RobotWidgetView: View {
    public enum Layout: Sendable, Equatable {
        /// `.systemSmall`.
        case compact
        /// `.systemMedium`, where there is room for a word on the button and a line
        /// the compact layout has to drop.
        case wide
    }

    private let content: RobotWidgetContent
    private let layout: Layout

    public init(content: RobotWidgetContent, layout: Layout = .compact) {
        self.content = content
        self.layout = layout
    }

    public var body: some View {
        Group {
            switch layout {
            case .compact:
                VStack(alignment: .leading, spacing: Space.sm) {
                    textColumn
                    if let action = content.action {
                        actionButton(action).frame(maxWidth: .infinity)
                    }
                }
            case .wide:
                // Bottom-aligned: the text column fills the height with the symbol
                // at the top, so this puts the button on the same line as the state
                // it acts on. A capsule stretched across 338 pt reads as a banner,
                // and stacking it under the text leaves the right half empty — the
                // extra width is the whole argument for putting it beside.
                HStack(alignment: .bottom, spacing: Space.md) {
                    textColumn
                    if let action = content.action {
                        actionButton(action)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Shared by both branches so the text has one place it can drift.
    ///
    /// `spacing: 6` is the component's own optical rhythm and deliberately not a
    /// `Space` token — `Space.swift`'s second rule warns that an unmotivated 6 → 8
    /// moves every reference it touches with no design reason behind it. The tokens
    /// govern the *new* gap between this column and the button.
    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: content.symbolName)
                .font(Typography.screenTitle)
                .foregroundStyle(content.isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            Spacer(minLength: 0)
            Text(content.title)
                .font(Typography.rowTitle)
                .lineLimit(1)
            Text(content.detail)
                .font(Typography.status)
                .foregroundStyle(.secondary)
                // Two lines because a relative date in a wordier language runs
                // past one at the small size, and a truncated "last seen" is the
                // one part of a stale reading that has to survive.
                .lineLimit(2)
            if layout == .wide, let secondary = content.secondaryDetail {
                Text(secondary)
                    .font(Typography.status)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The words and glyphs of `RobotScreen.controlSection`, deliberately not the
    /// Control Centre buttons' (`figure.wave`, `moon.zzz.fill`): a control is read
    /// against the screen it stands in for.
    ///
    /// `invalidatableContent()` takes no condition, unlike `RobotAppTileView`'s.
    /// There a pending tile is still on screen and the flag distinguishes it; here a
    /// transition in flight takes the button away entirely, so a condition off
    /// `isPending` could only ever be false and would switch the dimming off rather
    /// than drive it. The tap it has to cover is the one that starts the transition,
    /// and at that moment nothing is pending yet.
    @ViewBuilder
    private func actionButton(_ action: RobotWidgetContent.Action) -> some View {
        switch action {
        case .wake:
            Button(intent: WakeRobotIntent()) {
                actionLabel(.reachy("Wake up"), systemImage: "sun.max")
            }
            .reachyButton()
            .invalidatableContent()
        case .sleep:
            Button(intent: SleepRobotIntent()) {
                actionLabel(.reachy("Go to sleep"), systemImage: "moon.zzz")
            }
            .reachyButton()
            .invalidatableContent()
        }
    }

    /// Compact drops the word and keeps it as the accessibility label: at 158 pt the
    /// column above is already a glyph, a title and a two-line detail, and a
    /// symbol-plus-word capsule under that either clips or costs the detail its
    /// second line.
    @ViewBuilder
    private func actionLabel(_ title: LocalizedStringResource, systemImage: String) -> some View {
        switch layout {
        case .compact:
            Image(systemName: systemImage)
                .accessibilityLabel(Text(title))
        case .wide:
            Label(title, systemImage: systemImage)
        }
    }
}
