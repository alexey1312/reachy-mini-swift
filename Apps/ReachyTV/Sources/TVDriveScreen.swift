import ReachyDesign
import ReachyKit
import ReachyTeleop
import SwiftUI

/// Driving, full screen: a game controller or the Siri Remote moves the robot.
///
/// The screen is one focusable view with nothing to move focus to, so the remote's
/// touch surface steers rather than navigates, and Menu leaves. A controller drives the
/// whole time and moves no focus at all — `Apps/Project.swift` says why.
///
/// Everything goes through `TeleopDriver`, the driver the phone's Controller screen
/// uses, claimed from the shared `GamepadTeleop` at `.screen` priority. So the slew
/// limiter and the daemon's limits apply unchanged (project rule 2), and the controller
/// lets go whenever the robot sleeps, the screen goes, or the app leaves the front.
///
/// The camera belongs behind the legend. It needs WebRTC for tvOS, which this target
/// does not link yet (`docs/research/tvos.md`), so the space says so.
struct TVDriveScreen: View {
    let session: RobotSession
    @State private var driver = TeleopDriver()
    @State private var setupError: String?
    @FocusState private var hasFocus: Bool
    @Environment(\.dismiss) private var dismiss

    private var gamepad: GamepadTeleop {
        .shared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Where the picture goes once the TV has a camera; it will fill the screen
            // behind the legend rather than sit above it.
            ContentUnavailableView(.reachy("Camera unavailable"), systemImage: "video.slash")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            hud
                .frame(width: TVMetrics.listWidth)
                .padding(TVMetrics.gutter)
        }
        // A cover is drawn over the screen it was presented from, and without a page of
        // its own the robot screen shows through it.
        .background(.background)
        .focusable()
        .focused($hasFocus)
        .focusEffectDisabled()
        .onAppear {
            hasFocus = true
            start()
        }
        .onDisappear {
            driver.stop()
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

    private func start() {
        do {
            try driver.start { try session.makeTeleop() }
        } catch {
            setupError = RobotSession.describe(error)
        }
    }
}
