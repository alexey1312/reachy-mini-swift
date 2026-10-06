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
    /// Called on the pad's first deflection, so the robot's own head behaviours let go
    /// before this one starts driving. `nil` leaves them alone, which is what a preview
    /// and the floating window both want.
    var standDown: TeleopStandDown?

    var body: some View {
        CameraVideoView(track: session.videoTrack)
            .overlay(alignment: .center) { status }
            .overlay(alignment: .bottomTrailing) { teleopControls }
    }

    /// **The status backs itself, because nothing under it can be relied on.**
    /// Until a frame arrives `RTCMTLVideoView` skips its draw, so what shows through
    /// is whatever the host put behind it: the system background on the Live tab, the
    /// row's white in the first run (`First run — camera` records it), and the pinned
    /// black of `PreviewScene.pane` in the `Camera —` references. Adaptive text read
    /// on the first two and was black on black on the third, with "Try again" at
    /// about 2.3:1. A fixed dark appearance is the opposite bet — white on white
    /// wherever the host is light — and `AGENTS.md` records a forced-white
    /// "Connecting…" that was removed for that reason. So the status carries its own
    /// surface with adaptive text on it, which reads the same over all three.
    /// `.window` because it is opaque and glass-free, so it also flips correctly in a
    /// dark reference. A stream that is up draws no status, so no surface covers the
    /// picture.
    @ViewBuilder
    private var status: some View {
        if session.phase != .streaming {
            phaseStatus
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .reachySurface(.window)
        }
    }

    @ViewBuilder
    private var phaseStatus: some View {
        switch session.phase {
        case .connecting:
            ProgressView(.reachy("Connecting…"))
        case .waitingForProducer:
            ContentUnavailableView(
                .reachy("Waiting for camera"),
                systemImage: "video",
                description: Text(.reachy("The robot has not registered a video stream yet."))
            )
        case .stalled:
            // The one ending that offers a retry: the session already made its own
            // and gave up, so the next is the reader's to ask for.
            ContentUnavailableView {
                Label(.reachy("Camera unavailable"), systemImage: "video.slash")
            } description: {
                Text(.reachy("The video connection did not finish setting up, even on a second try."))
            } actions: {
                Button(.reachy("Try again"), action: session.retry)
            }
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

    /// The gate is here rather than in `TeleopPadCluster` because it is the *host*
    /// that knows whether there is anything to drive: a stream still negotiating
    /// has no picture to aim at yet, and no factory means this connection carries
    /// no teleop at all, so the joystick is absent rather than offered inert.
    @ViewBuilder
    private var teleopControls: some View {
        if let makeTeleop {
            TeleopPadCluster(
                isVisible: session.phase == .streaming,
                makeTeleop: makeTeleop,
                standDown: standDown
            )
        }
    }
}

/// Hangs up. Present only while a call is actually up, beside the microphone
/// that started it.
///
/// **It goes through the system, never straight to the session.** The Lock
/// Screen's End and this one are one funnel (`EndConversationAction`), so the
/// two UIs cannot disagree about whether a call is running. That is also why
/// there is no macOS spelling: no call ever becomes active there, so this never
/// draws.
struct CallEndButton: View {
    let call: RobotCallController

    var body: some View {
        Button(role: .destructive, action: call.endCall) {
            Label(.reachy("End call"), systemImage: "phone.down.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(Tone.danger.style)
        }
        .buttonStyle(ViewportControlButtonStyle())
        .help(Text(.reachy("End call")))
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
    /// Frames the unmute as a system call (issue #78). `nil` — previews and
    /// macOS today — keeps the direct toggle this button always had.
    var call: RobotCallController?

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
        .buttonStyle(ViewportControlButtonStyle())
        .help(Text(title))
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
        } else if let call {
            call.toggleMic(for: session)
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
