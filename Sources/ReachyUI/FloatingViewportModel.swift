import Observation
import ReachyDesign
import SwiftUI

/// Where the one live view of the robot is drawn, and the geometry of the window
/// that carries it off the Live tab.
///
/// **`placement` is derived, never assigned.** `LiveTab` draws the viewport only
/// at `.inline` and the overlay only at everything else, so the two predicates
/// come out of a single value and there is no state in which both are true. That
/// is what keeps `ReachyScene/AGENTS.md`'s "move the view; never mount two" true
/// by construction rather than by review — an `Entity` has one parent, and a
/// second `RealityView` would silently take the robot from the first.
///
/// The gesture's starting values are stored properties rather than
/// `@GestureState`, which is the shape `OrbitCamera` already uses and the only one
/// in this project.
///
/// **Two placements are in play while anything is moving, and the split is the whole
/// design.** `drawn` is where the geometry is heading and `placement` is what is
/// mounted — they differ for exactly as long as an animation runs. Keeping them apart
/// is what lets the window morph on **one** SwiftUI identity: two `switch` branches
/// returning structurally different views have different identities, and nothing
/// geometric can interpolate across an identity boundary, so `withAnimation` was left
/// with only the default opacity transition to run. It is also what moves the
/// RealityKit teardown out of the animation: see `settling`.
@MainActor
@Observable
final class FloatingViewportModel {
    /// What a finished drag carries: where the finger was *heading*, never where it
    /// stopped. A flick and a haul end in the same place and mean different things, and
    /// the finger that was set down needs no second point — at rest SwiftUI predicts
    /// where it already is, so one value answers both.
    ///
    /// It comes straight off `DragGesture.Value` and is still measured from the touch,
    /// so the model subtracts its own `activation` — a caller must not do it twice.
    struct DragRelease {
        let predictedEndTranslation: CGSize
    }

    /// Where the window sits whenever the tab does not have it. Never `.inline` —
    /// that case belongs to `placement`, which is what merges this with the two
    /// inputs below.
    private(set) var rest: Placement = .floating(.bottomTrailing)

    /// Whether the shell is showing a tab bar rather than a sidebar. Written by
    /// the modifier that mounts the overlay, because that is the one place the
    /// size class is read.
    ///
    /// False collapses everything back to today's behaviour: the viewport is the
    /// tab's, always, and `isStreaming` is never true — so a sidebar layout cannot
    /// leave a stream running behind a screen that is not showing it.
    var hasTabBar = false

    /// Whether the Live tab is the selected one. Written by the shell.
    var isLiveTabSelected = false

    /// Whether the window is offered at all — the only one of `placement`'s four
    /// inputs that outlives the app.
    ///
    /// **The gesture is not half of this switch.** Throwing the window at an edge
    /// answers "get out of the way for a minute" and leaves a tab saying how to get
    /// it back; this answers "do not offer it". Off collapses `placement` to
    /// `.inline` — the shape a sidebar layout already had, which is why nothing in
    /// `RootLifecycle` needs to know it exists.
    private(set) var isEnabled: Bool

    /// Whether the running-app strip is on screen. Written by the shell, because
    /// neither placement the strip can take is reported to the overlay's safe area —
    /// the system's accessory slot is invisible to it for the same reason the tab
    /// bar is, and the fallback's inset sits *inside* a tab, one level further in
    /// than the overlay can see.
    var hasBottomAccessory = false

    /// Set while the window grows to fill the screen, in the instant before the
    /// tab takes the viewport over. There is no matched transition to be had here
    /// — that would need both hosts alive at once — so the overlay animates its
    /// own frame and hands the content over only once it is done.
    private(set) var isExpanding = false

    /// Where the window is heading while an animation runs, and `nil` at rest.
    ///
    /// **This is what keeps RealityKit out of the animation.** Assigning `rest`
    /// directly took `isStreaming` false in the same runloop turn the animation
    /// started, and `RootLifecycle` answers that synchronously with
    /// `viewport.setActive(false)` → `pauseStream()` on the main actor — a stall
    /// landing on the frames the animation was trying to draw. The geometry follows
    /// `drawn`, so it can leave immediately; `rest` waits for `finishSettling()`.
    ///
    /// The two directions want the wait for opposite reasons, and both get it:
    /// docking keeps the renderer mounted while it fades, undocking keeps the stream
    /// off until the window has finished growing, so the picture appears in a window
    /// that has already arrived.
    private(set) var settling: Placement?

