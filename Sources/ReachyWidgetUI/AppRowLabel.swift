import ReachyDesign
import SwiftUI

/// The two shapes an app row is drawn at.
///
/// A preset rather than three arguments repeated at each call site: the dock strip
/// and a widget tile differ in exactly these, and putting the difference in one
/// place is most of the point of sharing the row.
public struct AppRowLayout: Sendable {
    let spacing: CGFloat
    let titleFont: Font
    /// How much room the row insists on keeping for whatever sits after it.
    let trailingGap: CGFloat

    /// The running-app strip: controls follow it, and its caption gets two lines.
    public static let dock = AppRowLayout(
        spacing: Space.md,
        titleFont: Typography.rowTitleCompact,
        trailingGap: Space.xs
    )

    /// A widget tile: half a widget wide, nothing after it, one line of caption.
    public static let tile = AppRowLayout(
        spacing: Space.sm,
        titleFont: Typography.tileTitle,
        trailingGap: 0
    )
}

/// One app as a row: its artwork, its name, and what it is doing.
///
/// Two surfaces draw exactly this — the running-app dock inside the app, and a
/// launcher tile inside the widget — and it lives here for the reason `AppArtwork`
/// records: an extension process cannot link `ReachyUI`, so whatever both surfaces
/// draw moves down to the shared target rather than up.
///
/// The status caption is passed in already built. `ReachyStatusLabel` is a concrete
/// type, so this stays generic over the badge alone, and each caller keeps its own
/// mapping from a domain state onto a tone.
public struct AppRowLabel<Badge: View>: View {
    private let artwork: AppArtwork
    private let title: String
    private let layout: AppRowLayout
    private let titleWeight: Font.Weight
    private let status: ReachyStatusLabel?
    private let badge: Badge

    public init(
        artwork: AppArtwork,
        title: String,
        layout: AppRowLayout,
        titleWeight: Font.Weight = .semibold,
        status: ReachyStatusLabel? = nil,
        @ViewBuilder badge: () -> Badge
    ) {
        self.artwork = artwork
        self.title = title
        self.layout = layout
        self.titleWeight = titleWeight
        self.status = status
        self.badge = badge()
    }

    public var body: some View {
        HStack(spacing: layout.spacing) {
            AppArtworkTile(artwork: artwork, size: Metrics.artworkCompact)
                .overlay { badge }
            // 1 pt is optical, not rhythm: the caption belongs to the title above
            // it, and a `Space` gap would read as two separate lines.
            // swiftlint:disable:next raw_spacing
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(layout.titleFont)
                    .fontWeight(titleWeight)
                    .lineLimit(1)
                status
            }
            Spacer(minLength: layout.trailingGap)
        }
    }
}

public extension AppRowLabel where Badge == EmptyView {
    init(
        artwork: AppArtwork,
        title: String,
        layout: AppRowLayout,
        titleWeight: Font.Weight = .semibold,
        status: ReachyStatusLabel? = nil
    ) {
        self.init(
            artwork: artwork,
            title: title,
            layout: layout,
            titleWeight: titleWeight,
            status: status
        ) {
            EmptyView()
        }
    }
}
