import ReachyDesign
import ReachyKit
import ReachyWidgetUI
import SwiftUI

/// One app in the store list.
struct AppStoreRow: View {
    let app: RobotApp
    var isInstalled = false
    var isRunning = false
    var hasUpdate = false
    var isStartupApp = false
    var isPinned = false

    var body: some View {
        HStack(spacing: Space.md) {
            AppArtworkTile(app: app)
            // Optical: title, subtitle and footnote read as one block; 3 pt is tighter than any token.
            // swiftlint:disable:next raw_spacing
            VStack(alignment: .leading, spacing: 3) {
                // Optical: badges hug the title; 5 pt is the glyph's own breathing room.
                // swiftlint:disable:next raw_spacing
                HStack(spacing: 5) {
                    // Beside the title rather than in `trailing`, whose four cases are
                    // mutually exclusive and are all about the app's state on the robot.
                    // A pin is the reader's own mark and coexists with every one of them.
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(.tint)
                            .accessibilityLabel(.reachy("Pinned"))
                    }
                    Text(app.title)
                        .font(Typography.rowTitle)
                        .lineLimit(1)
                    if app.isOfficial {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.tint)
                            .accessibilityLabel(.reachy("Official"))
                    }
                    if app.isPrivate {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(.reachy("Private"))
                    }
                }
                .font(Typography.status)

                if let subtitle {
                    Text(subtitle)
                        .font(Typography.subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let footnote {
                    Text(footnote)
                        .font(Typography.status)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Space.sm)
            trailing
        }
        .padding(.vertical, Space.xs)
    }

    private var subtitle: String? {
        app.summary ?? app.author
    }

    /// Author and likes are all the Hub offers as a reputation signal, and the
    /// only way to tell two similarly named apps apart.
    private var footnote: String? {
        var parts: [String] = []
        if let author = app.author, app.summary != nil {
            parts.append(author)
        }
        if let likes = app.likes, likes > 0 {
            parts.append(String(localized: .reachy("♥ \(likes)")))
        }
        if isStartupApp {
            parts.append(String(localized: .reachy("Starts on wake-up")))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var trailing: some View {
        if isRunning {
            Label(.reachy("Running"), systemImage: "waveform")
                .labelStyle(.iconOnly)
                .foregroundStyle(.tint)
                .symbolEffect(.variableColor.iterative)
                .accessibilityLabel(.reachy("Running"))
        } else if hasUpdate {
            ReachyBadge(.reachy("Update"))
        } else if isInstalled {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel(.reachy("Installed"))
        } else {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.tint)
                .accessibilityLabel(.reachy("Not installed"))
        }
    }
}
