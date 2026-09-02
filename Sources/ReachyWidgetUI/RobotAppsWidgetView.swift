import ReachyDesign
import SwiftUI
import WidgetKit

/// The launcher's face.
///
/// Unlike `RobotWidgetView` this does import `WidgetKit`, for
/// `invalidatableContent()` alone — the one signal a widget has that a button's
/// intent is still running. It is inert outside a widget, so previews and the
/// snapshot suite render this the same as any other view.
///
/// The grid takes its shape from how many tiles it was handed rather than from
/// the widget family, so small, medium and large fall out of one `limit` decided
/// in the provider.
public struct RobotAppsWidgetView: View {
    private let content: RobotAppsWidgetContent

    public init(content: RobotAppsWidgetContent) {
        self.content = content
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Space.sm), count: content.tiles.count <= 2 ? 1 : 2)
    }

    public var body: some View {
        // Optical: a widget pays for every point; 6 pt is the tile's own rhythm (see RobotWidgetView).
        // swiftlint:disable:next raw_spacing
        VStack(alignment: .leading, spacing: 6) {
            if content.tiles.isEmpty {
                emptyState
            } else {
                // The grid takes the height rather than hugging the top. A small
                // widget holding one tile used to leave roughly two thirds of
                // itself empty, which reads as a widget that failed to load.
                LazyVGrid(columns: columns, spacing: Space.sm) {
                    ForEach(content.tiles) { tile in
                        RobotAppTileView(tile: tile)
                    }
                }
                .frame(maxHeight: .infinity)
                if let message = content.notice.message {
                    noticeRow(message)
                }
                if let footnote = content.footnote {
                    Text(footnote)
                        .font(Typography.statusCompact)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        // Optical: a widget pays for every point; 6 pt is the tile's own rhythm (see RobotWidgetView).
        // swiftlint:disable:next raw_spacing
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "square.grid.2x2")
                // Optical: empty-state artwork, sized against the tile and not its caption.
                // swiftlint:disable:next raw_font
                .font(.title2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(content.notice.message ?? "")
                .font(Typography.status)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func noticeRow(_ message: String) -> some View {
        Text(content.notice.invitesTheApp ? String(localized: .reachy("\(message) Tap to open.")) : message)
            .font(Typography.statusCompact)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

/// One app. A button when the tap means something, plain text when it does not —
/// a dimmed `Button` that silently declines is worse than no button, and letting
/// the tap fall through to the widget's own `widgetURL` opens the app instead,
/// which is where a blocked or missing app is actually resolved.
struct RobotAppTileView: View {
    let tile: RobotAppsWidgetContent.Tile

    var body: some View {
        if tile.isTappable {
            Button(intent: RobotAppTileIntent(id: tile.id, name: tile.name)) {
                label
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    private var label: some View {
        AppRowLabel(
            artwork: AppArtwork(emoji: tile.emoji, gradient: tile.gradient, key: tile.id),
            title: tile.title,
            layout: .tile,
            titleWeight: tile.state == .running ? .semibold : .regular,
            status: caption.map {
                ReachyStatusLabel(text: $0, tone: statusTone, font: Typography.statusCompact, lineLimit: 1)
            }
        ) {
            badge
        }
        // Optical: a widget tile pays for every point; 6 is what fits two rows.
        // swiftlint:disable:next raw_spacing
        .padding(6)
        // Fills the row the grid gives it, so two tiles on a small widget divide
        // the height between them instead of stacking at the top over a void.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(background, in: Radius.rect(Radius.sm))
        .opacity(isDimmed ? 0.4 : 1)
        // WidgetKit dims this by itself while the button's intent is in flight,
        // which is the only progress a widget can show across a process boundary.
        // The durable pending marker is what keeps the caption up through the
        // reload the intent triggers on its way out.
        .invalidatableContent(isPending)
    }

    /// The one signal that survives a tile too narrow for its caption: what the app
    /// is doing, on the artwork itself. A stop target on the one holding the robot,
    /// a warning on the one that died on it.
    @ViewBuilder
    private var badge: some View {
        switch tile.state {
        // A scrim rather than a tone: it darkens the artwork under it so the glyph
        // reads, which is not something any of the five roles means.
        case .running:
            badgeSymbol("stop.fill", background: AnyShapeStyle(.black.opacity(0.45)), label: .reachy("Running"))
        case .failed:
            badgeSymbol("exclamationmark", background: Tone.danger.style, label: .reachy("Failed"))
        default: EmptyView()
        }
    }

    private func badgeSymbol(_ name: String, background: AnyShapeStyle, label: LocalizedStringResource) -> some View {
        Image(systemName: name)
            // Optical: the glyph is what sizes the badge disc drawn around it.
            // swiftlint:disable:next raw_font
            .font(.caption2)
            // Pinned against a fill this view owns, the way `ConnectRail` pins its
            // own: both badge backgrounds carry white in either appearance.
            .foregroundStyle(.white)
            .padding(Space.xs)
            .background(background, in: Circle())
            .accessibilityLabel(label)
    }

    private var caption: String? {
        switch tile.state {
        case .idle, .blocked: nil
        case .running: String(localized: .reachy("Running"))
        case .starting: String(localized: .reachy("Starting…"))
        case .stopping: String(localized: .reachy("Stopping…"))
        case .notInstalled: String(localized: .reachy("Not installed"))
        // One word, because that is all the room there is. The notice under the
        // grid carries what the daemon actually said.
        case .failed: String(localized: .reachy("Failed"))
        }
    }

    /// Only a crash gets a colour. "Running" stays quiet here even though the same
    /// word is `.active` elsewhere: a tile already says it is running by weight, by
    /// its tint and by the stop target on the artwork, and a fourth signal in green
    /// would make the grid read as a status board.
    private var statusTone: StatusTone {
        tile.state == .failed ? .failed : .idle
    }

    private var background: AnyShapeStyle {
        switch tile.state {
        case .running: AnyShapeStyle(Tone.brand.style.opacity(0.18))
        case .failed: AnyShapeStyle(Tone.danger.style.opacity(0.12))
        default: AnyShapeStyle(.fill.quaternary)
        }
    }

    /// A failed tile is not dimmed: dimming says "somebody else has the robot", and
    /// this one is the opposite — the thing the user most needs to see.
    private var isDimmed: Bool {
        tile.state == .blocked || tile.state == .notInstalled
    }

    private var isPending: Bool {
        tile.state == .starting || tile.state == .stopping
    }
}
