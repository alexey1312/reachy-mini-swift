import SwiftUI

/// Stable handles for UI automation: the `id:` selectors in `Apps/Maestro`.
///
/// A flow that selects by visible text breaks on a copy change and on a simulator
/// left in another language, and it cannot tell two controls with the same label
/// apart. An identifier does none of those things, which is why it is not a
/// `.reachy(…)` string — it is never shown and never translated.
///
/// `MaestroFlowIdentifierTests` reads the flows and fails on an `id:` this enum
/// does not declare, so the YAML and the Swift cannot drift apart silently.
///
/// **A tab bar button cannot carry one, and that is measured.** SwiftUI has had
/// `TabContent.accessibilityIdentifier(_:)` since iOS 18, and it does not reach the
/// button: `maestro hierarchy` on iOS 27.0 shows the tab's *content* carrying its
/// identifier and the tab bar carrying only the SF Symbol's name (`figure.wave` on
/// the Robot tab) — never ours. So the shell's tabs are still selected by their
/// label, and nothing here pretends otherwise.
enum AccessibilityID: String, CaseIterable {
    /// The typed address at the foot of the `Nearby` segment.
    case connectAddress = "connect.address"
    /// Its Connect button — one of several controls in the app labelled "Connect".
    case connectSubmit = "connect.submit"
    case connectBluetoothSetup = "connect.bluetooth-setup"
    /// The disclosure the simulator sits behind.
    case connectDeveloper = "connect.developer"
    case connectStartSimulator = "connect.start-simulator"
}

extension View {
    func accessibilityIdentifier(_ id: AccessibilityID) -> some View {
        accessibilityIdentifier(id.rawValue)
    }
}
