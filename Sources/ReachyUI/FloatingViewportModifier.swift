import ReachyDesign
import ReachyKit
import SwiftUI

extension View {
    /// Floats the live view over the whole interface, wherever the shell draws a
    /// tab bar.
    ///
    /// **Apply this to the `TabView`.** Order against `reachyTabAccessory` no longer
    /// matters — it used to, back when the dock was a bottom `safeAreaInset` this
    /// overlay could read, and the note here said so. The strip is system chrome
    /// now, invisible to this reader like the tab bar, so `FloatingViewportModel`
    /// is told it is there instead.
    ///
    /// It is mounted in the shell rather than in the root so it dies with the
    /// connection. `.unreachable` stays in the shell, which is why a network blip
    /// leaves the window where it is instead of taking it away.
    func floatingViewport(
        model: FloatingViewportModel,
        viewport: ViewportModel,
        session: RobotSession,
        open: @escaping () -> Void
    ) -> some View {
        modifier(FloatingViewportModifier(model: model, viewport: viewport, session: session, open: open))
    }
}

private struct FloatingViewportModifier: ViewModifier {
    let model: FloatingViewportModel
    let viewport: ViewportModel
    let session: RobotSession
    let open: () -> Void

    #if !os(macOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// **The one size-class branch in this target, and it is deliberate.** The rule
    /// is not "iPhone" but "wherever the shell draws a tab bar rather than a
    /// sidebar": a sidebar layout has the Live tab permanently beside the others
    /// and nothing to float. `ReachyUI/AGENTS.md` carries the same note, because
    /// the entry there used to say no branch was left.
    private var hasTabBar: Bool {
        #if os(macOS)
            false
        #else
            horizontalSizeClass == .compact
        #endif
    }

