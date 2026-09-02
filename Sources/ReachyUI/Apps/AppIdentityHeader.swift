import ReachyDesign
import ReachyKit
import ReachyWidgetUI
import SwiftUI

/// Artwork, name, author and the badges — the way an app introduces itself.
///
/// Shared by the catalogue sheet and the running-app sheet. They agree on nothing
/// else (one is about installing, the other about what is happening right now),
/// but a user who opens both must see the same app, described the same way.
struct AppIdentityHeader: View {
    let app: RobotApp
    var artworkSize: CGFloat = 64

    var body: some View {
        // Optical: artwork-to-text gap of the identity header, between Space.md and Space.lg.
        // swiftlint:disable:next raw_spacing
        HStack(spacing: 14) {
            AppArtworkTile(app: app, size: artworkSize)
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
                // Optical: badge row spacing sized against the glyphs, not the text.
                // swiftlint:disable:next raw_spacing
                HStack(spacing: 10) {
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
                .font(Typography.status)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.xs)
    }
}
