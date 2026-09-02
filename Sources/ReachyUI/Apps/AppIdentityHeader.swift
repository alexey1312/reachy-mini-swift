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
    /// The one thing to do with this app, where a store puts it: beside the name.
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
        HStack(spacing: Space.lg) {
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
                HStack(spacing: Space.sm) {
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
            if let primary {
                ReachyActionButton(action: primary.action) {
                    Label(primary.title, systemImage: primary.systemImage)
                }
                .buttonBorderShape(.capsule)
                .disabled(!primary.isEnabled)
            }
        }
        .padding(.vertical, Space.xs)
    }
}
