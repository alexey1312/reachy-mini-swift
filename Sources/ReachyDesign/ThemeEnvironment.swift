import SwiftUI

private struct ReachyThemeKey: EnvironmentKey {
    static let defaultValue = ReachyTheme.fallback
}

public extension EnvironmentValues {
    /// The theme in force. Defaults to `.fallback`, which is what makes an
    /// un-themed preview or snapshot render exactly what a fresh install shows.
    ///
    /// Spelled out rather than written with `@Entry`: that macro ships in Xcode's
    /// SDKs and not in the pinned swift.org toolchain, so it would break
    /// `swift build` — the same reason `reachyPreviewMode` is hand-written.
    var reachyTheme: ReachyTheme {
        get { self[ReachyThemeKey.self] }
        set { self[ReachyThemeKey.self] = newValue }
    }
}

public extension View {
    /// Applies a theme: the value for anything that reads it, and the tint every
    /// system control follows.
    ///
    /// Belongs at a scene's entry point, never at `ReachyRootView`. Environment
    /// resolves nearest-to-leaf, so a root that read the store itself would
    /// overwrite whatever a preview injected — and the snapshot suite could then
    /// only ever capture the default.
    func reachyTheme(_ theme: ReachyTheme) -> some View {
        environment(\.reachyTheme, theme)
            .tint(theme.accent)
    }
}
