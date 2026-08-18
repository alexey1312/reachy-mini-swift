import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// The angle is one number along the robot's left–right axis, and the interesting
/// half of it is what it *cannot* say: `π/2` is in front or behind with no way to
/// tell which. Everything here exists so that degeneracy stays visible instead of
/// being rounded into a confident direction.
@Suite("Direction of arrival")
@MainActor
struct DirectionOfArrivalModelTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - The mapping

    /// `.claude/rules/daemon-api.md`: 0 = left, π/2 = front/back, π = right.
    @Test("zero is the robot's left and pi is its right")
    func mapsTheEndsOfTheAxis() {
        #expect(DirectionOfArrivalModel.side(for: 0) == .left)
        #expect(DirectionOfArrivalModel.side(for: .pi) == .right)
    }

    /// **The reading the hardware cannot disambiguate.** A two-microphone array
    /// measures a delay along one axis, so a voice directly in front and one directly
    /// behind produce the same number. A compass would have to pick one.
    @Test("broadside is reported as ambiguous rather than as a side")
    func refusesToPickBetweenFrontAndBehind() {
        #expect(DirectionOfArrivalModel.side(for: .pi / 2) == .frontOrBehind)
    }

    /// The band has to be wide enough that a voice roughly in front does not
    /// alternate between left and right frame by frame at 5 Hz.
    @Test("the ambiguous band covers both sides of broadside")
    func spansTheBandSymmetrically() {
        let band = DirectionOfArrivalModel.frontBackBand

        #expect(DirectionOfArrivalModel.side(for: .pi / 2 - band * 0.9) == .frontOrBehind)
        #expect(DirectionOfArrivalModel.side(for: .pi / 2 + band * 0.9) == .frontOrBehind)
        #expect(DirectionOfArrivalModel.side(for: .pi / 2 - band * 1.1) == .left)
        #expect(DirectionOfArrivalModel.side(for: .pi / 2 + band * 1.1) == .right)
    }

    /// The daemon's range is the half-circle `[0, π]`, so anything outside it is
    /// noise. **Clamped rather than wrapped**: wrapping a slightly negative reading
    /// would land it just under `2π` and report a confident "right" for a voice on
    /// the left.
    @Test("an angle outside the daemon's range is clamped, never wrapped")
    func clampsRatherThanWraps() {
        #expect(DirectionOfArrivalModel.side(for: -0.5) == .left)
        #expect(DirectionOfArrivalModel.side(for: .pi + 0.5) == .right)
    }

    // MARK: - What the model holds

    @Test("a model with no stream opens nothing and holds nothing")
    func staysInertWithoutAStream() {
        let model = DirectionOfArrivalModel(stream: nil)

        model.start()

        #expect(model.lastHeard == nil)
        #expect(model.isSupported == false)
    }

    /// **`isSupported` is what keeps the badge off a robot that cannot answer.**
    /// `doa` is nullable, `sim-daemon` sends `null` forever, and so does any unit
    /// with no microphone array — a badge mounted on hope would sit blank on every
    /// simulator run and read as broken.
    @Test("a robot that has never answered is not treated as a silent one")
    func separatesUnsupportedFromQuiet() {
        let quiet = DirectionOfArrivalModel.preview(nil)
        let unsupported = DirectionOfArrivalModel.preview(nil, isSupported: false)

        #expect(quiet.isSupported)
        #expect(unsupported.isSupported == false)
        // Indistinguishable in the reading itself, which is the whole reason the two
        // are separate properties.
        #expect(quiet.lastHeard == unsupported.lastHeard)
    }

    @Test("a preview state is final on its first frame")
    func buildsASettledPreview() {
        let model = DirectionOfArrivalModel.preview(.left)

        #expect(model.lastHeard?.side == .left)
        #expect(model.isSupported)
    }

    /// The hold window is retired by the stream rather than by a `Timer` — frames
    /// arrive whether or not anybody is talking, so the stream is a clock the model
    /// already owns. What that buys is this: a reading survives a glance at another
    /// tab, because `stop()` does not clear it.
    @Test("suspending the viewport keeps a reading that is still inside its window")
    func keepsAReadingAcrossASuspend() {
        let model = DirectionOfArrivalModel.preview(.right)

        model.stop()

        #expect(model.lastHeard?.side == .right)
    }
}
