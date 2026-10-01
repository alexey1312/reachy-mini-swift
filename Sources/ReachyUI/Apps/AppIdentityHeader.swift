import ReachyDesign
import ReachyKit
import ReachyWidgetUI
import SwiftUI

/// Artwork, name, author and the badges — the way an app introduces itself.
///
/// The head of `AppDetailSheet`, which the store's rows and the dock both open.
struct AppIdentityHeader: View {
    /// The one thing to do with this app, where a store puts it: under the name.
    /// Install for an app the robot does not have, Start for one it does. What is
    /// not the one thing — Update, the wake-up switch, Remove — stays in the rows.
    struct Primary {
        let title: LocalizedStringResource
        let systemImage: String
        var isEnabled = true
        let action: () -> Void
    }

    let app: RobotApp
    var artworkSize: CGFloat = 64
    var primary: Primary?

    var body: some View {
        // The button sits under the name, as on the App Store's own page, and never
        // beside it. Beside it on a phone the text column kept about 110 pt, and the
        // badges' labels were wrapped a letter to a line ("Of / fi- / ci / al",
        // "2 / 1 / 4"). Choosing between the two by `ViewThatFits` was tried and is not
        // enough: by ideal sizes the row fitted with a couple of points to spare, the
        // laid-out column still got less, and the badges came out as "…".
        //
        // Top-aligned under a button, again as the App Store does; centred without
        // one, where the column is about the artwork's height and a title pinned to
        // its top edge left a gap under it.
        HStack(alignment: primary == nil ? .center : .top, spacing: Space.lg) {
            AppArtworkTile(app: app, size: artworkSize)
            VStack(alignment: .leading, spacing: Space.md) {
                details
                if let primary {
                    ReachyActionButton(action: primary.action) {
                        Label(primary.title, systemImage: primary.systemImage)
                    }
                    .buttonBorderShape(.capsule)
                    .disabled(!primary.isEnabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.xs)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(app.title)
                // Optical: the sheet's own heading, one step below the screen title; a role would have this one consumer.
                // swiftlint:disable:next raw_font
                .font(.title3.weight(.semibold))
            if let author = app.author {
                Text(author)
                    .font(Typography.subtitle)
                    .foregroundStyle(.secondary)
            }
            // Side by side, or one to a line where even the full column is too
            // narrow for that — the largest text sizes — but never a letter to a line.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.md) { badges }
                VStack(alignment: .leading, spacing: Space.xs) { badges }
            }
            .font(Typography.status)
            .foregroundStyle(.secondary)
            .labelStyle(BadgeLabelStyle())
        }
    }

    @ViewBuilder
    private var badges: some View {
        if app.isOfficial {
            Label(.reachy("Official"), systemImage: "checkmark.seal.fill")
        }
        if app.isPrivate {
            Label(.reachy("Private"), systemImage: "lock.fill")
        }
        if let likes = app.likes, likes > 0 {
            Label(.reachy("\(likes)"), systemImage: "heart.fill")
        }
    }
}

/// A badge's glyph tight against its word, so the gap between two badges is the
/// widest one in the row. Left to a `Form` row, a `Label` sets its icon in a column
/// of its own: measured on `App detail — not installed`, the seal stood 21 pt from
/// "Official" and the heart 14 pt after it, so the heart read as part of "Official"
/// rather than of its own 214, 22 pt away.
private struct BadgeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.xs) {
            configuration.icon
            configuration.title
        }
    }
}
