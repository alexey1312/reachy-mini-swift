@testable import ReachyUI
import SwiftUI

// The badge is a component, so every capture opts out of the device trait with
// `.sizeThatFitsLayout` — a full-device reference of a capsule is mostly empty page.
//
// Every state is injected through `DirectionOfArrivalModel.preview(_:)`, which builds
// an address-less model: it has no socket to open, so the first frame is the final
// one. A preview that waited on a stream would capture whatever had arrived by the
// time the shutter fell.

#Preview("Direction of arrival — left", traits: .sizeThatFitsLayout) {
    DirectionOfArrivalIndicator(model: .preview(.left))
        .padding()
}

#Preview("Direction of arrival — right", traits: .sizeThatFitsLayout) {
    DirectionOfArrivalIndicator(model: .preview(.right))
        .padding()
}

// The degenerate reading, and the reason the badge is an axis rather than a compass:
// the microphone array reports one angle along the robot's left–right line, so π/2 is
// *in front or behind* with no way to tell which. This reference is what stops the
// wording being quietly "improved" into a claim.
#Preview("Direction of arrival — ahead or behind", traits: .sizeThatFitsLayout) {
    DirectionOfArrivalIndicator(model: .preview(.frontOrBehind))
        .padding()
}

// A quiet room renders **nothing**, and that is the point of capturing it: a badge
// sitting there blank would read as a broken feature rather than as a robot nobody is
// talking to.
#Preview("Direction of arrival — quiet", traits: .sizeThatFitsLayout) {
    DirectionOfArrivalIndicator(model: .preview(nil))
        .padding()
}

// A robot whose daemon has never sent a `doa` — `sim-daemon` sends `null` forever, and
// so does a unit with no array. Also nothing, and for a different reason: the two are
// indistinguishable in an image, which is exactly why the model keeps them apart.
#Preview("Direction of arrival — no microphone array", traits: .sizeThatFitsLayout) {
    DirectionOfArrivalIndicator(model: .preview(nil, isSupported: false))
        .padding()
}
