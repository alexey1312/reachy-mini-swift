import ReachyDesign
import SwiftUI

private struct ReachyDeveloperScreenKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> AnyView)? = nil
}

extension EnvironmentValues {
    /// A screen the app target owns and this package knows nothing about, shown at
    /// the bottom of Settings → Advanced.
    ///
    /// It used to be a tab of its own. It stopped earning one: discovery and manual
    /// connect — the two things it was built for in phase 0 — are what
    /// `ConnectionScreen` does now, for everyone rather than for a developer.
    ///
    /// An environment value rather than a generic parameter because it would
    /// otherwise have to be threaded through `SettingsScreen`, which is presented
    /// from two places that have no business knowing about it. `AnyView` is the
    /// price, paid once, on a screen that ships to nobody.
    ///
    /// Spelled out rather than written with `@Entry`, like `reachyPreviewMode`:
    /// that macro ships in Xcode's SDKs and not in the pinned toolchain.
    var reachyDeveloperScreen: (@MainActor () -> AnyView)? {
        get { self[ReachyDeveloperScreenKey.self] }
        set { self[ReachyDeveloperScreenKey.self] = newValue }
    }
}
