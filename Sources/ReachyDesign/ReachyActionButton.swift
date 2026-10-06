import SwiftUI

/// The app's action button, for the three things `reachyButton(_:)` cannot do
/// from outside the `Button`: put the width on the label, make the whole label a
/// target, and paint a prominent label in the colour the appearance needs.
///
/// **All three go inside the label, and that is the whole reason this type
/// exists.** `frame(maxWidth: .infinity)` applied after a button style stretches
/// the container and leaves the capsule hugging its text in the middle of it —
/// nine call sites shipped that way, every onboarding step among them, and the
/// references showed a small pill centred under a full-width column.
/// `ConnectHeader.decision` had the right spelling all along; this is that
/// spelling with a name. A frame outside the label is not a target either, for
/// the same reason. And a button style's own foreground beats any
/// `foregroundStyle` set around the button, so the label colour has to be set on
/// the label itself.
///
/// Outer modifiers still belong at the call site: `.disabled`,
/// `.buttonBorderShape`, `.controlSize` all read the same as on a plain `Button`.
public struct ReachyActionButton<Label: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    private let emphasis: ButtonEmphasis
    private let role: ButtonRole?
    private let fullWidth: Bool
    private let action: () -> Void
    private let label: Label

    public init(
        _ emphasis: ButtonEmphasis = .prominent,
        role: ButtonRole? = nil,
        fullWidth: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.emphasis = emphasis
        self.role = role
        self.fullWidth = fullWidth
        self.action = action
        self.label = label()
    }

    public var body: some View {
        Button(role: role, action: action) {
            styledLabel
        }
        .reachyButton(emphasis)
    }

    /// A prominent label carries its own colour; the other tiers leave it to the
    /// style, which already picks a legible one (a destructive capsule is system
    /// red, and white holds ≥ 3:1 on it in either appearance).
    @ViewBuilder
    private var styledLabel: some View {
        let sized = label
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: emphasis.minimumLabelHeight)
            // **Glass answers a tap only where the label draws.** The bordered
            // styles make their own capsule a target; `.glassProminent` does not,
            // and a full-width footer button was reported from a device as
            // answering on its words alone, with the rest of the capsule dead. A
            // frame is empty space, and empty space is not hit-tested until a
            // shape says it is. A rectangle and not a capsule: the label sits
            // inside the capsule's padding, so its corners never reach the curve.
            // A shape changes no pixel, so no reference image can show it.
            .contentShape(.rect)
        if emphasis == .prominent {
            sized.foregroundStyle(ButtonEmphasis.prominentLabel(for: colorScheme))
        } else {
            sized
        }
    }
}

public extension ReachyActionButton where Label == Text {
    init(
        _ title: LocalizedStringResource,
        emphasis: ButtonEmphasis = .prominent,
        role: ButtonRole? = nil,
        fullWidth: Bool = false,
        action: @escaping () -> Void
    ) {
        self.init(emphasis, role: role, fullWidth: fullWidth, action: action) {
            Text(title)
        }
    }
}
