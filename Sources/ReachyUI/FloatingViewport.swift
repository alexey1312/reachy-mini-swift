import ReachyDesign
import ReachyKit
import SwiftUI

/// The live view of the robot, floating over whatever tab is showing — and the
/// tab at the edge it leaves behind when it is switched off.
///
/// It draws `ViewportContent` and brings its own compact chrome: two icons rather
/// than the Live tab's segmented picker, which is up to 240 pt wide and does not
/// fit here.
///
/// **Nothing inside the window is interactive** — not the joystick (`makeTeleop` is
/// absent) and not the orbit camera (hit-testing is off on the content). The window
/// is one object that can be moved, put away and opened; the robot is driven from
/// the tab. That is a product decision and, since the scene's own gesture would
/// otherwise swallow every touch, also what makes the window work at all.
///
/// **The window and the tab are one view, not two branches.** They used to be a
/// `switch` returning structurally different views, which gave them different SwiftUI
/// identities — and nothing geometric interpolates across an identity boundary, so
/// `withAnimation` had only the default opacity transition left to run and the morph
/// was a 0.28 s crossfade between two differently sized things in two places. One
/// identity animates its frame, its position and its corners instead. The renderer
/// keeps its own fixed size inside and is clipped, so none of that re-lays it out.
///
/// `matchedGeometryEffect` would be the obvious way to do this and is exactly what
/// cannot be used: it keeps source and destination alive at the same time, and a
/// second `RealityView` takes the robot away from the first.
struct FloatingViewport: View {
    let model: FloatingViewportModel
    let viewport: ViewportModel
    let session: RobotSession
    /// The rectangle the window may occupy, already inset by the safe area — the
    /// tab bar and the running-app dock both live in that inset, and the window
    /// must not land on either.
    let bounds: CGRect
    /// Selects the Live tab. Called after the window has finished growing, never
    /// before: the tab and the window cannot both hold the viewport.
    let open: () -> Void

    @Environment(\.reachyPreviewMode) private var previewMode

    var body: some View {
        if model.isInline {
            EmptyView()
        } else {
            chrome
        }
    }

    /// The frame is animated by `isExpanding` and the content is handed over only
    /// once that animation reports itself done — the same shape as the dock below it,
    /// and for the same reason.
    private var chrome: some View {
        let shape = Radius.flush(to: model.drawnEdge, Radius.lg)
        return ZStack {
            picture
            edgeGlyphs
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .reachySurface(.window, in: shape)
        // **The chrome goes outside the clip**, which is where it has always been. Moved
        // inside it once, and the references named the mistake exactly: a capsule inset
        // by `Space.xs` meets a 16 pt continuous corner, so the corner shaved it. The
        // three floating captures carrying a switcher or a badge all moved and
        // `Floating viewport — no camera`, which carries neither, did not.
        .overlay(alignment: .topLeading) { windowOnly { switcher } }
        .overlay(alignment: .bottomTrailing) { windowOnly { reconnectingBadge } }
        .shadow(color: .black.opacity(0.2), radius: isDocked ? 8 : 12, y: isDocked ? 0 : 4)
        .contentShape(.rect)
        // A non-zero minimum distance is what leaves the tap intact: at 0 the drag
        // claims every touch, and tapping is how the window is both opened and
        // brought back.
        .gesture(drag)
        .onTapGesture(perform: tapped)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isDocked ? .reachy("Live view, hidden") : .reachy("Live view"))
        .accessibilityAddTraits(.isButton)
        .accessibilityActions { actions }
        // SwiftUI can drop a `DragGesture` without ever ending it, and this subtree
        // really is unmounted mid-gesture — selecting the Live tab or losing the robot
        // both do it. Without this the window stayed wherever the finger left it.
        //
        // `finishSettling` is owed by an animation's completion handler, and an
        // animation on a subtree that is already gone may never report one. Every way
        // into the model guards on `settling == nil`, so a completion that never
        // arrived would leave the window unable to move again — and `isStreaming` true
        // over one the reader had put away.
        //
        // **Not in a preview, and the reference images are why.** A frozen `settling` is
        // the only static evidence there is about the morph, and Prefire captures one
        // preview body once per device and appearance off a single model — so adopting
        // it here rendered the mid-morph state in the first capture and the placement it
        // settled into in the other three. Measured: `Floating viewport — undocking` came
        // back with a switcher and a spinner in three of its four references.
        .onDisappear {
            model.endDrag()
            if !previewMode {
                model.finishSettling()
            }
        }
        .modifier(DragOffset(model: model, bounds: bounds))
        // `.position` comes last and carries only the *resting* point, never the live
        // gesture: it is a layout modifier, so driving it from every touch event ran a
        // layout pass over a subtree hosting a rendering `RealityView`. The finger goes
        // through `DragOffset` instead, which is a render-time transform and the shape
        // `JoystickPad` already uses.
        .position(centre)
    }

