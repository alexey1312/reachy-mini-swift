import ReachyDesign
import ReachyKit
@testable import ReachyUI
import Testing

/// The one mapping between a theme and the scene's paint. The scene itself is
/// covered in `RobotShellTintTests`; what is decided here is the colour it is
/// handed, and when it is handed none.
@Suite("Twin paint")
struct TwinPaintTests {
    @Test("the fallback theme leaves the robot in its own colours")
    func fallbackIsUnpainted() {
        #expect(TwinPaint.shellColor(for: .fallback, paints: true) == nil)
    }

    @Test("switched off, no theme paints the robot", arguments: ReachyTheme.allCases)
    func switchedOffIsUnpainted(theme: ReachyTheme) {
        #expect(TwinPaint.shellColor(for: theme, paints: false) == nil)
    }

    @Test("a theme's tint arrives as its sRGB channels")
    func bronzeChannels() {
        let color = TwinPaint.shellColor(for: .bronze, paints: true)
        #expect(color == URDFColor(red: 1, green: 0xDF / 255, blue: 0xA6 / 255, alpha: 1))
    }

    @Test("the switch is on until the reader turns it off")
    func onByDefault() {
        #expect(TwinPaint.defaultValue)
    }
}
