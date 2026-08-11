import ReachyDesign
import ReachyKit
import ReachyMedia
import SwiftUI

/// Robot camera + two-way audio over WebRTC. Video and robot audio play as soon
/// as the session negotiates; the mic button unmutes the client → robot audio
/// uplink (robot speaker). A joystick drives head yaw/pitch so you can look
/// around without leaving the video, and held sideways it turns the body — which
/// is the one thing it leaves behind, so a button beside it undoes that turn once
/// there is one to undo.
struct CameraViewport: View {
    let session: CameraSession
    /// `nil` hides the joystick outright rather than showing one that cannot move
    /// anything.
    var makeTeleop: TeleopFactory?

    @State private var driver: TeleopDriver
    @Environment(\.reachyPreviewMode) private var previewMode

    init(
        session: CameraSession,
        makeTeleop: TeleopFactory? = nil,
        driver: TeleopDriver = TeleopDriver()
    ) {
        self.session = session
        self.makeTeleop = makeTeleop
        _driver = State(initialValue: driver)
    }

    var body: some View {
        CameraVideoView(track: session.videoTrack)
            .overlay(alignment: .center) { status }
            .overlay(alignment: .bottomTrailing) { teleopControls }
            .onAppear { connectTeleop() }
            .onDisappear { driver.stop() }
    }

    @ViewBuilder
    private var status: some View {
        switch session.phase {
        case .connecting:
            ProgressView(.reachy("Connecting…"))
        case .waitingForProducer:
            ContentUnavailableView(
                .reachy("Waiting for camera"),
                systemImage: "video",
                description: Text(.reachy("The robot has not registered a video stream yet."))
            )
        case let .failed(message):
            ContentUnavailableView(
                .reachy("Camera unavailable"),
                systemImage: "video.slash",
                description: Text(message)
            )
        case .streaming:
            EmptyView()
        }
    }

    /// The pad, and beside it the way back from where the pad can leave you.
    ///
    /// Both float over the video rather than in `ViewportView`'s cluster: that
    /// cluster is built a level up, which does not own this driver and covers the
    /// 3D scene too, where teleop does not apply. Here they also land under the
    /// thumb that just turned the robot.
    ///
    /// **An overlay, and it used to be a bottom `safeAreaInset`.** An inset is
    /// subtracted from the video's rectangle, and this one costs a fixed
    /// 140 + 2 × 16 = 172 pt of *height* — nothing on a portrait iPhone's 874, two
    /// thirds of a landscape one's 402. With the navigation and tab bars taking
    /// their own share, the camera was left ~86 pt to letterbox 16:9 into and
    /// rendered a 145 × 80 pt picture in the middle of an 874 pt screen. Nothing
    /// moves by drawing it over instead: the pad's own rectangle is
    /// `bottom − 156 … bottom − 16` either way.
    ///
    /// It is the same symptom `CameraVideoView`'s doc comment describes and a
    /// different cause; that one was the renderer's intrinsic size, and it is
    /// fixed. Measure the rectangle the video is handed before reaching for it.
    @ViewBuilder
    private var teleopControls: some View {
        // No factory means this connection carries no teleop at all, so the
        // joystick is absent rather than offered inert.
        if session.phase == .streaming, makeTeleop != nil {
            HStack(spacing: Space.md) {
                recenterButton
                JoystickPad(mapping: driver.mapping) { driver.apply($0) }
                    .frame(width: 140, height: 140)
            }
            .padding()
            .animation(Motion.stateChange, value: driver.isBodyTurned)
        }
    }

    /// Offered only once the body is actually turned — at neutral there is nothing
    /// to return from, and this screen has no other readout of where the robot is
    /// facing, so the button appearing *is* the notice that it has been left off
    /// centre.
    ///
    /// The return is smooth without anything here doing so: `reset()` moves a
    /// goal, and both transports walk their emitted pose toward it under
    /// `TargetSlewLimiter`. Easing it a second time on this side would fight the
    /// pacer that already does it.
    @ViewBuilder
    private var recenterButton: some View {
        if driver.isBodyTurned {
            Button {
                driver.reset()
            } label: {
                Label(.reachy("Reset to neutral"), systemImage: "arrow.counterclockwise")
                    .labelStyle(.iconOnly)
            }
            .viewportControlStyle()
            .transition(.scale.combined(with: .opacity))
        }
    }

    private func connectTeleop() {
        guard !previewMode, let makeTeleop else { return }
        try? driver.start(makeTeleop)
    }
}

/// Unmutes the client → robot audio uplink. Lives beside the viewport switcher
/// rather than inside the video, so the floating controls stay in one cluster.
///
/// A refused microphone used to be invisible here: `setMicEnabled(true)` swallowed
/// the refusal, so the glyph never changed and tapping did nothing, forever. The
/// blocked state is now a different button — it says so, and it goes somewhere.
struct CameraMicButton: View {
    let session: CameraSession

    @Environment(\.reachyPreviewMode) private var previewMode
    @Environment(\.scenePhase) private var scenePhase

    private var isBlocked: Bool {
        session.micPermission.isBlocking
    }

    var body: some View {
        Button(action: act) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .foregroundStyle(tint)
        }
        .viewportControlStyle()
        // A blocked microphone is still worth explaining while the stream is down,
        // but there is nothing to unmute into, so the rule is unchanged.
        .disabled(session.phase != .streaming)
        .onChange(of: scenePhase) { _, phase in
            scenePhaseChanged(phase)
        }
    }

    private func act() {
        if isBlocked {
            PrivacySettingsLink.open(.microphone)
        } else {
            session.setMicEnabled(!session.isMicEnabled)
        }
    }

    private func scenePhaseChanged(_ phase: ScenePhase) {
        guard !previewMode, phase == .active else { return }
        session.refreshMicPermission()
    }

    /// The glyph is icon-only, so this is also what a screen reader announces.
    private var title: String {
        if isBlocked {
            return String(localized: .reachy("Microphone access is turned off"))
        }
        return session.isMicEnabled
            ? String(localized: .reachy("Mute microphone"))
            : String(localized: .reachy("Unmute microphone"))
    }

    private var symbol: String {
        if isBlocked {
            return "mic.slash.circle"
        }
        return session.isMicEnabled ? "mic.fill" : "mic.slash"
    }

    /// `.warning`, not `.danger`: a live microphone is already red, and two reds on one
    /// control would say "recording" and "broken" in the same colour. The tones resolve
    /// to the same `.red`/`.secondary` this button always used, so naming them moves no
    /// reference image.
    private var tint: AnyShapeStyle {
        if isBlocked {
            return Tone.warning.style
        }
        return session.isMicEnabled ? Tone.danger.style : Tone.quiet.style
    }
}
