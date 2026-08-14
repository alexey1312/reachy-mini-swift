import ReachyDesign
import ReachyKit
import SwiftUI

/// Opens a teleop stream on demand — a WebSocket on the LAN, the session's own
/// data channel over the relay.
///
/// `@Sendable` because a `View` is, and this is stored on two of them; `@MainActor`
/// because the session it closes over is.
typealias TeleopFactory = @MainActor @Sendable () throws -> any TeleopChannel

/// What a joystick calls to take the head off the robot's own two behaviours before
/// driving it. Built by `PresenceModel.teleopStandDown(session:)` and cheap enough to
/// call on every touch event; `nil` where there is no robot session to ask.
typealias TeleopStandDown = @MainActor @Sendable () -> Void

/// The Live tab's host for the viewport: `ViewportContent` under the full-size
/// chrome.
///
/// It is one of two hosts, never both at once. `RobotSceneView` hands the scene's
/// root entity to `RealityView`, and an entity has exactly one parent, so a second
/// mounted viewport would silently steal the robot from the first.
/// `FloatingViewportModel.placement` is what makes "one at a time" structural: this
/// view is drawn only at `.inline`, and `FloatingViewport` only at everything else.
struct ViewportView: View {
    let model: ViewportModel
    /// The robot reports no camera at all on a wired unit — then there is nothing
    /// to switch between and the control is hidden rather than disabled.
    let offersCamera: Bool
    /// `nil` where this connection carries no teleop at all, and then the joystick
    /// is absent rather than inert.
    var makeTeleop: TeleopFactory?
    /// The robot behind the picture, for the controls that are about *it* rather
    /// than about the stream. `nil` in the floating window, which is a place to
    /// watch from rather than to configure.
    var robotSession: RobotSession?
    /// Owned by `LiveTab` rather than by this view, and passed in for two reasons.
    /// SwiftUI re-runs a sheet's content closure on every update of the view it hangs
    /// off, so a model built there is silently replaced by an empty one — and these two
    /// flags are the only record of what the robot was asked for. Held one level up
    /// because this view is *conditional*: a sleeping robot and the floating window both
    /// unmount it, and a `@State` model would forget the robot's behaviours across
    /// either. `ControllerScreen` reads the same instance, which is what stops its
    /// joystick from turning a behaviour off behind a switch still showing it on.
    let presence: PresenceModel
    /// Puts the viewport away, where there is somewhere for it to go. `nil` on the Live
    /// tab, which is where it would go — a control that closes the thing you are
    /// looking at *into* the thing you are looking at does nothing.
    ///
    /// It exists because the column had no visible way out: the switch is a toolbar
    /// menu on the Live tab, which is a different destination from the one the column
    /// is beside. That is the same complaint the floating window's menu answered, in a
    /// second place — and the answer is the same shape, a control on the object itself.
    var dismiss: (() -> Void)?

    @State private var showsPresence = false

