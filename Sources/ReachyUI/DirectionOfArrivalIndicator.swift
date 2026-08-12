import ReachyDesign
import SwiftUI

/// A small badge on the viewport saying where the robot last heard a voice from.
///
/// **An axis, never a compass.** The daemon reports one angle along the robot's
/// left–right line, and π/2 means *in front or behind* with no way to tell which
/// (`DirectionOfArrivalModel.Side.frontOrBehind`). A dial would have to invent the
/// missing half, and would be wrong about it half the time with nothing on screen
/// admitting it. Three glyphs on one axis say exactly what is known.
///
/// It renders nothing at all for a robot that has never answered — `sim-daemon`
/// sends `doa: null` forever, and so does any unit with no microphone array — and
/// nothing while the room is quiet. A badge that is permanently blank is worse than
/// a badge that is absent: it reads as a feature that is broken rather than one the
/// robot does not have.
struct DirectionOfArrivalIndicator: View {
    let model: DirectionOfArrivalModel

    /// The animation belongs to the **container**, not to the badge: a `.transition`
    /// is driven by the parent whose body produced or dropped the child, so an
    /// `.animation` written inside the `if` would never see the insertion it is
    /// meant to soften. An empty `ZStack` measures zero, so the wrapper costs the
    /// chrome row nothing.
    var body: some View {
        ZStack {
            if let heard = model.lastHeard, model.isSupported {
                content(heard)
                    .transition(.opacity)
            }
        }
        .animation(Motion.stateChange, value: model.lastHeard)
    }

    private func content(_ heard: DirectionOfArrivalModel.Heard) -> some View {
        Label(Self.caption(for: heard.side), systemImage: Self.symbol(for: heard.side))
            .font(Typography.status)
            .foregroundStyle(Tone.brand.style)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .reachySurface(.chrome, in: .capsule)
            // The visible label is already words, so this only restates whose left is
            // meant — "the robot heard" rather than "you are on the left".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityLabel(for: heard.side))
    }

    /// **The robot's left, not the reader's**, which is why the caption says so out
    /// loud rather than leaving a glyph to imply it. Looking through the camera and
    /// looking at the 3D model put the robot's left on opposite sides of the screen,
    /// so the only unambiguous thing to draw is a word.
    private static func caption(for side: DirectionOfArrivalModel.Side) -> LocalizedStringResource {
        switch side {
        case .left: .reachy("Heard on its left")
        case .right: .reachy("Heard on its right")
        case .frontOrBehind: .reachy("Heard ahead or behind")
        }
    }

    /// The mirroring symbols are deliberately **not** used here.
    /// `arrow.left`/`arrow.right` rather than `arrow.backward`/`arrow.forward`,
    /// because the direction belongs to the robot and a right-to-left language must
    /// not flip it — the same call `JoystickPad` makes about its own labels.
    private static func symbol(for side: DirectionOfArrivalModel.Side) -> String {
        switch side {
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .frontOrBehind: "arrow.up.and.down"
        }
    }

    private static func accessibilityLabel(
        for side: DirectionOfArrivalModel.Side
    ) -> LocalizedStringResource {
        switch side {
        case .left: .reachy("The robot heard a voice on its left")
        case .right: .reachy("The robot heard a voice on its right")
        case .frontOrBehind: .reachy("The robot heard a voice in front of it or behind it")
        }
    }
}
