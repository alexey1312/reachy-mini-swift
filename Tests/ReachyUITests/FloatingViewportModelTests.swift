import CoreGraphics
import Foundation
import ReachyDesign
@testable import ReachyUI
import SwiftUI
import Testing

@MainActor
@Suite("Floating viewport", .timeLimit(.minutes(1)))
struct FloatingViewportModelTests {
    /// An iPhone's safe area, near enough: what matters is that the four corners
    /// are distinct and the window fits inside with room to spare.
    private static let portrait = CGRect(x: 0, y: 0, width: 400, height: 800)
    /// The same screen once the running-app strip is up: `Metrics.tabAccessoryAllowance`
    /// shorter, which is the change that used to land under a finger mid-drag.
    private static let withAccessory = CGRect(x: 0, y: 0, width: 400, height: 732)

    private func model(
        _ rest: FloatingViewportModel.Placement = .floating(.bottomTrailing),
        hasTabBar: Bool = true,
        live: Bool = false,
        enabled: Bool = true
    ) -> FloatingViewportModel {
        .preview(rest, hasTabBar: hasTabBar, isLiveTabSelected: live, isEnabled: enabled)
    }

    // MARK: - The placement automaton

    @Test("a fresh connection floats in a corner, live")
    func startsFloating() {
        let model = FloatingViewportModel()
        model.hasTabBar = true

        #expect(model.placement == .floating(.bottomTrailing))
        #expect(model.isStreaming)
        #expect(!model.isInline)
    }

    /// The single value all three hosts read, and what keeps a second `RealityView`
    /// off the screen. **It used to compare two predicates that were each other's
    /// negation**, which held for any input at all and certified nothing; with a third
    /// host the count is what has to be one.
    @Test("exactly one of the three hosts draws")
    func exactlyOneHost() {
        let rests: [FloatingViewportModel.Placement] = [
            .floating(.topLeading),
            .floating(.bottomTrailing),
            .docked(.leading, y: 200),
            .docked(.trailing, y: 600),
        ]
        for rest in rests {
            for hasTabBar in [true, false] {
                for live in [true, false] {
                    for enabled in [true, false] {
                        let model = model(rest, hasTabBar: hasTabBar, live: live, enabled: enabled)
                        let hosts = [model.isInline, model.isWindowed, model.placement == .column]
                        let drawing = hosts.filter(\.self).count
                        #expect(drawing == 1)
                        #expect(model.isInline == (model.placement == .inline))
                        #expect(!(model.isStreaming && model.isInline))
                    }
                }
            }
        }
    }

    @Test("selecting Live hands the viewport to the tab and gives it back")
    func inlineIsReversible() {
        let model = model()
        drag(model, by: CGSize(width: -300, height: -600), in: Self.portrait)
        model.finishSettling()
        let before = model.placement

        model.isLiveTabSelected = true
        #expect(model.placement == .inline)

        model.isLiveTabSelected = false
        #expect(model.placement == before)
    }

    /// **This asserted `.inline` and no stream until the column existed**, and the
    /// `live` half is a bug fix on top of that: a sidebar has exactly one host, so
    /// selecting Live must not move the viewport. `placement`'s own note carries the
    /// measurement that forced it. `rest` is ignored because a column has neither
    /// corner nor edge.
    @Test("a sidebar has one host, whatever the tab and the window were doing")
    func regularWidthUsesTheColumn() {
        let rests: [FloatingViewportModel.Placement] = [
            .floating(.topLeading),
            .docked(.leading, y: 200),
            .docked(.trailing, y: 600),
        ]
        for rest in rests {
            for live in [false, true] {
                let model = model(rest, hasTabBar: false, live: live)
                #expect(model.placement == .column)
                #expect(model.isStreaming)
                #expect(!model.isInline)
                #expect(!model.isWindowed)
            }
        }
    }

