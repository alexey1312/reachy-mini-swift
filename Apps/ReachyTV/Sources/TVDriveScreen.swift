import ReachyDesign
import ReachyKit
import ReachyMedia
import ReachyTeleop
import SwiftUI

/// The robot's camera, full screen, and a game controller or the Siri Remote to drive it.
///
/// The legend is the one focusable view, with nothing to move focus to while the picture
/// streams, so the remote's touch surface steers rather than navigates, and Menu leaves.
/// A controller drives the whole time and moves no focus at all — the TV target's
/// Info.plist (`Apps/Tuist/ProjectDescriptionHelpers`) says why.
///
/// Everything goes through `TeleopDriver`, the driver the phone's Controller screen
/// uses, claimed from the shared `GamepadTeleop` at `.screen` priority. So the slew
/// limiter and the daemon's limits apply unchanged (project rule 2), and the controller
/// lets go whenever the robot sleeps, the screen goes, or the app leaves the front.
///
/// The camera is the phone's own `CameraSession` on the robot's `:8443` signalling, drawn
/// by ReachyMedia's `CameraVideoView`, and it runs while the robot sleeps: the screen opens
/// for watching as much as for driving. The microphone stays off — the TV offers no way
/// to talk through the robot yet — while the robot's own sound plays on the TV.
struct TVDriveScreen: View {
    let session: RobotSession
    @State private var driver = TeleopDriver()
    /// Built on appear and stopped on the way out. WebRTC has no cheap pause, so a
    /// session is dropped rather than kept, as the phone's viewport does.
    @State private var camera: CameraSession?
    @State private var setupError: String?
    @FocusState private var hasFocus: Bool
    @Environment(\.dismiss) private var dismiss

    private var gamepad: GamepadTeleop {
        .shared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Above the legend rather than behind it, so a status never sits under it.
            cameraStatus
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            hud
                .frame(width: TVMetrics.listWidth)
                .padding(TVMetrics.gutter)
                .focusable()
                .focused($hasFocus)
                .focusEffectDisabled()
        }
        .background {
            if let camera {
                // Full bleed: letterboxing is the renderer's, which clears what the
                // stream does not fill.
                CameraVideoView(track: camera.videoTrack)
                    .ignoresSafeArea()
            }
        }
        // A cover is drawn over the screen it was presented from, and without a page of
        // its own the robot screen shows through it.
        .background(.background)
        .onAppear {
            hasFocus = true
            start()
        }
        .onDisappear {
            driver.stop()
            camera?.stop()
            camera = nil
        }
        .onChange(of: session.isAwake) { _, awake in
            // Targets accumulated while asleep would be replayed as one jump.
            if awake {
                driver.reset()
            }
        }
        .gamepadTeleop(driver, priority: .screen, standDown: nil, isActive: drives)
        .onExitCommand {
            dismiss()
        }
    }

    /// Never during a wake: a stream of targets just after the motors come on can take
    /// the daemon down (pollen-robotics/reachy_mini#1430), which is the phone's gate too.
    private var drives: Bool {
        session.isAwake && session.powerTransition == nil
    }

    private var hud: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            if !session.isAwake {
                Label(.reachy("Robot is asleep"), systemImage: "moon.zzz")
            }
            if let setupError {
                Text(setupError)
                    .foregroundStyle(.secondary)
            }
            legend
        }
        .padding(Space.xxl)
        .reachySurface(.card, in: Radius.rect(Radius.window))
    }

    /// What each control does, for the input in use. The controller's rows are the
    /// phone's legend (`GamepadLegendSection`), word for word.
    @ViewBuilder
    private var legend: some View {
        if let name = gamepad.controllerName {
            // The controller's own name, as the system reports it.
            Label(name, systemImage: gamepad.drivesWithRemote ? "appletvremote.gen4.fill" : "gamecontroller")
                .font(Typography.rowTitle)
            if gamepad.drivesWithRemote {
                row(.reachy("Look around"), control: .reachy("Touch surface"))
                row(.reachy("Reset to neutral"), control: .reachy("Play/Pause"))
                Text(.reachy("Drag to look around. Hold at the side to turn the body."))
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
            } else {
                row(.reachy("Look around"), control: .reachy("Right stick"))
                row(.reachy("Turn the body"), control: .reachy("Left stick, sideways"))
                row(.reachy("Raise or lower the head"), control: .reachy("Left stick, up and down"))
                row(.reachy("Tilt the head"), control: .reachy("Shoulder buttons"))
                row(.reachy("Move the antennas"), control: .reachy("Triggers"))
                row(.reachy("Reset to neutral"), control: .reachy("Right face button"))
            }
        } else {
            Text(.reachy("Connect a game controller, or use the Siri Remote."))
        }
    }

    private func row(_ action: LocalizedStringResource, control: LocalizedStringResource) -> some View {
        LabeledContent {
            Text(control)
                .foregroundStyle(.secondary)
        } label: {
            Text(action)
        }
    }

    /// The phone's words for each state of the stream (`CameraViewport`), and nothing
    /// once it streams. A stall is the one state with something to do, so its button is
    /// the only other thing on this screen that takes focus.
    @ViewBuilder
    private var cameraStatus: some View {
        if let camera {
            switch camera.phase {
            case .connecting:
                ProgressView(.reachy("Connecting…"))
            case .waitingForProducer:
                ContentUnavailableView(
                    .reachy("Waiting for camera"),
                    systemImage: "video",
                    description: Text(.reachy("The robot has not registered a video stream yet."))
                )
            case .stalled:
                ContentUnavailableView {
                    Label(.reachy("Camera unavailable"), systemImage: "video.slash")
                } description: {
                    Text(.reachy("The video connection did not finish setting up, even on a second try."))
                } actions: {
                    Button(.reachy("Try again"), action: camera.retry)
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
        } else {
            // No LAN address to open signalling on — the TV reaches robots on its own
            // network only, so this is a session that went away under the screen.
            ContentUnavailableView(.reachy("Camera unavailable"), systemImage: "video.slash")
        }
    }

    private func start() {
        do {
            try driver.start { try session.makeTeleop() }
        } catch {
            setupError = RobotSession.describe(error)
        }
        guard camera == nil, let address = session.address,
              let camera = try? CameraSession(address: address)
        else { return }
        camera.start()
        self.camera = camera
    }
}
