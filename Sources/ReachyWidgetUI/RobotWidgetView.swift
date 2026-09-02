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
        /// `.accessoryCircular` — the Lock Screen and StandBy. A glyph and nothing
        /// else fits inside the ring.
        case circular
        /// `.accessoryRectangular`. Two lines, and the widest of the three.
        case rectangular
        /// `.accessoryInline`, which is one line beside the clock. The system draws
        /// it in its own font and colour and ignores almost everything asked of it.
        case inline
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
            // None of the three accessory branches carries the wake/sleep button,
            // and one of them could not: `.accessoryInline` is a single line the
            // system builds itself out of a `Text` and an `Image`, and a `Button` in
            // it is discarded. The other two are a decision — a 76 pt ring holding a
            // capsule has nothing left to say what the robot is doing. All three
            // fall through to `widgetURL`, so a tap opens the Robot tab, where the
            // button is.
            case .circular:
                circularBody
            case .rectangular:
                rectangularBody
            case .inline:
                // One `Label`, and the system decides everything about it. Anything
                // stacked here is dropped rather than laid out.
                //
                // `detail` rather than `title`: this line sits beside the clock, and
                // the robot's name is the one thing its owner already knows.
                // "Awake", "Hand Tracker" and "Last seen 2 hours ago" are what the
                // glance is for.
                Label(content.detail, systemImage: content.symbolName)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    /// The two system families and the rectangular accessory read as rows, so they
    /// start at the leading edge. A ring and a line beside the clock are centred by
    /// definition — and getting this wrong is visible only in a reference: the
    /// first circular recording put a leading-aligned glyph half outside its own
    /// ring.
    private var alignment: Alignment {
        switch layout {
        case .compact, .wide, .rectangular: .leading
        case .circular, .inline: .center
        }
    }

    /// A ring and a glyph, and **no words at all — which the first recording is
    /// what settled.**
    ///
    /// It carried `content.title` under the symbol, and the reference came back
    /// with "kitchen" clipped to "kitcher": 76 pt less padding is 68, and
    /// `minimumScaleFactor` gave up before the name did. Shortening the font would
    /// have traded a legible glyph for an illegible word. The symbol already
    /// carries the state — that is the whole of what `RobotWidgetContent.symbolName`
    /// is chosen for — and the ring's job is to be read at a glance from a locked
    /// screen, so the state is spoken to VoiceOver instead of drawn.
    ///
    /// `AccessoryWidgetBackground` is the system's own ring rather than a token,
    /// and that is the exception `ReachyDesign` names for a platform-drawn surface:
    /// it renders the Lock Screen's material, which nothing in the design system
    /// can reproduce and nothing headless can capture.
    private var circularBody: some View {
        ZStack {
            AccessoryWidgetBackground()
            // Sized to the ring rather than to a `Typography` step: the ring is
            // 76 pt on a phone and something else on a watch face, and a fixed font
            // that fits one clips in the other — which the first recording showed,
            // with the glyph's head cut off by `clipShape`.
            Image(systemName: content.symbolName)
                .resizable()
                .scaledToFit()
                .padding(Space.lg)
                .widgetAccentable()
        }
        .clipShape(.circle)
        .accessibilityElement()
        .accessibilityLabel(spokenState)
    }

    /// Both halves are already localized — `RobotWidgetContent` resolves them
    /// through `.reachy(_:)` — so this joins two finished sentences rather than
    /// forming a key of its own. Held in a `String` property on purpose: a literal
    /// with interpolation at the call site would bind to `accessibilityLabel`'s
    /// `LocalizedStringKey` overload, which inside a library resolves against
    /// `Bundle.main` and would silently never translate (project rule 9).
    private var spokenState: String {
        "\(content.title), \(content.detail)"
    }

    /// The one accessory family with room for a state *and* its reason, which is
    /// what makes it the Smart Stack's row rather than a badge.
    private var rectangularBody: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Label(content.title, systemImage: content.symbolName)
                .font(Typography.rowTitle)
                .widgetAccentable()
                .lineLimit(1)
            Text(content.detail)
                .font(Typography.status)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shared by both branches so the text has one place it can drift.
    ///
    /// `spacing: 6` is the component's own optical rhythm and deliberately not a
    /// `Space` token — `Space.swift`'s second rule warns that an unmotivated 6 → 8
    /// moves every reference it touches with no design reason behind it. The tokens
    /// govern the *new* gap between this column and the button.
    private var textColumn: some View {
        // Optical: this component's own rhythm, deliberately off the 4-pt grid (Space.swift, rule 2).
        // swiftlint:disable:next raw_spacing
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
    /// second line. The accessory families never reach here — they draw no button —
    /// and are folded in with compact rather than given a case that cannot run.
    @ViewBuilder
    private func actionLabel(_ title: LocalizedStringResource, systemImage: String) -> some View {
        switch layout {
        case .wide:
            Label(title, systemImage: systemImage)
        default:
            Image(systemName: systemImage)
                .accessibilityLabel(Text(title))
        }
    }
}
