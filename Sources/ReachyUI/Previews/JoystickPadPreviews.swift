@testable import ReachyUI
import SwiftUI

// A preview with no `traits:` is captured at full device size — Prefire defaults the trait list
// to `.device`. Components that should be measured at their intrinsic height opt out with
// `.sizeThatFitsLayout`.

#Preview("Joystick — screen") {
    JoystickPad { _ in }
        .padding()
}

#Preview("Joystick — component", traits: .sizeThatFitsLayout) {
    JoystickPad { _ in }
        .padding()
}

// The lit slice has no gesture behind it in a snapshot, so the deflection is injected.
#Preview("Joystick — turning", traits: .sizeThatFitsLayout) {
    JoystickPad(deflection: .init(x: 0.95, y: -0.2)) { _ in }
        .padding()
}

// What the widened zone is for, and the state the old one could not reach: a push into
// the corner of the pad turns the body just as a level one does. At the previous
// threshold this knob sat outside the zone with the pad unlit.
#Preview("Joystick — turning from the corner", traits: .sizeThatFitsLayout) {
    JoystickPad(deflection: .init(x: -0.62, y: 0.72)) { _ in }
        .padding()
}