    /// Asked of the model rather than of `RootViewportTarget`: the window renders
    /// what the model holds, and before it has attached there is nothing to float.
    /// The Live tab asks the other question because it has to say *why* there is no
    /// live view, which the model cannot tell it.
    private var hasSomethingToShow: Bool {
        viewport.source != nil && session.isAwake
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geometry in
                    let bounds = available(in: geometry)
                    // `isWindowed`, never `!isInline`: a column is not inline either,
                    // and asking the old question here would draw the window over it.
                    if hasSomethingToShow, model.isWindowed {
                        FloatingViewport(
                            model: model,
                            viewport: viewport,
                            session: session,
                            bounds: bounds,
                            bleed: dockBleed(in: geometry),
                            open: open
                        )
                        .onChange(of: bounds) { _, new in model.fit(to: new) }
                    }
                }
                .coordinateSpace(.floatingViewportBounds)
            }
            .onChange(of: hasTabBar, initial: true) { _, value in
                model.hasTabBar = value
            }
    }

    /// The region the window may rest in: this reader's own, less the chrome it
    /// cannot see.
    ///
    /// **The safe area is not subtracted here, and that is the correction.** A
    /// `GeometryReader` is laid out *inside* the safe area, so `size` has already
    /// lost it and the origin of this reader's coordinate space — the space
    /// `.position` places the window in — is already the top-left of the inset
    /// region. Subtracting `safeAreaInsets` as well counted it twice at both ends.
    /// Measured on an iPhone 17 Pro running iOS 26.4: the reader is 402 × 778 and
    /// reports t62 b34, of a 402 × 874 screen. Reaching for `ignoresSafeArea()` on
    /// the reader does not fix it either — that yields the full 402 × 874 but
    /// reports t0 b0, so there would be nothing left to subtract.
    ///
    /// What does have to be subtracted is the chrome the reader is *not* inset by:
    /// the tab bar insets each tab's content and reports none of it out here, and
    /// the accessory the running-app strip sits in does the same, which is why the
    /// shell writes `hasBottomAccessory` rather than leaving it to be measured.
    ///
    /// It can change with a finger down — the strip arrives on a poll — which is why
    /// nothing about this rectangle is captured when a gesture begins.
    private func available(in geometry: GeometryProxy) -> CGRect {
        let accessory = model.hasBottomAccessory ? Metrics.tabAccessoryAllowance : 0
        return CGRect(
            x: 0,
            y: 0,
            width: geometry.size.width,
            height: max(0, geometry.size.height - Metrics.tabBarAllowance - accessory)
        )
    }

    /// How far the docked tab may reach back out of the safe area, and **at which one
    /// end**.
    ///
    /// The gap it closes is the one `available(in:)` deliberately leaves: the reader is
    /// laid out inside the safe area, so in landscape `bounds` stops 62 pt short of the
    /// glass and a 44 pt tab hung there with a strip of screen behind it — reported as
    /// a window that had not finished docking.
    ///
    /// **Only one end, and the orientation is the one thing that says which.** iOS
    /// reports that inset on *both* sides in landscape however the phone is held, so
    /// filling both in would push the tab under the Dynamic Island on whichever side
    /// carries it: the island sits x ∈ [17, 50] from the edge, which is 27 pt of a 44 pt
    /// tab, and a cutout has no pixels and takes no touches. The bleed therefore goes to
    /// the phone's *bottom* edge — the one end of a landscape screen with nothing cut
    /// out of it.
    ///
    /// **`UIInterfaceOrientation`'s two landscape cases are the device's, swapped, and
    /// getting them the wrong way round is invisible.** The enum is literally defined as
    /// `.landscapeLeft = UIDeviceOrientationLandscapeRight`, and the "home button on the
    /// right side" sentence in Apple's documentation belongs to `UIDeviceOrientation` —
    /// applied to this one it yields the mirror image. So `.landscapeLeft` holds the
    /// home indicator at the screen's **leading** end and `.landscapeRight` at its
    /// trailing one. The two orientations are mirrors of each other, which is exactly
    /// what makes the mistake unfalsifiable by inspection: an inverted mapping is wrong
    /// in both and looks plausible in both, and the geometry tests cannot see it at all
    /// because `bleed` reaches `tabCentre` as a number that has already been decided.
    /// It was measured instead — a standalone probe on a booted simulator, forced into
    /// each orientation through `UISupportedInterfaceOrientations` and screenshotted.
    ///
    /// Portrait needs no case: there is no horizontal inset there to give back.
    ///
    /// **This is the target's second branch on how the device is held**, after
    /// `hasTabBar`, and `AGENTS.md` carries why neither is a layout fork. It asks where
    /// the screen's physical edge is, and moves one point to meet it.
    private func dockBleed(in geometry: GeometryProxy) -> FloatingViewportModel.EdgeBleed {
        #if os(macOS)
            .none
        #else
            switch interfaceOrientation {
            case .landscapeLeft: .init(leading: geometry.safeAreaInsets.leading)
            case .landscapeRight: .init(trailing: geometry.safeAreaInsets.trailing)
            default: .none
            }
        #endif
    }

    #if !os(macOS)
        /// Re-read rather than observed: this is only ever called from inside the
        /// overlay's `GeometryReader`, and a rotation changes that reader's size — so
        /// the closure runs again with the orientation already settled, and there is no
        /// notification to subscribe to and unsubscribe from.
        ///
        /// **Any window scene, deliberately not the `foregroundActive` one.**
        /// `WebAuthenticationBrowser` filters on that and is right to — it is choosing a
        /// window to present in. Here the filter is a silent failure: measured on an
        /// iPhone 17 Pro with a landscape layout already laid out (reader 750 × 382,
        /// l62 r62), `connectedScenes` held one scene reporting `.landscapeLeft`, and
        /// `activationState` was not yet `foregroundActive` — so the filter returned nil,
        /// the fallback said portrait, and the bleed came out zero with nothing to
        /// re-run the body once the scene did activate. There is one scene here; asking
        /// it what orientation it is drawing at needs no liveness test.
        private var interfaceOrientation: UIInterfaceOrientation {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?
                .interfaceOrientation ?? .portrait
        }
    #endif
}

extension CoordinateSpaceProtocol where Self == NamedCoordinateSpace {
    /// The overlay's own space: the one rectangle that does not move while the window
    /// is dragged. The drag gesture rides *inside* the subtree `DragOffset` displaces,
    /// so measuring it `.local` fed the drawn offset back into the translation one
    /// frame late — the window vibrated at frame rate and tracked at half the finger's
    /// speed. This is also the space `bounds` and `.position` already live in.
    static var floatingViewportBounds: NamedCoordinateSpace {
        .named("FloatingViewport.bounds")
    }
}