    /// The expansion is these two and `pictureSize` together, and they only make sense
    /// read as one: a frame growing to the screen while the centre stays on a corner
    /// anchor leaves most of the window off it.
    private var size: CGSize {
        model.isExpanding ? bounds.size : model.drawnSize
    }

    private var centre: CGPoint {
        model.isExpanding ? CGPoint(x: bounds.midX, y: bounds.midY) : model.centre(in: bounds)
    }

    private var isDocked: Bool {
        model.drawnEdge != nil
    }

    // MARK: - What is inside

    /// The renderer, at a size of its own rather than the container's — see `pictureSize`.
    ///
    /// **Mounted on `placement`, faded on `drawn`** — that gap is the two-phase dock.
    /// While the window is animating into its edge `placement` is still `.floating`, so
    /// this stays mounted and fades out; it is `finishSettling()` that unmounts it and
    /// stops the stream, after the animation rather than on its first frame.
    @ViewBuilder
    private var picture: some View {
        if case .floating = model.placement {
            ViewportContent(model: viewport)
                // **The window's content is a picture, not a control.** `RobotSceneView`
                // hangs a `DragGesture(minimumDistance: 0)` off the `RealityView` for
                // the orbit camera, and in SwiftUI a descendant's gesture beats an
                // ancestor's `.gesture(_:)` — so every touch on the 3D pane went to the
                // camera and the window could be neither moved nor opened. The camera
                // pane had no such gesture and worked, which is what made the bug look
                // 3D-only.
                //
                // Suppressed rather than out-prioritised with `highPriorityGesture`:
                // orbiting a 160 pt viewport is the same call as the absent `makeTeleop`
                // above, and both belong to full screen. The chrome is added *after*
                // this and stays live.
                .allowsHitTesting(false)
                .frame(width: pictureSize.width, height: pictureSize.height)
                .opacity(isDocked ? 0 : 1)
                // Scoped to the opacity so the geometry keeps its spring: the picture
                // leaves in roughly the first third, and what gets squashed into the
                // edge is an empty surface rather than a shrinking 3D scene.
                .animation(Motion.absorbContent, value: isDocked)
        }
    }

    /// Fixed while the window morphs into its edge: the container's frame shrinks to the
    /// tab's, and a child that took that proposal would re-lay-out the `RealityView` on
    /// every frame of the morph. This ignores it and is clipped instead.
    ///
    /// It does follow the expansion, where there is no morph and no clip to hide behind —
    /// the window is growing into the Live tab and the picture has to arrive at the size
    /// the tab will hand back.
    private var pictureSize: CGSize {
        model.isExpanding ? bounds.size : Metrics.floatingViewport
    }

    /// Something that belongs to the window rather than to the tab: mounted and faded
    /// exactly as the picture is, because there is no room for a control on a 44 pt tab
    /// and no reason to draw one over the glyphs on the way there.
    @ViewBuilder
    private func windowOnly(@ViewBuilder _ content: () -> some View) -> some View {
        if case .floating = model.placement {
            content()
                .opacity(isDocked ? 0 : 1)
                .animation(Motion.absorbContent, value: isDocked)
        }
    }

    /// What the tab at the edge shows instead: the mode it will come back in, and a dot
    /// for the link. Always mounted — two glyphs cost nothing — and faded by `drawn`,
    /// so they arrive as the picture leaves.
    private var edgeGlyphs: some View {
        VStack(spacing: Space.xs) {
            Image(systemName: viewport.content.systemImage)
                .font(Typography.detail)
                .foregroundStyle(Tone.quiet.style)
            Circle()
                .fill(linkTone.style)
                .frame(width: Space.sm, height: Space.sm)
        }
        .opacity(isDocked ? 1 : 0)
        .animation(Motion.absorbContent, value: isDocked)
    }

    // MARK: - Gestures

