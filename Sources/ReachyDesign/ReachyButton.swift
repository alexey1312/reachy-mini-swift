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
    /// **There is no glass tier here, and that is a measurement rather than a
    /// preference.** `.buttonStyle(.glass)` does not merely fail to render in a
    /// headless snapshot the way a material does — it takes the whole capture with
    /// it. A screen carrying one comes out blank apart from its toolbar, which is
    /// rendered in a separate pass. Measured by recording the onboarding suite
    /// twice on the iOS 26 simulator: with the glass tier every reference was
    /// empty, with it removed every one was complete, nothing else changed.
    ///
    /// A blank reference is worse than a missing one — it reads as coverage and
    /// passes any change (`ReachyUI/AGENTS.md`) — and roughly sixty of them sit
    /// behind these fourteen call sites. So the styles stay bordered, which iOS 26
    /// draws in its own updated way regardless.
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

    func body(content: Content) -> some View {
        switch emphasis {
        case .prominent: content.buttonStyle(.borderedProminent)
        case .standard: content.buttonStyle(.bordered)
        // `.borderless` rather than `.plain`: plain drops the tint too, and a
        // tintless label beside a blue one reads as disabled.
        case .quiet: content.buttonStyle(.borderless)
        case .destructive: content.buttonStyle(.borderedProminent).tint(Tone.danger.style)
        }
    }
}
