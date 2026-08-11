import ReachyDesign

#if os(iOS)
    import UIKit
#endif

/// Applies a theme's app icon, best effort.
///
/// iOS only. macOS has no alternate icons — `NSApplication.applicationIconImage`
/// reaches the Dock and Cmd-Tab but leaves Finder, Launchpad and Spotlight on the
/// bundle's own icon, which reads as a bug rather than as a feature — so there the
/// theme is colour only and `AppearanceSection` promises nothing else.
///
/// The theme is saved unconditionally by the picker; this is what may fail. On a
/// refusal the picker shows a caption and no alert: iOS already presents its own
/// unsuppressable "You have changed the icon" on *success*, and stacking a second
/// dialog on the failure path would be worse than the failure.
enum AppIconSwitcher {
    /// The bundle name a theme selects, or `nil` for the primary icon.
    static func iconName(for theme: ReachyTheme) -> String? {
        theme.alternateIconName
    }

    /// Whether the icon already in use is the one this theme wants.
    ///
    /// Guarding on this is not an optimisation: `setAlternateIconName` raises the
    /// system alert every time it is called with a *different* name, so without the
    /// guard, re-selecting the theme already applied would show "You have changed
    /// the icon" over an icon that did not change.
    static func isAlreadyApplied(_ theme: ReachyTheme, current: String?) -> Bool {
        iconName(for: theme) == current
    }

    /// `true` when the icon now matches the theme — including the two cases where
    /// there was nothing to do and the case where this platform has no icons to
    /// switch. `false` only when iOS refused.
    @MainActor
    static func apply(_ theme: ReachyTheme) async -> Bool {
        #if os(iOS)
            let application = UIApplication.shared
            guard application.supportsAlternateIcons else { return false }
            guard !isAlreadyApplied(theme, current: application.alternateIconName) else { return true }
            do {
                // Measured: called before the scene is active this throws
                // NSCocoaErrorDomain 3072 (NSUserCancelledError). Every caller is a
                // button tap, so the app is foreground-active by construction — do
                // not move this onto a launch `.task`.
                try await application.setAlternateIconName(iconName(for: theme))
                return true
            } catch {
                return false
            }
        #else
            return true
        #endif
    }
}
