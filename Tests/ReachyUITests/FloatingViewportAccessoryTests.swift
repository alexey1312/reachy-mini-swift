import CoreGraphics
import Foundation
import ReachyDesign
@testable import ReachyUI
import SwiftUI
import Testing

/// What the running-app strip does to the window, and what a bottom corner asks
/// of the tabs. Beside `FloatingViewportModelTests`, which is at the file limit.
@MainActor
@Suite("Floating viewport and the running-app strip", .timeLimit(.minutes(1)))
struct FloatingViewportAccessoryTests {
    private func model(_ rest: FloatingViewportModel.Placement) -> FloatingViewportModel {
        .preview(rest, hasTabBar: true, isLiveTabSelected: false, isEnabled: true)
    }

    @Test("the strip arriving lifts a bottom-corner window to the top corner on its side")
    func stripLiftsTheWindow() {
        let trailing = model(.floating(.bottomTrailing))
        let leading = model(.floating(.bottomLeading))

        trailing.hasBottomAccessory = true
        leading.hasBottomAccessory = true

        #expect(trailing.placement == .floating(.topTrailing))
        #expect(leading.placement == .floating(.topLeading))
    }

    @Test("the strip leaving moves nothing, and a top corner or a docked tab is left alone")
    func stripLeavesTheRestAlone() {
        let top = model(.floating(.topLeading))
        let docked = model(.docked(.trailing, y: 300))

        top.hasBottomAccessory = true
        docked.hasBottomAccessory = true
        #expect(top.placement == .floating(.topLeading))
        #expect(docked.placement == .docked(.trailing, y: 300))

        let lifted = model(.floating(.bottomTrailing))
        lifted.hasBottomAccessory = true
        lifted.hasBottomAccessory = false
        #expect(lifted.placement == .floating(.topTrailing))
    }

    @Test("a bottom corner reserves the bottom of every tab, and nothing else does")
    func bottomCornerReservesTheBottom() {
        #expect(FloatingViewportModel.Placement.floating(.bottomTrailing).restsAtBottomCorner)
        #expect(FloatingViewportModel.Placement.floating(.bottomLeading).restsAtBottomCorner)
        #expect(!FloatingViewportModel.Placement.floating(.topTrailing).restsAtBottomCorner)
        #expect(!FloatingViewportModel.Placement.docked(.leading, y: 100).restsAtBottomCorner)
        #expect(!FloatingViewportModel.Placement.inline.restsAtBottomCorner)
        #expect(!FloatingViewportModel.Placement.column.restsAtBottomCorner)
    }
}
