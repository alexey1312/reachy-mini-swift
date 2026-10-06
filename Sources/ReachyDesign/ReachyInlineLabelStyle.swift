import SwiftUI

/// A label's glyph tight against its word, wherever the label sits.
///
/// **A `Form` row sets a `Label`'s icon in a column of its own.** That is right for
/// the row's own label and wrong for a label *inside* the row — a badge, a button
/// or a status beside a row title. Measured off the references by ink columns:
/// the seal stood 21 pt from "Official", the Install glyph 18.5 pt from "Install",
/// and the Robot tab's check 18 pt from "Connected", whose row separator also
/// started under "Connected" rather than at the row's inset. This style sets the
/// glyph and the word in one stack, so the row has no icon to put in a column.
///
/// `Space.xs` between the two frames, which the side bearings make about 6 pt
/// between the inks in a badge. Centred, as the badges' own style was before this
/// one replaced it, so the badges do not move.
public struct ReachyInlineLabelStyle: LabelStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.xs) {
            configuration.icon
            configuration.title
        }
    }
}

public extension LabelStyle where Self == ReachyInlineLabelStyle {
    /// The glyph tight against its word, outside a row's icon column.
    static var reachyInline: ReachyInlineLabelStyle {
        ReachyInlineLabelStyle()
    }
}
