import SwiftUI

/// What a surface is *for*. A call site names this and never a material, a glass
/// or an OS version.
public enum SurfaceRole: Sendable, CaseIterable {
    /// A floating control over video or 3D, where nothing behind it can be relied
    /// on for contrast.
    case chrome
    /// A panel of content raised off whatever is behind it.
    case card
    /// A small marker sitting on content that already carries a surface.
    case badge
    /// The backdrop behind a header, a footer or a console.
    case scrim
    /// The page's own background, drawn under something pinned to an edge of it.
    ///
    /// Opaque and nothing else — no glass, no material — and that is the whole
    /// point. A bar at the edge of a plain page has one job, to hide what passes
    /// under it, and `.scrim` does that job while also announcing itself. That is
    /// right over a log tail and wrong at the bottom of a sheet: glass renders a
    /// light surface whatever is behind it, so on a dark onboarding step the
    /// footer read as a grey strip stuck to the bottom of the screen with a button
    /// in it — reported as a bug, and it was one.
    ///
    /// Distinct from `.window`, which is also glass-free but takes a `.bar`
    /// material: a window is raised *off* whatever is behind it, and this is the
    /// thing behind it.
    case page
    /// A raised, opaque, glass-free panel: the running-app strip where it has to
    /// back itself, and the floating live view.
    ///
    /// Separate from `.scrim` because it takes no glass, and for a measured reason
    /// — though not any longer the one it was born with. The strip's shape used to
    /// reach past the safe area, and glass over an edge with nothing behind it
    /// renders in the iOS 26 simulator as a black-red-green smear; the same glass
    /// over the viewport's chrome, which stays inside the screen, renders cleanly.
    /// The strip sits above the tab bar now and crosses no edge, so that is history
    /// rather than a live constraint. **Keep the role glass-free anyway**: it is the
    /// only surface that flips correctly in a dark reference, which is what
    /// `FloatingViewport` picked it for, and nothing should show through a window.
    case window
}

/// A role's surface as a view you place yourself.
///
/// Its root is the shape, not a `Color`: a `Color` is flexible in both axes, and
/// one carrying `ignoresSafeArea` expands to the whole safe-area container rather
/// than to the thing it is backing. Mounted under a `safeAreaInset` — which draws
/// over the content — that painted the entire screen in the window colour. Two
/// reference images caught it as blank captures.
public struct ReachySurfaceFill<S: Shape>: View {
    private let role: SurfaceRole
    private let shape: S

    public init(_ role: SurfaceRole, in shape: S) {
        self.role = role
        self.shape = shape
    }

    public var body: some View {
        effect
    }

    private var base: some View {
        shape.fill(role.baseFill)
    }

    /// **The effect goes under the content, never around it.**
    ///
    /// `glassEffect` renders what it *wraps* vibrantly, and that comes out in a
    /// reference image: measured on the iOS 26 simulator, red, orange, green and
    /// secondary text inside one all render black, and `.tint` is the only style
    /// that survives. Wrapping would therefore have cost the dock its red crash
    /// line and the BLE console its orange warning — two places where the colour
    /// *is* the message. Every ad-hoc site this replaces already put its material
    /// in a `.background`, so backing it is also what keeps them unchanged.
    ///
    /// The glass wraps the opaque fill, not empty space. Laid over a `Color.clear`
    /// instead it has no backdrop to refract and the iOS 26 simulator renders it as
    /// a black-red-green smear — which is what the dock's reference image caught.
    ///
    /// `.glassEffect` is multiplatform, so there is no `#if os(…)` and macOS 26
    /// gets real glass — which an iOS-only backport never could.
    @ViewBuilder
    private var effect: some View {
        if #available(iOS 26.0, macOS 26.0, *), let glass = role.glass {
            base.glassEffect(glass, in: shape)
        } else if let material = role.material {
            base.overlay { shape.fill(material) }
        } else {
            base
        }
    }
}

public extension View {
    /// Backs this view with a role's surface: real glass from iOS 26 / macOS 26,
    /// a material below, over an opaque fill.
    ///
    /// The opaque `baseFill` under the effect is what keeps the snapshot suite
    /// meaningful. Neither glass nor a material renders headless — the dock records
    /// the same about `.bar` — so without a fill that does render, every surface in
    /// the app would be invisible to the reference images, and the layout and text
    /// on each card would quietly lose their regression cover.
    func reachySurface(_ role: SurfaceRole, in shape: some Shape = .rect) -> some View {
        background { ReachySurfaceFill(role, in: shape) }
    }

    /// A surface that paints the inset beside it as well.
    ///
    /// `background(_:)` taking a `ShapeStyle` defaults to `ignoresSafeAreaEdges:
    /// .all`, and every bar this replaces relied on that without saying so: a strip
    /// mounted as a `safeAreaInset` has to run to the edge of the screen, or the
    /// home indicator sits on a stripe of window colour. `reachySurface` uses the
    /// `ViewBuilder` form of `background`, which stops at the safe area — so the
    /// bars that need the old behaviour ask for it by name.
    func reachySurface(
        _ role: SurfaceRole,
        in shape: some Shape = .rect,
        ignoringSafeArea edges: Edge.Set
    ) -> some View {
        background {
            ReachySurfaceFill(role, in: shape)
                .ignoresSafeArea(edges: edges)
        }
    }

    /// The `.scrim` spelling of the above — what the two consoles ask for, and the
    /// name three call sites already used.
    func reachyScrim(ignoringSafeArea edges: Edge.Set = .all) -> some View {
        reachySurface(.scrim, ignoringSafeArea: edges)
    }
}

extension SurfaceRole {
    var material: Material? {
        switch self {
        case .chrome, .card: .regular
        case .scrim, .window: .bar
        case .badge, .page: nil
        }
    }

    /// A badge takes no effect at all: it sits inside a card and floats over
    /// nothing, so there is nothing behind it for glass to refract or a material
    /// to blur. Its fill alone is the surface. A page is the same claim from the
    /// other side: it *is* the backdrop, so there is nothing behind it either.
    @available(iOS 26.0, macOS 26.0, *)
    var glass: Glass? {
        switch self {
        // Only the chrome is touched. The rest are backdrops, and interactive
        // glass on one would react to every scroll passing under it.
        case .chrome: .regular.interactive()
        case .card, .scrim: .regular
        case .badge, .window, .page: nil
        }
    }

    /// A badge takes a fill rather than the window colour: it sits *on* a card,
    /// and `.background` there would punch a hole straight through to the screen.
    var baseFill: AnyShapeStyle {
        switch self {
        case .chrome, .card, .scrim, .window, .page: AnyShapeStyle(.background)
        case .badge: AnyShapeStyle(.fill.quaternary)
        }
    }
}
