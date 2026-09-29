import Foundation
import ReachyDesign
import ReachyKit

/// Whether the theme paints the 3D twin, and in what.
///
/// The one place that sees both halves: `ReachyScene` paints whatever colour it is
/// handed and knows no themes, `ReachyDesign` knows themes and no robot. The
/// switch exists for whoever watches the twin as an exact mirror of the robot on
/// their desk — they keep their accent and still get the factory white.
///
/// The key lives in the App Group suite with every other setting, and the app's
/// `CloudSettingsMirror` carries it beside `ThemeStore.key`, so a theme and its
/// paint arrive on another device together. `ReachyUI` rather than `ReachyDesign`
/// because the widget draws no robot and has no use for it — the reason
/// `JobNotificationSettings` sits here too.
public enum TwinPaint {
    public static let key = "ReachyUI.paintsTwin"

    /// On until the reader turns it off: the switch is how to opt out of a theme's
    /// paint, not how to opt in.
    static let defaultValue = true

    /// `nil` leaves the description's own colours, which the fallback theme and a
    /// switched-off paint both ask for.
    static func shellColor(for theme: ReachyTheme, paints: Bool) -> URDFColor? {
        guard paints, let hex = theme.shellTint else { return nil }
        return URDFColor(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
