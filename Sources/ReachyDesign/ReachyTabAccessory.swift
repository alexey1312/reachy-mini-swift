import SwiftUI

/// Where a strip pinned to the bottom of the window is being drawn, and who is
/// drawing the container around it.
///
/// This module's own word for it rather than `TabViewBottomAccessoryPlacement`:
/// that type only exists from iOS 26, a property wrapper cannot be conditionally
/// available, and it has no case for "there is no system slot here at all" — which
/// is the case that decides whether the strip has to back itself.
public enum ReachyAccessoryPlacement: Sendable, Hashable {
    /// No system slot: the strip is a bottom inset on a tab's content and **draws
    /// its own surface**. Below iOS 26.1 and on every macOS.
    case standalone
    /// The system's slot, a row of its own above the tab bar. The container — a
    /// capsule with its own fill, shadow and 21 pt side inset — is the system's, so
    /// the strip must draw no surface of its own. Measured on iOS 26.4: an opaque
    /// fill placed inside it renders as a second, differently rounded capsule and
    /// the two disagree visibly at the corners.
    case expanded
    /// The system's slot, merged into a minimised tab bar.
    case inline
}

/// Forces both halves onto the fallback.
///
/// It exists for the reference images. The snapshot suite runs on one iOS 26
/// simulator, so every capture would take the native branch and the fallback would
/// ship with no cover at all. A preview sets this and captures the other one.
public enum ReachyTabAccessoryStyle: Sendable, Hashable {
    case automatic
    case legacy
}

private struct ReachyAccessoryPlacementKey: EnvironmentKey {
    static let defaultValue = ReachyAccessoryPlacement.standalone
}

private struct ReachyTabAccessoryStyleKey: EnvironmentKey {
    static let defaultValue = ReachyTabAccessoryStyle.automatic
}

public extension EnvironmentValues {
    /// Spelled out rather than written with `@Entry`, like `reachyPreviewMode`:
    /// that macro ships in Xcode's SDKs and not in the pinned swift.org toolchain.
    var reachyAccessoryPlacement: ReachyAccessoryPlacement {
        get { self[ReachyAccessoryPlacementKey.self] }
        set { self[ReachyAccessoryPlacementKey.self] = newValue }
    }

    var reachyTabAccessoryStyle: ReachyTabAccessoryStyle {
        get { self[ReachyTabAccessoryStyleKey.self] }
        set { self[ReachyTabAccessoryStyleKey.self] = newValue }
    }
}

public extension View {
    /// The system's tab-view bottom accessory — the slot Apple Music holds its
    /// mini-player in. **Apply this to the `TabView`.**
    ///
    /// A no-op wherever the platform has no such slot, which is where
    /// `reachyTabAccessoryFallback` takes over. Exactly one of the two is ever
    /// live, and both read the same style to decide.
    ///
    /// **`isEnabled:` rather than a dropped modifier, and the floor is 26.1 for
    /// that reason.** Wrapping the modifier in an `if` changes the type of the view
    /// it is applied to, so SwiftUI would tear down and rebuild the whole tab
    /// subtree every time the strip appears — five `NavigationStack`s reset and the
    /// `RealityView` with them. The argument is what varies, never the modifier.
    /// The 26.0 overload takes no `isEnabled:`, and switching its *content* off is
    /// not the same thing: measured on iOS 26.4, an accessory whose content is
    /// empty still leaves a blank capsule above the tab bar and still holds 56 pt
    /// of the tab's bottom safe area. So 26.0 takes the fallback with everything
    /// below it.
    func reachyTabAccessory(
        isPresented: Bool,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        modifier(ReachyNativeTabAccessory(isPresented: isPresented, accessory: content))
    }

    /// The same strip as a bottom `safeAreaInset` **on a tab's content**, which is
    /// the one place it lands *above* the tab bar.
    ///
    /// On the `TabView` it does not: a bottom `safeAreaInset` grows the safe area of
    /// the view it is applied to, and that boundary does not cross into the tab bar
    /// or into the tabs' hosting controllers — so the strip was simply drawn over
    /// the bar. That was this app's bug for five releases; the measurement is in
    /// `RunningAppDock`.
    ///
    /// A no-op wherever `reachyTabAccessory` is live.
    func reachyTabAccessoryFallback(
        isPresented: Bool,
        @ViewBuilder content: @escaping () -> some View
    ) -> some View {
        modifier(ReachyFallbackTabAccessory(isPresented: isPresented, accessory: content))
    }
}

/// Whether the system slot is the one in play. Asked in both directions so the two
/// modifiers cannot both draw a strip.
private func usesNativeAccessory(_ style: ReachyTabAccessoryStyle) -> Bool {
    #if os(iOS)
        guard #available(iOS 26.1, *) else { return false }
        return style == .automatic
    #else
        // `tabViewBottomAccessory` is `@available(macOS, unavailable)` — not merely
        // late. So the fork is not "iOS 26 or below" but "does this platform place a
        // tab accessory", and every macOS lands with iOS 18 on the fallback.
        return false
    #endif
}

