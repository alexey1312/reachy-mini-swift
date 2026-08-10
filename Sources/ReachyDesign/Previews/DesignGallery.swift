import ReachyDesign
import SwiftUI

/// Scaffolding for the token gallery.
///
/// Nothing here is `private` and nothing is nested inside a preview: Prefire
/// copies each preview body into a generated file, where a file-private helper is
/// out of scope and the build fails naming the *generated* file.
struct DesignToken: Identifiable {
    let name: String
    let value: CGFloat

    var id: String {
        name
    }
}

enum DesignGallery {
    static let space: [DesignToken] = [
        DesignToken(name: "xxs", value: Space.xxs),
        DesignToken(name: "xs", value: Space.xs),
        DesignToken(name: "sm", value: Space.sm),
        DesignToken(name: "md", value: Space.md),
        DesignToken(name: "lg", value: Space.lg),
        DesignToken(name: "xl", value: Space.xl),
        DesignToken(name: "xxl", value: Space.xxl),
    ]

    static let radius: [DesignToken] = [
        DesignToken(name: "xs", value: Radius.xs),
        DesignToken(name: "sm", value: Radius.sm),
        DesignToken(name: "md", value: Radius.md),
        DesignToken(name: "lg", value: Radius.lg),
        DesignToken(name: "window", value: Radius.window),
    ]

    /// `readableForm` is missing on purpose — it is a width *limit*, not a size to
    /// draw, and a true-size swatch would make the gallery 600 pt wide and stretch
    /// every other row in it.
    static let metrics: [DesignToken] = [
        DesignToken(name: "artworkCompact", value: Metrics.artworkCompact),
        DesignToken(name: "artwork", value: Metrics.artwork),
        DesignToken(name: "dockStrip", value: Metrics.dockStrip),
        DesignToken(name: "joystickKnob", value: Metrics.joystickKnob),
        DesignToken(name: "railNode", value: Metrics.railNode),
    ]

    static let typography: [(name: String, font: Font)] = [
        ("screenTitle", Typography.screenTitle),
        ("rowTitle", Typography.rowTitle),
        ("detail", Typography.detail),
        ("status", Typography.status),
        ("statusCompact", Typography.statusCompact),
        ("console", Typography.console),
        ("consoleLine", Typography.consoleLine),
    ]

    /// A switch rather than `String(describing:)`, so a case added to any of these
    /// fails the gallery's build instead of quietly going unrendered.
    static func name(of tone: Tone) -> String {
        switch tone {
        case .danger: "danger"
        case .warning: "warning"
        case .success: "success"
        case .brand: "brand"
        case .quiet: "quiet"
        }
    }

    static func name(of tone: StatusTone) -> String {
        switch tone {
        case .active: "active"
        case .idle: "idle"
        case .failed: "failed"
        }
    }

    /// The captions the three renderers this type replaces actually put on screen,
    /// so the gallery shows what it is standing in for rather than one string in
    /// three colours.
    static func caption(for tone: StatusTone) -> String {
        switch tone {
        case .active: "Running"
        case .idle: "Not responding"
        case .failed: "Stopped with an error"
        }
    }

    static func name(of emphasis: ButtonEmphasis) -> String {
        switch emphasis {
        case .prominent: "prominent"
        case .standard: "standard"
        case .quiet: "quiet"
        }
    }

    static func name(of role: SurfaceRole) -> String {
        switch role {
        case .chrome: "chrome"
        case .card: "card"
        case .badge: "badge"
        case .scrim: "scrim"
        case .window: "window"
        case .page: "page"
        }
    }
}

struct TokenGallery<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title)
                .font(Typography.rowTitle)
            content()
        }
        .padding(Space.lg)
    }
}

struct TokenRow<Sample: View>: View {
    let name: String
    let value: String
    @ViewBuilder let sample: () -> Sample

    var body: some View {
        HStack(spacing: Space.md) {
            Text(name)
                .font(Typography.consoleLine)
                .frame(width: 148, alignment: .leading)
            sample()
            Spacer(minLength: Space.sm)
            Text(value)
                .font(Typography.consoleLine)
                .foregroundStyle(Tone.quiet.style)
        }
    }
}

/// Something with real contrast behind a surface, so the opaque `baseFill` shows
/// up as covering rather than as one more translucent layer. Glass and materials
/// do not render headless; the fill is the whole of what a reference image sees.
struct GalleryBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [.indigo, .orange],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