    var body: some View {
        ViewportContent(model: model, makeTeleop: makeTeleop, standDown: standDown)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) { chrome }
            .overlay(alignment: .bottomLeading) { hearing }
            .sheet(isPresented: $showsPresence) {
                if let robotSession {
                    NavigationStack {
                        TelepresenceSheet(
                            session: robotSession,
                            dismiss: { showsPresence = false },
                            presence: presence
                        )
                    }
                    .reachySheet()
                }
            }
    }

    /// Absent without a robot session — the relay carries no media routes, so there is
    /// nothing on that side to stand down.
    private var standDown: TeleopStandDown? {
        guard let robotSession else { return nil }
        return presence.teleopStandDown(session: robotSession)
    }

    /// Every floating control hugs the leading edge: on iPad the tab bar floats
    /// over the top centre, and anything trailing-aligned ends up underneath it.
    ///
    /// **No `ReachySurfaceGroup` here, and it is not an oversight.** A
    /// `GlassEffectContainer` only sees a `glassEffect` applied to its own
    /// subviews; one nested inside a `.background` — which is where every
    /// `SurfaceRole` puts it — gets hoisted into the container's merged sheet and
    /// composited *over* the content instead of under it. On device that blurred
    /// the switcher's labels and this button's glyph into illegibility, and the
    /// snapshot suite cannot see it because glass does not render headless.
    /// `ReachyDesign/AGENTS.md` carries the measurement.
    private var chrome: some View {
        HStack(spacing: Space.md) {
            switcher
            contentControls
            presenceButton
            dismissButton
        }
        .padding(Space.md)
    }

    /// Last in the row, after the controls that are about the picture: this one is
    /// about the picture's *place*, and it is the only control here that makes
    /// something disappear.
    @ViewBuilder
    private var dismissButton: some View {
        if let dismiss {
            Button(action: dismiss) {
                Label(.reachy("Close"), systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(ViewportControlButtonStyle())
        }
    }

    /// **The bottom, because this row is a reading and the top row is controls.** It
    /// started beside them and could not fit: the caption is a sentence rather than a
    /// glyph — deliberately, since the robot's left is on opposite sides of the
    /// screen in the two viewports and only a word is unambiguous — so on a phone it
    /// wrapped to two lines and took a third of the chrome row with it.
    ///
    /// Leading rather than trailing: `CameraViewport` puts the joystick and the
    /// recentre button in `bottomTrailing`, and this is the one corner nothing else
    /// claims in either viewport. Outside `contentControls` for the reason it always
    /// was — the reading is the same fact whichever engine is up, and
    /// `ViewportModel.hearing` outlives the switch between them.
    @ViewBuilder
    private var hearing: some View {
        if let hearing = model.hearing {
            DirectionOfArrivalIndicator(model: hearing)
                .padding(Space.md)
        }
    }

    /// Speaker, microphone and the robot's own idle behaviour, without leaving the
    /// stream — which is the whole point: every one of them is something a reader
    /// wants *while* looking through the camera, and the Settings tab is a place
    /// you have to give the picture up to reach.
    @ViewBuilder
    private var presenceButton: some View {
        if robotSession != nil {
            Button {
                showsPresence = true
            } label: {
                Label(.reachy("Presence"), systemImage: "slider.horizontal.3")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(ViewportControlButtonStyle())
        }
    }

    @ViewBuilder
    private var contentControls: some View {
        switch model.content {
        case .scene:
            if let sceneModel = model.sceneModel {
                SceneOptionsMenu(model: sceneModel)
            }
        case .camera:
            if let session = model.cameraSession {
                CameraMicButton(session: session)
            }
        }
    }

    /// What there is to switch between. Over the relay the 3D model does not
    /// exist, so there is one option and the control disappears rather than
    /// offering a dead segment.
    private var options: [ViewportModel.Content] {
        ViewportOptions.offered(by: model, offersCamera: offersCamera)
    }

    @ViewBuilder
    private var switcher: some View {
        if options.count > 1 {
            Picker(.reachy("Viewport"), selection: Binding(
                get: { model.content },
                set: { model.setContent($0) }
            )) {
                ForEach(options) { content in
                    Label(content.title, systemImage: content.systemImage).tag(content)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // **The cap is iOS-only, because only iOS stretches the segments.**
            // A macOS segmented control keeps its natural width whatever it is
            // offered and centres itself in the surplus — measured by rendering it
            // in a 300 pt container and reading the bounding box: 158 pt spanning
            // x 71…228, unchanged by a `maxWidth: .infinity` inside the cap. So the
            // 240 left ~82 pt of empty capsule around it. Dropping it here lets the
            // capsule hug the control instead; on iOS the segments do fill, so the
            // cap is what stops the switcher spanning an iPad.
            #if !os(macOS)
                .frame(maxWidth: 240)
            #endif
                // A segmented control's track is translucent, so on the camera's black
                // backdrop the unselected segment had no contrast left and read as missing
                // (seen in dark mode). It now carries its own backing like every other
                // floating control here — which is the rule stated at the bottom of this
                // file, and the reason it holds regardless of theme or what is behind it.
                //
                // 3 pt is optical, not rhythm: it is what stops the segmented track from
                // touching the backing around it.
                .padding(3)
            // **On macOS the backing is concentric with the control, not a capsule.**
            // A capsule was the third instance of the same mistake the round controls
            // made — drawing a shape the thing inside does not have. Rendered on a
            // keyed background and traced by pixel, an AppKit segmented control comes
            // out **157 × 24 pt with a ~4 pt corner** (its left inset decays 7,5,4,3,
            // 2,1,1,0 half-pixels), where a capsule at that height would be 12. So the
            // capsule curved away from the segment inside it and left a crescent at
            // each end — visible as a mismatch, and clickable where nothing was drawn.
            // Concentric means the control's radius plus the 3 pt inset ≈ 7;
            // `Radius.xs` is the token nearest it.
            //
            // iOS keeps the capsule: its segments fill and round differently, nobody
            // has reported it, and changing it would move every `Viewport —` and
            // `Root — live tab` reference with no run here to re-record them.
            #if os(macOS)
                .reachySurface(.chrome, in: Radius.rect(Radius.xs))
                .contentShape(Radius.rect(Radius.xs))
            #else
                .reachySurface(.chrome, in: .capsule)
                .contentShape(.capsule)
            #endif
        }
    }
}

/// Shared chrome so the scene and the camera report progress the same way.
enum ViewportStatus {
    /// `@MainActor` because it builds a surface, and `ViewModifier` carries that
    /// isolation in Swift 6.
    @MainActor
    static func loading(_ title: String, progress: Double?) -> some View {
        VStack(spacing: Space.md) {
            if let progress {
                ProgressView(value: progress)
                    .frame(maxWidth: 220)
            } else {
                ProgressView()
            }
            Text(title)
                .font(Typography.detail)
                .foregroundStyle(Tone.quiet.style)
        }
        .padding(20)
        // `Radius.rect` is `.continuous`; this shape used to default to `.circular`,
        // so the reference image moves here. That is the correction, not a
        // regression — `ReachyDesign/AGENTS.md` records it as expected.
        .reachySurface(.chrome, in: Radius.rect(Radius.md))
    }
}

extension View {
    /// Floating controls sit on top of video and 3D alike, so they carry their own
    /// backing rather than relying on whatever is behind them for contrast.
    ///
    /// `@MainActor` because `reachySurface` is: a `ViewModifier`'s initialiser
    /// carries that isolation in Swift 6, and a nonisolated helper cannot return
    /// what it builds.
    ///
    /// **The name is the rule: this goes on a label, never around a `Button`.** A
    /// button's appearance *and* its click target both belong to the button, so
    /// applied outside one it sets neither — it drew the disc in the right place
    /// while macOS drew the button's own rectangle around the glyph inside it, and
    /// only that rectangle answered a click. A `Button` takes
    /// `ViewportControlButtonStyle`; a `Menu` puts this on its label.
    @MainActor
    func viewportControlLabelStyle() -> some View {
        modifier(ViewportControlStyle())
    }

    /// A `Menu` wearing the same disc as the buttons beside it — **the default menu
    /// style plus `.buttonStyle(.plain)`, with the disc on the label.**
    ///
    /// The other two spellings were measured in a real window, painting a
    /// background straight onto each menu so the rectangle drawn *is* the control
    /// and therefore the click target:
    ///
    /// | menu style                  | control          |
    /// | --------------------------- | ---------------- |
    /// | `.borderlessButton`         | label's own layout discarded — the disc vanished |
    /// | `.button`                   | **39 × 17** — its own metrics, not the label's    |
    /// | default + `.buttonStyle(.plain)` | **36 × 36** — exactly the label's frame       |
    ///
    /// So `.button` plus `ViewportControlButtonStyle` — the obvious "same as the
    /// buttons" — cannot reproduce them: it imposes its own size, which is why that
    /// build came out visibly smaller and flatter. Only the last row honours the
    /// label, and honouring the label is what makes the whole disc clickable rather
    /// than just the glyph.
    @MainActor
    func viewportControlMenuStyle() -> some View {
        menuIndicator(.hidden)
            .buttonStyle(.plain)
    }
}

/// What a `Button` in the viewport's chrome takes.
///
/// A `ButtonStyle`'s body *is* the button, so the disc it draws is also the area
/// that answers a click — which is the whole reason this is a style and not a
/// modifier applied around the button.
struct ViewportControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // A nested `View` rather than building it here: `makeBody` is nonisolated
        // and `viewportControlLabelStyle()` is `@MainActor`, which a `body` is.
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration

        var body: some View {
            configuration.label
                .viewportControlLabelStyle()
                // The platform's chrome is gone, so the press has to be visible
                // somewhere; without this a tap gives no acknowledgement at all.
                .opacity(configuration.isPressed ? 0.55 : 1)
        }
    }
}

/// **A square stated once, because none of these glyphs is square.** `Circle` as a
/// background insets to the shorter side of whatever it is given, and at `.title3`
/// `ellipsis.circle` measures 33 × 33, `mic.slash` 31 × 34 and `slider.horizontal.3`
/// 35 × 31 — so padding each glyph gave three different diameters, and the two
/// oblong ones overhung the circle they sat in. That overhang is what was reported
/// as a stray grey line across the settings button: the slider's own strokes,
/// outside the disc. A `Menu` was the extreme case at 79 × 40, chevron and all.
///
/// `@ScaledMetric` rather than a bare constant, because the glyph inside grows with
/// the reader's text size and a fixed box would clip it — this module's rule for
/// every `Metrics` constant. At the default size the multiplier is 1, so adopting
/// it moves no reference image.
private struct ViewportControlStyle: ViewModifier {
    @ScaledMetric private var side = Metrics.viewportControl

    func body(content: Content) -> some View {
        content
            .font(.title3)
            .frame(width: side, height: side)
            .reachySurface(.chrome, in: .circle)
            // The frame is a square and the surface drawn in it is a disc, so
            // without this the corners outside the disc stay tappable — 21% of the
            // box, in the gaps between three controls sitting `Space.md` apart.
            // Stating the square's size is what made that visible; the padded
            // version had the same mismatch on a smaller box.
            .contentShape(.circle)
    }
}