    /// How far the finger has carried the window since the gesture woke up. A pure
    /// function of the gesture — nothing about the screen is captured when it begins,
    /// so a rectangle that changes mid-drag re-clamps and cannot drift, and a gesture
    /// SwiftUI drops without an `onEnded` leaves nothing behind but this one value.
    private(set) var dragTranslation: CGSize = .zero

    /// The translation SwiftUI reported the moment it woke the recogniser up. It is
    /// never zero: `minimumDistance` means the first `onChanged` already carries
    /// everything the finger travelled before the gesture existed — 4 pt at the very
    /// least, and arbitrarily more from a fast finger. Subtracting it is what stops
    /// the window teleporting by a speed-dependent amount at every touch-down.
    private var activation: CGSize?

    private let preferences: FloatingViewportPreferences

    init(preferences: FloatingViewportPreferences = FloatingViewportPreferences()) {
        self.preferences = preferences
        isEnabled = preferences.isEnabled
    }

    var placement: Placement {
        isLiveTabSelected || !hasTabBar || !isEnabled ? .inline : rest
    }

    /// The placement the geometry draws: where an animation in flight is heading, and
    /// the real one otherwise. Inline out-votes both — the overlay is not on screen at
    /// all while the tab has the viewport.
    var drawn: Placement {
        guard !isInline else { return .inline }
        return settling ?? placement
    }

    /// The window's size at rest in whichever placement is being drawn. The content
    /// inside keeps `Metrics.floatingViewport` and is clipped by this, so the
    /// renderer's own frame never moves and the morph costs no layout.
    var drawnSize: CGSize {
        switch drawn {
        case .inline, .floating: Metrics.floatingViewport
        case .docked: Metrics.viewportTab
        }
    }

    /// The edge the drawn shape is flush with, and `nil` where it is flush with
    /// nothing. Feeds `Radius.flush(to:_:)`, which is what squares off the two corners
    /// that meet the screen.
    var drawnEdge: HorizontalEdge? {
        if case let .docked(edge, _) = drawn {
            edge
        } else {
            nil
        }
    }

    /// Whether the tab owns the viewport. The overlay draws exactly when this is
    /// false, and `LiveTab` exactly when it is true.
    var isInline: Bool {
        placement == .inline
    }

    /// The one thing `RootLifecycle` asks: is anything outside the Live tab
    /// keeping the stream alive? A docked window is the off switch, so it is not.
    var isStreaming: Bool {
        if case .floating = placement {
            true
        } else {
            false
        }
    }

    // MARK: - Placement

