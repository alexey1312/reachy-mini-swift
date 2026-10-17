import Foundation

/// The joystick and the headphones clamp their angles with this. `ReachyTeleop` keeps a
/// copy of its own rather than exporting one, as `ReachyKit` does: a public extension on
/// `Double` would reach every module that imports it.
extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
