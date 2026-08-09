import CoreGraphics
@testable import ReachyUI

// The gesture harness the floating-viewport suites share — one definition, so the
// shape of "a whole gesture" cannot drift between the model and the release suite.

/// A whole gesture, the shape SwiftUI delivers one: a first `onChanged` already
/// carrying whatever the finger travelled before the recogniser woke up, then the
/// real movement, then a release.
///
/// `from` is that head start, and it defaults to something non-zero on purpose —
/// a test that drags from exactly zero cannot tell a model that subtracts the
/// activation from one that does not.
///
/// `thrown` is how much further the finger was *heading* than where it stopped.
/// Zero means it was set down rather than flicked.
@MainActor
func drag(
    _ model: FloatingViewportModel,
    by translation: CGSize,
    from activation: CGSize = CGSize(width: 6, height: -3),
    thrown: CGSize = .zero,
    in bounds: CGRect
) {
    let raw = activation + translation
    model.dragChanged(translation: activation)
    model.dragChanged(translation: raw)
    model.dragEnded(
        FloatingViewportModel.DragRelease(predictedEndTranslation: raw + thrown),
        in: bounds
    )
}

/// Where the window is actually drawn: the resting centre of whatever `drawn`
/// names, plus what the finger is currently adding. The view sums the same two.
@MainActor
func drawnCentre(_ model: FloatingViewportModel, in bounds: CGRect) -> CGPoint {
    let centre = model.centre(in: bounds)
    let offset = model.dragOffset(in: bounds)
    return CGPoint(x: centre.x + offset.width, y: centre.y + offset.height)
}

extension CGSize {
    static func + (lhs: CGSize, rhs: CGSize) -> CGSize {
        CGSize(width: lhs.width + rhs.width, height: lhs.height + rhs.height)
    }
}