    private var drag: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .floatingViewportBounds)
            .onChanged { model.dragChanged(translation: $0.translation) }
            .onEnded(release)
    }

    /// The throw. `predictedEndTranslation` is what decides where the window lands, so a
    /// flick reaches an edge a carry of the same length does not, and `velocity` is what
    /// seeds the spring so it continues the gesture instead of restarting from a
    /// standstill.
    ///
    /// A spring's initial velocity is a fraction of the journey per second, which is why
    /// the model is asked how long the journey is rather than the distance being guessed
    /// from the gesture.
    private func release(_ value: DragGesture.Value) {
        let carried = FloatingViewportModel.DragRelease(
            predictedEndTranslation: value.predictedEndTranslation
        )
        let distance = model.releaseDistance(for: carried, in: bounds)
        let speed = hypot(value.velocity.width, value.velocity.height)
        withAnimation(Motion.absorb(velocity: speed / max(distance, 1))) {
            model.dragEnded(carried, in: bounds)
        } completion: {
            model.finishSettling()
        }
    }

    private func tapped() {
        if isDocked {
            undock()
        } else {
            openFullScreen()
        }
    }

    private func openFullScreen() {
        withAnimation(Motion.dock) {
            model.beginExpanding()
        } completion: {
            model.endExpanding()
            open()
        }
    }

    private func dock(_ edge: HorizontalEdge) {
        withAnimation(Motion.absorb(velocity: 0)) {
            model.beginDocking(edge, in: bounds)
        } completion: {
            model.finishSettling()
        }
    }

    private func undock() {
        withAnimation(Motion.absorb(velocity: 0)) {
            model.beginUndocking(in: bounds)
        } completion: {
            model.finishSettling()
        }
    }

    // MARK: - Chrome

    /// Two icons and no labels: at 160 pt there is room for the state, not for the
    /// word naming it. The Live tab keeps the picker, which is what a reader who
    /// wants to be told rather than shown is one tap away from.
    @ViewBuilder
    private var switcher: some View {
        if options.count > 1 {
            HStack(spacing: Space.xxs) {
                ForEach(options) { option in
                    Button {
                        viewport.setContent(option)
                    } label: {
                        Image(systemName: option.systemImage)
                            .font(Typography.status)
                            .foregroundStyle(option == viewport.content ? Tone.brand.style : Tone.quiet.style)
                            .frame(width: 24, height: 20)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Space.xxs)
            .reachySurface(.chrome, in: .capsule)
            .padding(Space.xs)
        }
    }

    @ViewBuilder
    private var reconnectingBadge: some View {
        if isUnreachable {
            Image(systemName: "wifi.exclamationmark")
                .font(Typography.status)
                .foregroundStyle(Tone.warning.style)
                .padding(Space.xxs)
                .reachySurface(.chrome, in: .circle)
                .padding(Space.xs)
                .accessibilityLabel(.reachy("Unreachable — reconnecting…"))
        }
    }

    /// The window is one accessibility element — a 24 pt glyph inside a 160 pt
    /// window is not something VoiceOver can aim at — so everything it can do is
    /// offered as a named action instead. Without them the window could neither be
    /// opened nor put away, and it covers content.
    @ViewBuilder
    private var actions: some View {
        if isDocked {
            Button(.reachy("Show the live view"), action: undock)
        } else {
            Button(.reachy("Open full screen"), action: openFullScreen)
            ForEach(options) { option in
                Button(option.title) { viewport.setContent(option) }
            }
            Button(.reachy("Hide at the leading edge")) { dock(.leading) }
            Button(.reachy("Hide at the trailing edge")) { dock(.trailing) }
        }
    }

    private var options: [ViewportModel.Content] {
        ViewportOptions.offered(by: viewport, offersCamera: session.hasCamera)
    }

    private var isUnreachable: Bool {
        if case .unreachable = session.phase {
            true
        } else {
            false
        }
    }

    private var linkTone: StatusTone {
        switch session.phase {
        case .connected: .active
        case .unreachable: .failed
        case .idle, .connecting: .idle
        }
    }
}

/// The one thing that reads the live gesture, and a modifier of its own so that nothing
/// else does.
///
/// `@Observable` tracks reads per property, so keeping `dragTranslation` out of
/// `FloatingViewport.body` is what stops the surface, the chrome and the renderer from
/// being rebuilt on every touch event — they are built once per drag instead. Only this
/// node re-evaluates, and all it does is move a transform.
private struct DragOffset: ViewModifier {
    let model: FloatingViewportModel
    let bounds: CGRect

    func body(content: Content) -> some View {
        content.offset(model.dragOffset(in: bounds))
    }
}
