import SwiftUI

/// How much a button insists.
public enum ButtonEmphasis: Sendable, CaseIterable {
    /// The action the screen is there for. One per screen, at most.
    case prominent
    /// An action beside it.
    case standard
    /// A way out, or an alternative the reader is not being steered towards.
    ///
    /// Added for the connection rail's decisions, where three bordered capsules of
    /// different widths stacked into a ragged column — legible, and plainly wrong.
    /// A borderless label carries no width of its own, so several sit on one line
    /// without competing with the action above them and without clipping when the
    /// text grows.
    case quiet
    /// Stop, remove, forget: prominent because it is the action, red because it
    /// cannot be undone. Two call sites spelled it as `.prominent` plus a red tint
    /// before it had a name — the dock's Stop and the move bar's — which is the
    /// second consumer rule 10 waits for. The label stays white: white on the
    /// system red holds ≥ 3:1 in both appearances, so it needs no colour of its own.
    case destructive
}

public extension ButtonEmphasis {
    /// What a `.prominent` label is painted with, per appearance.
    ///
    /// `.borderedProminent` paints white, and white is right on the light accents
    /// (≥ 3.18 on every theme) and wrong on the dark ones: they are picked light so
    /// they read on a black page, which leaves white on them at 2.05 (graphite) down
    /// to 1.75 (teal). Black on the same accents holds ≥ 4.86. A label decision, not
    /// a palette one — repainting the dark accents would cost every tinted row its
    /// contrast against the page. `ReachyThemeTests.prominentLabelContrast` reads
    /// this same pair, so the two cannot drift.
    static func prominentLabelHex(for scheme: ColorScheme) -> UInt32 {
        scheme == .dark ? 0x000000 : 0xFFFFFF
    }

    static func prominentLabel(for scheme: ColorScheme) -> Color {
        Color(hex: prominentLabelHex(for: scheme))
    }
}

public extension View {
    /// The app's action button. A call site names emphasis, never a style.
    ///
    /// For the two things this cannot do from outside the `Button` — a full-width
    /// label, and a prominent label painted for the appearance — use
    /// `ReachyActionButton`, which applies them inside the label and ends here.
    ///
    /// **The prominent tiers are glass on iOS 26 and macOS 26 — everywhere but a
    /// headless capture.** `.buttonStyle(.glass)` does not merely fail to render in
    /// a snapshot the way a material does: it takes the whole capture with it,
    /// blank apart from the toolbar, which is rendered in a separate pass. Measured
    /// by recording the onboarding suite twice on the iOS 26 simulator, and a blank
    /// reference is worse than a missing one — it reads as coverage and passes any
    /// change. So the style reads `reachyPreviewMode`, which every preview sets,
    /// and draws `.borderedProminent` under it. The references therefore certify the
    /// bordered layout, and the glass rendering is a device check — the same trade
    /// `reachySurface` makes, whose glass is invisible headless. What the two share
    /// is the label: `ReachyActionButton` paints it inside, and glass keeps it.
    ///
    /// Glass as a *background* is unaffected and is what `reachySurface` uses: the
    /// viewport's chrome renders correctly through the same simulator. The
    /// difference is that a button style wraps its content and a background does
    /// not — the same distinction that costs a wrapped foreground its colour.
    func reachyButton(_ emphasis: ButtonEmphasis = .standard) -> some View {
        modifier(ReachyButtonStyle(emphasis: emphasis))
    }
}

private struct ReachyButtonStyle: ViewModifier {
    let emphasis: ButtonEmphasis
    @Environment(\.reachyPreviewMode) private var previewMode

    func body(content: Content) -> some View {
        switch emphasis {
        case .prominent: prominent(content)
        case .standard: content.buttonStyle(.bordered)
        // `.borderless` rather than `.plain`: plain drops the tint too, and a
        // tintless label beside a blue one reads as disabled.
        case .quiet: content.buttonStyle(.borderless)
        case .destructive: prominent(content).tint(Tone.danger.style)
        }
    }

    /// Glass on iOS 26 and macOS 26, bordered under a headless capture and below
    /// the floor. The capture is the only place the two differ on purpose: glass
    /// blanks it, and a blank reference is worse than a missing one.
    @ViewBuilder
    private func prominent(_ content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *), !previewMode {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}