private struct ReachyNativeTabAccessory<Accessory: View>: ViewModifier {
    @Environment(\.reachyTabAccessoryStyle) private var style
    let isPresented: Bool
    let accessory: () -> Accessory

    func body(content: Content) -> some View {
        #if os(iOS)
            if #available(iOS 26.1, *), usesNativeAccessory(style) {
                content.tabViewBottomAccessory(isEnabled: isPresented) {
                    ReachyPlacedAccessory(content: accessory)
                }
            } else {
                content
            }
        #else
            content
        #endif
    }
}

private struct ReachyFallbackTabAccessory<Accessory: View>: ViewModifier {
    @Environment(\.reachyTabAccessoryStyle) private var style
    let isPresented: Bool
    let accessory: () -> Accessory

    func body(content: Content) -> some View {
        if usesNativeAccessory(style) {
            content
        } else {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if isPresented {
                        accessory()
                            // The strip takes the width it is given and asks for none.
                            // See `holdsMinimumSize` below for why that is not cosmetic.
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            // Otherwise the strip rides up on top of the keyboard
                            // whenever a search field on this tab takes focus. Being
                            // covered is the least surprising thing a pinned bar can
                            // do. The system's slot handles this itself.
                            .ignoresSafeArea(.keyboard, edges: .bottom)
                    }
                }
                .modifier(HoldsMinimumSize())
                // The appearance animates here rather than inside the strip: the
                // system animates its own slot, and two animations on one arrival
                // fight. Keyed on presence alone, so a caption changing from
                // "Starting…" to "Running" slides nothing.
                .animation(Motion.dock, value: isPresented)
        }
    }
}

/// Keeps the strip's arrival out of the tab's minimum size (#188).
///
/// **On macOS a tab's minimum size is a constraint on the window.** The tab is the
/// detail column of the sidebar's split view, and that split view sits inside the
/// inspector's. AppKit turns each column's minimum into a constraint and adds them
/// up into the window's minimum. Measured on macOS 27.0 with the sidebar at 144 pt
/// and the inspector at 380 pt: the detail column asked for at least 524 pt, and the
/// window for 904 pt, in a window 1000 pt wide. When the strip arrived, the detail
/// column asked for 707 pt, which is 524 pt plus the strip's own 183 pt. The window
/// then asked for 1087 pt.
///
/// AppKit answered by widening the window from inside a layout pass, and the pass
/// did not settle at once. Eight passes ran in 80 ms. The tab content went to 52 pt
/// high and then to 0 pt, the sidebar edge moved from 144 pt to 58 pt and back, and
/// the window grew to 1087 pt. On that Mac the passes converged. On the Mac in #188
/// they did not: AppKit raised its "more Update Constraints in Window passes than
/// there are views in the window" exception, a few seconds after Start, every time.
/// A window that cannot grow, such as a full-screen or tiled one, has no way to
/// converge at all.
///
/// So the strip may inset the tab, but it may not raise either minimum. Its width is
/// a frame with no minimum (above), and the inset tab is a frame with no minimum
/// height (here). Before the strip arrives, the tab content asks for no minimum of
/// its own, so neither frame moves anything else. With both frames the same arrival
/// left the window at 1000 pt and the column at 524 pt, in one layout pass.
///
/// No reference image can show any of this: the snapshot suite renders on an iOS
/// simulator, where a column's minimum is not a window constraint. On iOS both frames
/// propose exactly what the tab already fills, so no capture moves.
/// `ReachyTabAccessoryLayoutTests` holds the two minimums on macOS.
private struct HoldsMinimumSize: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(minHeight: 0, maxHeight: .infinity)
    }
}

#if os(iOS)
    /// Republishes the system's placement as this module's own.
    ///
    /// It exists because a property wrapper cannot be conditionally available:
    /// declaring `@Environment(\.tabViewBottomAccessoryPlacement)` on the strip
    /// itself would force `@available(iOS 26, *)` onto a type an iOS 18 target has
    /// to build. This shim carries the annotation instead, and the strip reads
    /// `\.reachyAccessoryPlacement` with no version anywhere in sight.
    ///
    /// `nil` means undefined and resolves to `.expanded`. The fallback sets no
    /// placement at all, so it resolves to the key's default, `.standalone` — the
    /// one shape that has to back itself.
    @available(iOS 26.0, *)
    private struct ReachyPlacedAccessory<Content: View>: View {
        @Environment(\.tabViewBottomAccessoryPlacement) private var placement
        let content: () -> Content

        var body: some View {
            content()
                .environment(\.reachyAccessoryPlacement, placement == .inline ? .inline : .expanded)
        }
    }
#endif