    /// Switched off under a sidebar is the one state that still behaves the way this
    /// target did before either second place existed — which is what the switch is for.
    @Test("switched off, a sidebar hands the viewport back to the tab")
    func disabledSidebarIsInline() {
        let model = model(hasTabBar: false, enabled: false)

        #expect(model.placement == .inline)
        #expect(model.isInline)
        #expect(!model.isStreaming)
    }

    /// The overlay is not on screen at all while the tab has the viewport, so a
    /// half-finished animation must not out-vote that.
    @Test("inline out-votes an animation in flight")
    func inlineOutvotesSettling() {
        let model = model()
        model.beginDocking(.leading, in: Self.portrait)

        model.isLiveTabSelected = true
        #expect(model.drawn == .inline)
        #expect(model.placement == .inline)
    }

    // MARK: - The switch on the Live tab

    /// Off is a fourth input to the same derivation, not a fourth state: every
    /// placement collapses to `.inline`, which is exactly the shape a sidebar layout
    /// already had. So the tab draws the viewport, the overlay draws nothing, and
    /// nothing in `RootLifecycle` has to learn that the switch exists.
    @Test("switched off, nothing floats and nothing streams")
    func disabledCollapsesToInline() {
        let rests: [FloatingViewportModel.Placement] = [
            .floating(.topLeading),
            .floating(.bottomTrailing),
            .docked(.leading, y: 200),
        ]
        for rest in rests {
            for live in [true, false] {
                let model = FloatingViewportModel.preview(rest, isLiveTabSelected: live, isEnabled: false)
                #expect(model.placement == .inline)
                #expect(model.isInline)
                #expect(!model.isStreaming)
            }
        }
    }

    /// `rest` remembers a window that was thrown at an edge, so switching back on
    /// without this returns a 44 pt tab at the screen's border — indistinguishable
    /// from a switch that does nothing, which is the complaint it exists to answer.
    @Test("switching back on lands in a corner, not where the window was left")
    func enablingReturnsToACorner() throws {
        let model = try switchable()
        model.beginDocking(.leading, in: Self.portrait)
        model.finishSettling()
        #expect(model.rest == .docked(.leading, y: 728))

        model.setEnabled(false)
        #expect(model.placement == .inline)

        model.setEnabled(true)
        #expect(model.rest == .floating(.bottomTrailing))
        #expect(model.placement == .floating(.bottomTrailing))
        #expect(model.isStreaming)
    }

    /// The guard, and it is load-bearing: a `Toggle` writes its binding whenever
    /// SwiftUI decides to, and without this any such write would yank a window the
    /// reader had put away back into a corner.
    @Test("writing the switch to what it already says moves nothing")
    func idleWriteIsANoOp() throws {
        let model = try switchable()
        model.beginDocking(.trailing, in: Self.portrait)
        model.finishSettling()

        model.setEnabled(true)
        #expect(model.rest == .docked(.trailing, y: 728))
    }

    /// The one input to `placement` that outlives the app. A docked window belongs
    /// to the connection and comes back with the next one; being switched off does
    /// not, which is the whole difference between the gesture and this.
    @Test("the switch outlives the model that wrote it")
    func choiceIsRemembered() throws {
        let preferences = try FloatingViewportPreferences(defaults: #require(isolatedDefaults()))

        #expect(FloatingViewportModel(preferences: preferences).isEnabled)

        FloatingViewportModel(preferences: preferences).setEnabled(false)
        #expect(!FloatingViewportModel(preferences: preferences).isEnabled)

        FloatingViewportModel(preferences: preferences).setEnabled(true)
        #expect(FloatingViewportModel(preferences: preferences).isEnabled)
    }

    /// A suite nothing has written reads as on: the window is what this app has
    /// always done, and never having found the switch is not a decision.
    @Test("an untouched preference reads as on")
    func defaultsToEnabled() throws {
        let preferences = try FloatingViewportPreferences(defaults: #require(isolatedDefaults()))
        #expect(preferences.isEnabled)
    }

    /// `swift test --parallel` runs suites concurrently against one `UserDefaults`
    /// table, so every test that writes gets a table of its own.
    private func isolatedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: "FloatingViewportModelTests.\(UUID().uuidString)")
    }

