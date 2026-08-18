import Foundation
import ReachyDesign
import ReachyKit

/// What to call the connection in front of a reader.
///
/// Here rather than in `ReachyKit`, for the reason `DaemonFlavourCaption` next door
/// gives: a caller maps its own domain type onto a presentation value, never the
/// other way, so `ReachyKit` never has to link `ReachyDesign`.
///
/// **`Link.displayString` used to do this, and it could not.** The catalogue lives
/// in `ReachyDesign`, which `ReachyKit` does not link and must not, so the string it
/// returned was a bare Swift literal — "Hugging Face relay" rendered in English on
/// all four screens that name the transport, while the very same sentence sat
/// translated in the catalogue for `DaemonFlavourCaption` to use. Exactly the
/// failure rule 9 describes: it reads perfectly, and can never be translated.
enum ConnectionLinkCaption {
    /// A `String` rather than a `LocalizedStringResource`, because one case is not
    /// copy at all: a LAN link renders its address, and no language translates an
    /// IP. `"—"` for `.none` is what the two `LabeledContent` rows have always
    /// shown for a session with no transport.
    static func text(for link: RobotSession.Link) -> String {
        switch link {
        case .none: "—"
        case let .lan(address): address.displayString
        case .remote: String(localized: .reachy("Hugging Face relay"))
        case .simulated: String(localized: .reachy("Simulator"))
        }
    }
}