    /// The switch on the Live tab, and the only writer of `isEnabled`.
    ///
    /// **Coming back lands in a corner, never where the window was left.** `rest`
    /// remembers one that was thrown at an edge, and restoring a 44 pt tab is
    /// indistinguishable from a switch that does nothing — which is the very
    /// complaint this exists to answer, wearing a different hat.
    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        preferences.isEnabled = enabled
        if enabled {
            rest = .floating(.bottomTrailing)
        }
    }

    /// The window was tapped: grow it, then let the caller select the tab. Split
    /// in two so the model never has to know what a `router` is.
    func beginExpanding() {
        isExpanding = true
    }

    func endExpanding() {
        isExpanding = false
    }

    /// Starts switching the window off at an edge, keeping the height it was at. The
    /// one lever the user has over the stream, and the reason `isStreaming` exists.
    ///
    /// Only the geometry moves here. `finishSettling()` is what stops the stream, and
    /// the caller owes it that call from the animation's completion handler.
    func beginDocking(_ edge: HorizontalEdge, in bounds: CGRect) {
        guard case .floating = rest, settling == nil else { return }
        settling = .docked(edge, y: Self.clampedTabY(centre(in: bounds).y, in: bounds))
    }

    /// The tab at the edge was tapped. The window comes back to whichever corner
    /// is nearest where it was hiding, and the stream comes back once it has arrived.
    func beginUndocking(in bounds: CGRect) {
        guard case let .docked(edge, y) = rest, settling == nil else { return }
        let centre = Self.tabCentre(edge: edge, y: y, in: bounds)
        // A degenerate rectangle has no nearest anything; the edge it was hiding at
        // is still the side it should come back to.
        let fallback: Corner = edge == .leading ? .bottomLeading : .bottomTrailing
        settling = .floating(Self.nearestCorner(to: centre, in: bounds) ?? fallback)
    }

    /// The animation reported itself done: adopt where it was heading. A no-op when
    /// nothing was in flight, so a completion handler never has to check first — and
    /// a drag that snapped to a corner rather than docking takes the same path as one
    /// that did.
    func finishSettling() {
        guard let settling else { return }
        rest = settling
        self.settling = nil
    }

    /// Keeps a docked tab inside a rotated or resized screen. A floating window
    /// needs nothing — its corner is already relative.
    func fit(to bounds: CGRect) {
        guard case let .docked(edge, y) = rest else { return }
        rest = .docked(edge, y: Self.clampedTabY(y, in: bounds))
    }

    // MARK: - Dragging

    /// Where the drawn placement rests. The live drag is **not** in here — it is
    /// `dragOffset(in:)`, and the view adds the two. Keeping them apart is what lets
    /// the finger drive a render-time `.offset` while `.position` carries only the
    /// resting point, so no layout pass runs over the renderer per touch event.
    func centre(in bounds: CGRect) -> CGPoint {
        Self.centre(of: drawn, in: bounds)
    }

    /// What the finger is adding to the resting centre, resisted past the margin so
    /// the window presses toward the screen's edge without ever crossing it. Zero at
    /// rest, and zero the instant the gesture ends, which is what makes the release
    /// continuous: the offset collapsing to zero and the resting centre moving to the
    /// destination happen in one animated transaction, so their sum never jumps.
    func dragOffset(in bounds: CGRect) -> CGSize {
        guard case let .floating(corner) = rest, dragTranslation != .zero else { return .zero }
        let anchor = Self.centre(of: corner, in: bounds)
        let moved = CGPoint(
            x: anchor.x + dragTranslation.width,
            y: anchor.y + dragTranslation.height
        )
        let drawn = Self.rubberBanded(moved, in: bounds)
        return CGSize(width: drawn.x - anchor.x, height: drawn.y - anchor.y)
    }

    /// Takes no rectangle on purpose: whatever this stores has to stay true across a
    /// screen that changes shape under a finger, and the running-app strip does
    /// exactly that on a poll.
    func dragChanged(translation: CGSize) {
        guard case .floating = rest, settling == nil else { return }
        let activation = activation ?? translation
        self.activation = activation
        dragTranslation = CGSize(
            width: translation.width - activation.width,
            height: translation.height - activation.height
        )
    }

    /// A drag that carried — or threw — the window past its own corner's edge
    /// switches it off; anything else snaps to the nearest corner.
    ///
    /// **The predicted end point decides, not where the finger stopped.** That is what
    /// makes a flick enough: the window keeps going the way it was thrown, and a
    /// smaller movement with speed behind it reaches the edge that the same movement
    /// set down does not.
    ///
    /// The test is the *unclamped* point, not the drawn one: the window stops at the
    /// margin while the finger keeps going, and that overshoot is the whole signal.
    /// Without it a drag that merely ended at the edge would dock, and the stream
    /// would stop because someone parked the window on the left.
    func dragEnded(_ release: DragRelease, in bounds: CGRect) {
        defer { endDrag() }
        guard let target = resolved(release, in: bounds) else { return }
        // A corner needs no second phase — nothing is mounted or unmounted by moving
        // between two floating positions — but taking `settling` either way is what
        // lets one completion handler serve every release.
        if case .docked = target {
            settling = target
        } else {
            rest = target
        }
    }

    /// How far the window still has to travel if it were released now.
    ///
    /// The view needs this to seed the spring, and cannot work it out itself: a spring's
    /// initial velocity is a fraction of the *journey* per second, so it means nothing
    /// until the journey is known — and the journey is only known once the release has
    /// been resolved, which is what this shares with `dragEnded`.
    func releaseDistance(for release: DragRelease, in bounds: CGRect) -> CGFloat {
        guard let target = resolved(release, in: bounds) else { return 0 }
        let resting = centre(in: bounds)
        let offset = dragOffset(in: bounds)
        let from = CGPoint(x: resting.x + offset.width, y: resting.y + offset.height)
        let to = Self.centre(of: target, in: bounds)
        return hypot(to.x - from.x, to.y - from.y)
    }

    /// Where a release lands — decided, not adopted. `nil` when there is no gesture to
    /// resolve, which is also what makes `dragEnded` a no-op for a stray `onEnded`.
    private func resolved(_ release: DragRelease, in bounds: CGRect) -> Placement? {
        guard case let .floating(corner) = rest, settling == nil, activation != nil else { return nil }
        let thrown = adjusted(release.predictedEndTranslation)
        let anchor = Self.centre(of: corner, in: bounds)
        let moved = CGPoint(x: anchor.x + thrown.width, y: anchor.y + thrown.height)
        let resting = Self.clamped(moved, in: bounds)
        let nearest = Self.nearestCorner(to: resting, in: bounds)
        // Hiding is offered only in the corner the window already holds: a throw that
        // changes corner is aimed at a corner, however much sideways speed it carries.
        // A fast vertical flick predicts hundreds of points of x from a few degrees of
        // drift, and used to trip the overshoot and hide the window at the top of an
        // edge. Equality with `corner` also pins the edge — a point clamped against an
        // edge is always in that edge's half, so a trailing corner can only ever
        // overshoot trailing. VoiceOver's explicit "Hide at…" actions go through
        // `beginDocking` and stay free to pick either edge.
        if nearest == corner {
            if moved.x < resting.x - Self.dockOvershoot {
                return .docked(.leading, y: Self.clampedTabY(moved.y, in: bounds))
            }
            if moved.x > resting.x + Self.dockOvershoot {
                return .docked(.trailing, y: Self.clampedTabY(moved.y, in: bounds))
            }
        }
        return .floating(nearest ?? corner)
    }

    /// Forgets the gesture. Called from `dragEnded`, and from the window's
    /// `onDisappear` — SwiftUI can drop a `DragGesture` without ever ending it, and
    /// this subtree really is unmounted mid-gesture whenever the Live tab is selected
    /// or the robot stops answering. Without this the window stayed where the finger
    /// left it and its corner never decided again.
    func endDrag() {
        dragTranslation = .zero
        activation = nil
    }

    private func adjusted(_ translation: CGSize) -> CGSize {
        guard let activation else { return translation }
        return CGSize(
            width: translation.width - activation.width,
            height: translation.height - activation.height
        )
    }
}

#if DEBUG
    extension FloatingViewportModel {
        /// Parked in a placement a real gesture would have to reach. `rest` is
        /// `private(set)`, which is why this lives here rather than in `Previews/`.
        ///
        /// `settling` is the interesting one: it is the mid-morph state, and freezing
        /// it is the only static evidence a reference image can give about an
        /// animation. Pass it with the `rest` the morph is leaving, not the one it is
        /// heading for — `.floating(…)` plus `settling: .docked(…)` is a window whose
        /// geometry has reached the edge while its renderer is still mounted.
        static func preview(
            _ rest: Placement = .floating(.bottomTrailing),
            settling: Placement? = nil,
            hasTabBar: Bool = true,
            isLiveTabSelected: Bool = false,
            isEnabled: Bool = true
        ) -> FloatingViewportModel {
            // Assigned rather than switched, and read out of an inert suite: a
            // reference must render the state it was handed, and `setEnabled` both
            // writes to `UserDefaults` and moves `rest` back to a corner.
            let model = FloatingViewportModel(preferences: .preview)
            model.isEnabled = isEnabled
            model.rest = rest
            model.settling = settling
            model.hasTabBar = hasTabBar
            model.isLiveTabSelected = isLiveTabSelected
            return model
        }
    }
#endif