    private func switchable() throws -> FloatingViewportModel {
        let model = try FloatingViewportModel(
            preferences: FloatingViewportPreferences(defaults: #require(isolatedDefaults()))
        )
        model.hasTabBar = true
        return model
    }

    // MARK: - Putting the window away, in two phases

    /// **The whole point of `settling`.** While the window is animating into its edge
    /// the renderer is still mounted and the stream still running, so RealityKit is
    /// not being torn down on the frames the animation is trying to draw. `rest`, and
    /// with it `isStreaming`, moves only once the animation reports itself done.
    @Test("docking animates first and stops the stream afterwards")
    func dockingIsTwoPhase() {
        let model = model()

        model.beginDocking(.leading, in: Self.portrait)
        #expect(model.drawn == .docked(.leading, y: 728))
        #expect(model.centre(in: Self.portrait) == CGPoint(x: 22, y: 728))
        #expect(model.placement == .floating(.bottomTrailing))
        #expect(model.isStreaming)

        model.finishSettling()
        #expect(model.placement == .docked(.leading, y: 728))
        #expect(model.drawn == .docked(.leading, y: 728))
        #expect(!model.isStreaming)
    }

    /// The mirror, and for the same reason the other way round: the stream starts
    /// *after* the window has finished growing, so the window arrives empty and the
    /// picture appears in it rather than stuttering into place with it.
    @Test("undocking animates first and starts the stream afterwards")
    func undockingIsTwoPhase() {
        let model = model(.docked(.trailing, y: 320))

        model.beginUndocking(in: Self.portrait)
        #expect(model.drawn == .floating(.topTrailing))
        #expect(model.placement == .docked(.trailing, y: 320))
        #expect(!model.isStreaming)

        model.finishSettling()
        #expect(model.placement == .floating(.topTrailing))
        #expect(model.isStreaming)
    }

    @Test("finishing nothing is not an error")
    func finishSettlingIsIdempotent() {
        let model = model()

        model.finishSettling()
        #expect(model.placement == .floating(.bottomTrailing))

        model.beginDocking(.trailing, in: Self.portrait)
        model.finishSettling()
        model.finishSettling()
        #expect(model.placement == .docked(.trailing, y: 728))
    }

    @Test("a docked window stays docked through a visit to the Live tab")
    func dockSurvivesInline() {
        let model = model()
        model.beginDocking(.trailing, in: Self.portrait)
        model.finishSettling()

        model.isLiveTabSelected = true
        #expect(model.placement == .inline)
        #expect(!model.isStreaming)

        model.isLiveTabSelected = false
        #expect(model.placement == .docked(.trailing, y: 728))
        #expect(!model.isStreaming)
    }

    /// Neither the content switch nor a lost connection is an input to this model —
    /// which is the point. The window keeps its corner while the robot goes
    /// unreachable, and switching 3D for the camera moves nothing.
    @Test("nothing but a gesture or the tab moves the window")
    func placementHasNoOtherInputs() {
        let model = model(.docked(.leading, y: 300))
        let viewport = ViewportModel.preview()

        viewport.setContent(.camera)
        #expect(model.placement == .docked(.leading, y: 300))

        viewport.setContent(.scene)
        #expect(model.placement == .docked(.leading, y: 300))
    }

    // MARK: - Dragging

    /// SwiftUI's first `onChanged` already carries everything the finger travelled
    /// before `minimumDistance` was crossed — 4 pt at the very least and arbitrarily
    /// more from a fast finger. Taking it at face value teleported the window by a
    /// speed-dependent amount at every single touch-down.
    @Test("a drag starts where the window already is, however fast the finger was")
    func activationDoesNotJump() {
        let model = model()

        model.dragChanged(translation: CGSize(width: 30, height: -18))
        #expect(model.dragOffset(in: Self.portrait) == .zero)
        #expect(drawnCentre(model, in: Self.portrait) == CGPoint(x: 304, y: 728))

        model.dragChanged(translation: CGSize(width: -70, height: -18))
        #expect(model.dragOffset(in: Self.portrait) == CGSize(width: -100, height: 0))
    }

    /// SwiftUI can drop a `DragGesture` without ever calling `onEnded` — and the
    /// window's own subtree really is unmounted mid-gesture, whenever the Live tab is
    /// selected or the robot stops answering. Nothing may survive that.
    @Test("a cancelled gesture leaves the window on its corner, not in mid-air")
    func cancelledDragIsForgotten() {
        let model = model()
        model.dragChanged(translation: .zero)
        model.dragChanged(translation: CGSize(width: -150, height: -300))
        #expect(model.dragOffset(in: Self.portrait) != .zero)

        model.endDrag()

        #expect(model.dragOffset(in: Self.portrait) == .zero)
        #expect(model.placement == .floating(.bottomTrailing))
        #expect(drawnCentre(model, in: Self.portrait) == CGPoint(x: 304, y: 728))
    }

    /// The running-app strip arrives on a poll, so it can arrive with a finger down.
    /// The offset is a pure function of the translation, so the only thing that moves
    /// is the anchor — by exactly the allowance, and not a point more. It used to be
    /// measured against the rectangle of the first `onChanged` and drift on top.
    @Test("the dock arriving mid-drag moves the window by the allowance and no more")
    func boundsChangeMidDragDoesNotDrift() {
        let model = model()
        model.dragChanged(translation: .zero)
        model.dragChanged(translation: CGSize(width: -100, height: -200))

        let travel = CGSize(width: -100, height: -200)
        #expect(model.dragOffset(in: Self.portrait) == travel)
        #expect(model.dragOffset(in: Self.withAccessory) == travel)

        let before = drawnCentre(model, in: Self.portrait)
        let after = drawnCentre(model, in: Self.withAccessory)
        #expect(after.x == before.x)
        #expect(before.y - after.y == Metrics.tabAccessoryAllowance)
    }

    /// The clamp bites at (96, 72) and (304, 728); the band may spend at most the
    /// 16 pt margin past each, which lands the window's own edge exactly on the
    /// screen's and never over it.
    @Test("the window resists past the margin and never leaves the screen")
    func dragResistsAtTheMargin() {
        let model = model()
        model.dragChanged(translation: .zero)

        model.dragChanged(translation: CGSize(width: -5000, height: -5000))
        let pressed = drawnCentre(model, in: Self.portrait)
        #expect(pressed.x > 80 && pressed.x < 96)
        #expect(pressed.y > 56 && pressed.y < 72)

        model.dragChanged(translation: CGSize(width: 5000, height: 5000))
        let opposite = drawnCentre(model, in: Self.portrait)
        #expect(opposite.x > 304 && opposite.x < 320)
        #expect(opposite.y > 728 && opposite.y < 744)
    }

    /// The rubber band inherits `boundsChangeMidDragDoesNotDrift`'s contract: the
    /// offset is a pure function of the translation and the rectangle it is asked
    /// about, so a drag pressed past the bottom margin re-derives against whichever
    /// rectangle arrives — in any order, without drift, and without crossing either
    /// rectangle's true edge.
    @Test("a drag pressed past the margin re-derives cleanly when the dock arrives")
    func rubberBandSurvivesBoundsChangeMidDrag() {
        let model = model()
        model.dragChanged(translation: .zero)
        model.dragChanged(translation: CGSize(width: 60, height: 300))

        let first = drawnCentre(model, in: Self.withAccessory)
        let interleaved = drawnCentre(model, in: Self.portrait)
        let second = drawnCentre(model, in: Self.withAccessory)
        #expect(first == second)

        let halfHeight = Metrics.floatingViewport.height / 2
        #expect(interleaved.y + halfHeight < Self.portrait.maxY)
        #expect(second.y + halfHeight < Self.withAccessory.maxY)
    }
}
