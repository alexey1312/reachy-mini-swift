import ReachyDesign
import ReachyKit
import SwiftUI

/// Reads the stored theme and applies it, redrawing when it changes.
///
/// `@AppStorage` rather than a `ThemeStore` read: the store is a value type with no
/// change notification, and a scene root has to re-render the moment the picker
/// writes. Both sit on the same key and the same suite, so the widget — which has
/// no SwiftUI to observe with — keeps using `ThemeStore`.
private struct ThemeFromSettings: ViewModifier {
    @AppStorage(ThemeStore.key) private var rawTheme: String = ReachyTheme.fallback.rawValue

    init(defaults: UserDefaults) {
        _rawTheme = AppStorage(
            wrappedValue: ReachyTheme.fallback.rawValue,
            ThemeStore.key,
            store: defaults
        )
    }

    func body(content: Content) -> some View {
        content.reachyTheme(ReachyTheme(rawValue: rawTheme) ?? .fallback)
    }
}

public extension View {
    /// The app's own themed root. The default suite is the shared app group, so the
    /// app and the widget read one value.
    func reachyThemeFromSettings(_ defaults: UserDefaults = KnownRobots.defaults) -> some View {
        modifier(ThemeFromSettings(defaults: defaults))
    }
}
