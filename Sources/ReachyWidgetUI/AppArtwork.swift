import ReachyDesign
import ReachyKit
import SwiftUI

/// What a Space looks like in a list.
///
/// The Hub gives an app no thumbnail at all — only `cardData.emoji` and two
/// palette *names* (`colorFrom` / `colorTo`) drawn from a fixed set. Resolving
/// those names is a UI concern, which is why `RobotApp.Gradient` carries them
/// unresolved.
///
/// It lives here rather than in `ReachyUI` because the widget extension draws the
/// same tile and cannot link that target. Duplicating the palette map instead
/// would guarantee the two drift the first time the Hub adds a colour name.
public struct AppArtwork: Sendable {
    public let emoji: String?
    public let colors: [Color]

    /// `key` is what an app with no palette gets a stable colour derived from.
    public init(emoji: String?, gradient: RobotApp.Gradient?, key: String) {
        self.emoji = emoji
        if let gradient {
            colors = [Self.color(named: gradient.from), Self.color(named: gradient.to)]
        } else {
            // An installed app that lost its metadata has no palette. Deriving one
            // from the name keeps the list legible — and keeps it *stable*, which
            // a random colour would not.
            colors = Self.derivedColors(for: key)
        }
    }

    public init(app: RobotApp) {
        self.init(emoji: app.emoji, gradient: app.gradient, key: app.id)
    }

    public init(_ summary: RobotAppSummary) {
        self.init(emoji: summary.emoji, gradient: summary.gradient, key: summary.id)
    }

    /// Tailwind's palette, which is what the Hub's card editor offers.
    public static func color(named name: String) -> Color {
        switch name.lowercased() {
        case "red": .red
        case "orange": .orange
        case "amber", "yellow": .yellow
        case "lime", "green", "emerald", "teal": .green
        case "cyan", "sky", "blue": .blue
        case "indigo", "violet": .indigo
        case "purple", "fuchsia": .purple
        case "pink", "rose": .pink
        case "gray", "grey", "slate", "zinc", "neutral", "stone": .gray
        // The Hub adds names without asking; a card with no artwork reads as a
        // broken app, so an unfamiliar name still gets a colour.
        default: .accentColor
        }
    }

    private static let palette: [Color] = [.red, .orange, .yellow, .green, .blue, .indigo, .purple, .pink]

    private static func derivedColors(for key: String) -> [Color] {
        // A hash of our own rather than `hashValue`, which is seeded per process
        // and would repaint every app on each launch.
        var digest: UInt64 = 5381
        for byte in key.utf8 {
            digest = digest &* 33 &+ UInt64(byte)
        }
        let first = Int(digest % UInt64(palette.count))
        let second = Int((digest / UInt64(palette.count)) % UInt64(palette.count))
        return [palette[first], palette[second == first ? (second + 3) % palette.count : second]]
    }
}

/// The rounded tile a store row leads with.
public struct AppArtworkTile: View {
    private let artwork: AppArtwork
    private let size: CGFloat

    public init(artwork: AppArtwork, size: CGFloat = Metrics.artwork) {
        self.artwork = artwork
        self.size = size
    }

    public init(app: RobotApp, size: CGFloat = Metrics.artwork) {
        self.init(artwork: AppArtwork(app: app), size: size)
    }

    public var body: some View {
        Radius.rect(Radius.tile(side: size))
            .fill(
                LinearGradient(colors: artwork.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .frame(width: size, height: size)
            .overlay {
                // The one place `.font(.system(size:))` is right: these are artwork,
                // and have to track the tile rather than the reader's text size.
                if let emoji = artwork.emoji {
                    Text(emoji)
                        // Optical: sized against the glyph it draws, not the reader's text size.
                        // swiftlint:disable:next raw_font
                        .font(.system(size: size * IconRatio.emoji))
                } else {
                    Image(systemName: "app.dashed")
                        // Optical: sized against the glyph it draws, not the reader's text size.
                        // swiftlint:disable:next raw_font
                        .font(.system(size: size * IconRatio.symbol))
                        // Pinned against the gradient this tile owns, not against an
                        // adaptive backdrop — every artwork colour carries white.
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .accessibilityHidden(true)
    }
}
