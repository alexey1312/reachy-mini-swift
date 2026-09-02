import ReachyDesign
import ReachyKit
import SwiftUI

/// What the menu bar popover can be asked to do.
///
/// One enum behind one callback rather than four closure parameters: the view stays
/// trivially previewable with `{ _ in }`, and the scene keeps the one command it
/// alone can carry out — `.open` needs a way to bring the app forward, which a
/// view has no business holding.
public enum MenuBarCommand: Equatable, Sendable {
    case wake
    case sleep
    case app(RobotAppsWidgetContent.Tile)
    case open(ReachyDeepLink)
}

/// The macOS menu bar popover.
///
/// Platform-neutral on purpose. The `MenuBarExtra` *scene* is macOS-only and lives
/// in the app target; this is ordinary SwiftUI, so it carries previews and renders
/// on the iOS simulator like every other view here. What those references prove is
/// the layout, the wording and which rows appear in which state — never the AppKit
/// chrome behind the popover, which is a device check.
///
/// **No `import WidgetKit`.** `RobotWidgetView` and `RobotAppsWidgetView` import it
/// for `invalidatableContent()` alone, the one progress signal a widget has across
/// a process boundary. This has `isBusy` and a live process.
public struct MenuBarContentView: View {
    private let content: MenuBarContent
    private let isBusy: Bool
    private let onCommand: (MenuBarCommand) -> Void

    public init(
        content: MenuBarContent,
        isBusy: Bool = false,
        onCommand: @escaping (MenuBarCommand) -> Void
    ) {
        self.content = content
        self.isBusy = isBusy
        self.onCommand = onCommand
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            statusRow
            if let action = content.status.action {
                actionButton(action).frame(maxWidth: .infinity)
            }
            if !content.apps.tiles.isEmpty {
                Divider()
                appsSection
            }
            if let message = content.apps.notice.message {
                captionText(message, style: .secondary)
            }
            if let footnote = content.apps.footnote {
                captionText(footnote, style: .tertiary)
            }
            Divider()
            openRow
        }
        .padding(Space.lg)
        // A `VStack` of flexible rows offers macOS no ideal width, so without this
        // AppKit lays the popover out cramped. The same class of problem
        // `Metrics.sheetWidth` solves, and declared for the same reason.
        .frame(width: Metrics.menuBarPopoverWidth)
    }

    private var statusRow: some View {
        HStack(spacing: Space.md) {
            Image(systemName: content.status.symbolName)
                .font(Typography.screenTitle)
                .foregroundStyle(content.status.isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            // 1 pt is optical, not rhythm: the detail belongs to the title above it,
            // exactly as in `AppRowLabel`.
            // swiftlint:disable:next raw_spacing
            VStack(alignment: .leading, spacing: 1) {
                Text(content.status.title)
                    .font(Typography.rowTitle)
                    .lineLimit(1)
                Text(content.status.detail)
                    .font(Typography.status)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if isBusy {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// The same asymmetry the widget's button follows, and for the same reason: it
    /// is `content.status.action` that decides, so a transition in flight and a
    /// robot that is not there both correctly offer nothing.
    @ViewBuilder
    private func actionButton(_ action: RobotWidgetContent.Action) -> some View {
        switch action {
        case .wake:
            Button { onCommand(.wake) } label: {
                Label(.reachy("Wake up"), systemImage: "sun.max")
            }
            .reachyButton()
            .disabled(isBusy)
        case .sleep:
            Button { onCommand(.sleep) } label: {
                Label(.reachy("Go to sleep"), systemImage: "moon.zzz")
            }
            .reachyButton()
            .disabled(isBusy)
        }
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(.reachy("Apps"))
                .font(Typography.status)
                .foregroundStyle(.secondary)
            ForEach(content.apps.tiles) { tile in
                appRow(tile)
            }
        }
    }

    /// A dimmed `Button` that silently declines is worse than no button, so an
    /// untappable app is drawn as plain text — the same call `RobotAppTileView`
    /// makes, minus the widget's fall-through to `widgetURL`.
    @ViewBuilder
    private func appRow(_ tile: RobotAppsWidgetContent.Tile) -> some View {
        if tile.isTappable {
            Button { onCommand(.app(tile)) } label: {
                appLabel(tile)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        } else {
            appLabel(tile)
        }
    }

    private func appLabel(_ tile: RobotAppsWidgetContent.Tile) -> some View {
        AppRowLabel(
            artwork: AppArtwork(emoji: tile.emoji, gradient: tile.gradient, key: tile.id),
            title: tile.title,
            layout: .dock,
            titleWeight: tile.state == .running ? .semibold : .regular,
            status: Self.caption(for: tile.state).map { text in
                ReachyStatusLabel(
                    text: text,
                    tone: Self.tone(for: tile.state),
                    font: Typography.statusCompact,
                    lineLimit: 1
                )
            }
        )
        .contentShape(.rect)
    }

    private func captionText(_ text: String, style: HierarchicalShapeStyle) -> some View {
        Text(text)
            .font(Typography.statusCompact)
            .foregroundStyle(style)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var openRow: some View {
        Button { onCommand(.open(content.apps.destination)) } label: {
            Label(.reachy("Open Reachy Mini"), systemImage: "arrow.up.forward.square")
        }
        .reachyButton(.quiet)
    }

    /// This surface's own mapping from a tile state onto a caption, which is the
    /// rule `ReachyWidgetUI` deliberately never centralises — each caller decides
    /// what "running" should look like on its own surface.
    ///
    /// `.blocked` says nothing, as on a tile: another app holding the robot is
    /// explained by the notice under the list, not six times over in the rows.
    private static func caption(for state: RobotAppsWidgetContent.TileState) -> String? {
        switch state {
        case .idle, .blocked: nil
        case .running: String(localized: .reachy("Running"))
        case .starting: String(localized: .reachy("Starting…"))
        case .stopping: String(localized: .reachy("Stopping…"))
        case .notInstalled: String(localized: .reachy("Not installed"))
        case .failed: String(localized: .reachy("Failed"))
        }
    }

    /// **Running is `.active` here and `.idle` on a widget tile, and the two
    /// disagree on purpose.** A tile is already tinted, already weighted and already
    /// carries a stop target on its artwork, so a fourth green signal would turn the
    /// grid into a status board. A popover row has none of those — the caption is
    /// the only thing saying which app holds the robot.
    private static func tone(for state: RobotAppsWidgetContent.TileState) -> StatusTone {
        switch state {
        case .running: .active
        case .failed: .failed
        case .idle, .starting, .stopping, .blocked, .notInstalled: .idle
        }
    }
}
