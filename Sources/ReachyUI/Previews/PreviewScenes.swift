import HuggingFaceAuth
import ReachyKit
import ReachyMedia
@testable import ReachyUI
import SwiftUI

/// Wrappers shared by preview bodies.
///
/// Deliberately not `private`, and deliberately not free functions: Prefire copies each preview's
/// body verbatim into a generated test file, so anything a body references has to be visible
/// across the whole target. A `private` helper compiles fine in the preview file and then fails
/// the generated test with "cannot find … in scope".
///
/// Every wrapper sets `reachyPreviewMode`, so no individual preview can forget it and leave a
/// WebSocket reconnecting in the background while the snapshot is taken.
@MainActor
enum PreviewScene {
    static let address = RobotAddress(host: "192.168.1.42")

    /// An account parked in one state, for the toolbar button and the sheet behind
    /// it. Goes through `HFSignInModel.preview`, which is where the token fixtures
    /// that make each state coherent already live.
    static func account(in state: HFAccount.State) -> HFAccount {
        HFSignInModel.preview(state: state).account
    }

    /// `health` defaults to nil so every preview written before the state screen
    /// existed still parks this one where it did — `RobotScreen` then builds its own,
    /// which decides only whether the State row is offered.
    static func robotScreen(_ session: RobotSession, health: RobotHealthModel? = nil) -> some View {
        NavigationHost {
            RobotScreen(session: session, health: health)
        }
        .preview()
    }

    /// The state screen on its own. It is a pushed destination, so capturing it
    /// through the Robot tab would photograph the tab — and the four states worth
    /// covering are all inside it.
    static func robotHealth(_ model: RobotHealthModel) -> some View {
        NavigationHost {
            RobotHealthScreen(model: model)
        }
        .preview()
    }

    /// The account button in a bar of its own. A whole root would capture the button at two
    /// pixels' worth of a full screen; this is what makes each state legible.
    static func accountToolbar(_ state: HFAccount.State) -> some View {
        NavigationHost {
            Text("Robot")
                .navigationTitle("Reachy Mini")
                .hfAccountToolbar(isPresented: .constant(false))
        }
        .environment(account(in: state))
        .preview()
    }

    /// The rail with its header, on its own. Worth capturing apart from the screen:
    /// on a full gate capture it is a strip a tenth of the frame tall, and the seven
    /// states it distinguishes are the whole reason it exists.
    static func rail(
        _ step: RobotSession.ConnectionStep,
        powerTransition: RobotSession.PowerTransition? = nil
    ) -> some View {
        ConnectHeader(
            session: .preview(phase: .connecting(step), powerTransition: powerTransition),
            displayed: .connecting(step)
        )
        .preview()
    }

    /// The two ends of the walk, which no `ConnectionStep` can express: nothing
    /// attempted yet, and every stage done. The second is the frame `holdsGate`
    /// exists to keep on screen.
    static func rail(_ phase: RobotSession.ConnectionPhase) -> some View {
        ConnectHeader(session: .preview(phase: phase), displayed: phase)
            .preview()
    }

    /// The model defaults are `nil` rather than `.preview()`: a default argument is evaluated in a
    /// nonisolated context, and every one of these factories is main-actor isolated.
    static func movesScreen(
        _ session: RobotSession,
        model: MovesModel? = nil,
        recorder: MoveRecorderModel? = nil
    ) -> some View {
        NavigationHost {
            MovesScreen(session: session, presence: .preview(), model: model ?? .preview(), recorder: recorder)
        }
        .preview()
    }

    // The app-store and running-app wrappers live in `PreviewAppScenes.swift` —
    // this file is at its length limit.

    static func logConsole(
        _ model: LogConsoleModel? = nil,
        setupError: String? = nil,
        session: RobotSession? = nil
    ) -> some View {
        NavigationHost {
            LogConsoleScreen(
                session: session ?? .preview(),
                model: model ?? .preview(),
                setupError: setupError
            )
        }
        .preview()
    }

    /// The local-daemon row on its own.
    ///
    /// Standalone rather than through `connection(_:)`, and that is the only way it
    /// can be captured at all: the section is mounted under `#if os(macOS)` — see
    /// `ConnectionScreen.form` for why it is not also `targetEnvironment(simulator)`
    /// — while the snapshot suite runs on an iOS simulator. The component itself
    /// carries no `#if`, so its three states render here exactly as macOS draws
    /// them; what no reference covers is the mount point.
    static func localDaemonSection(_ status: LocalDaemonModel.Status) -> some View {
        Form {
            LocalDaemonSection(model: .preview(status), connect: { _ in })
        }
        .formStyle(.grouped)
        .preview()
    }

    static func simulatorSection(isConnecting: Bool = false) -> some View {
        Form {
            SimulatorSection(isConnecting: isConnecting, connect: {})
        }
        .formStyle(.grouped)
        .preview()
    }

    static func audioSection(_ model: AudioSettingsModel? = nil, header: String? = "Audio") -> some View {
        Form {
            AudioSettingsSection(session: .preview(), header: header, model: model ?? .preview())
        }
        .formStyle(.grouped)
        .preview()
    }

    static func controller(
        _ session: RobotSession,
        driver: TeleopDriver? = nil,
        setupError: String? = nil,
        recorder: MoveRecorderModel? = nil
    ) -> some View {
        NavigationHost {
            ControllerScreen(
                session: session,
                driver: driver ?? TeleopDriver(),
                setupError: setupError,
                recorder: recorder
            )
        }
        .preview()
    }

    /// Enough to hang the joystick and its return-to-neutral button on a camera
    /// preview: what offers them is the factory being *present*, not it being
    /// callable. Nothing ever calls this one — `connectTeleop` returns early in
    /// preview mode — so throwing is the honest body rather than a limitation.
    static let teleopFactory: TeleopFactory = { throw ReachyKitError.teleopUnavailable }

    /// `makeTeleop` decides whether the joystick is offered at all, so it is a
    /// preview knob rather than something derived here.
    static func viewport(
        _ model: ViewportModel,
        offersCamera: Bool = true,
        makeTeleop: TeleopFactory? = nil,
        // Whether this host offers the Presence button — true on the Live tab, false
        // in the floating window, where the robot is watched rather than configured.
        //
        // A `Bool` rather than an optional session with a `.preview()` default: a
        // defaulted argument is evaluated nonisolated, and every `RobotSession`
        // factory is main-actor isolated. That compiles under SwiftPM and fails only
        // in the Xcode targets, minutes into a snapshot run that has already deleted
        // every reference.
        offersPresence: Bool = true,
        // Whether a call is up, which is what puts the End button in the chrome
        // row. A `Bool` for the same reason `offersPresence` is one — the
        // controller's factory is main-actor isolated and a defaulted argument is
        // evaluated nonisolated.
        onCall: Bool = false
    ) -> some View {
        ViewportView(
            model: model,
            offersCamera: offersCamera,
            makeTeleop: makeTeleop,
            robotSession: offersPresence ? .preview() : nil,
            // Built here rather than defaulted for the reason `offersPresence` is a
            // `Bool`: a defaulted argument is evaluated nonisolated and this initialiser
            // is `@MainActor`.
            presence: PresenceModel(),
            call: onCall ? .preview(robotName: "Reachy") : nil
        )
        .preview()
    }

    /// The sheet that button opens: the robot's audio levels and its two presence
    /// behaviours, reachable without giving up the stream.
    /// `viewport` is what adds the Call section: without one there is no microphone
    /// track to scale, so the sheet leaves the slider out rather than showing a dead
    /// one. Nil by default, so every reference recorded before it is unchanged.
    static func telepresence(
        _ session: RobotSession? = nil,
        presence: PresenceModel? = nil,
        viewport: ViewportModel? = nil
    ) -> some View {
        NavigationHost {
            TelepresenceSheet(
                session: session ?? .preview(),
                dismiss: {},
                viewport: viewport,
                presence: presence,
                // Settled, not empty: `AudioSettingsSection`'s `.task` is skipped in
                // preview mode, so the default model would capture every slider at
                // zero with Test sound greyed out — a picture of a screen that never
                // loaded rather than of this one.
                audio: .preview()
            )
        }
        .preview()
    }

    /// The floating window over a screen-shaped hole, so the corner it rests in is
    /// part of the capture rather than something to take on trust.
    ///
    /// `bounds` comes from the container rather than from a real safe area: the
    /// placement arithmetic is covered by `FloatingViewportModelTests`, and what a
    /// reference adds is the window's own size, shape and chrome.
    static func floatingViewport(
        _ model: FloatingViewportModel,
        viewport: ViewportModel? = nil,
        session: RobotSession? = nil
    ) -> some View {
        GeometryReader { geometry in
            FloatingViewport(
                model: model,
                viewport: viewport ?? .preview(),
                session: session ?? .preview(),
                bounds: CGRect(origin: .zero, size: geometry.size),
                open: {}
            )
        }
        .frame(width: 320, height: 460)
        .preview()
    }

    /// The viewport fills whatever it is given, so previews of its inner panes need a frame or
    /// they collapse to nothing on a `sizeThatFits` capture.
    static func pane(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The letterbox a camera pane sits in, not a design colour.
            .background(.black)
            .preview()
    }

    /// `route` is a parameter because the segments are the screen's shape: a
    /// capture of one says nothing about the other two.
    ///
    /// The progress model is always zero-dwell. With a real one the screen's
    /// `onChange` would queue the phase and the capture would land on whichever
    /// frame the drain happened to be on — the same timing dependence the spinner
    /// previews already have, and avoidable here.
    static func connection(
        _ session: RobotSession,
        route: ConnectRoute = .local,
        browser: RobotBrowser? = nil,
        manualInput: String = "",
        knownRobots: KnownRobotsModel? = nil
    ) -> some View {
        ConnectionScreen(
            session: session,
            progress: ConnectProgressModel(dwell: .zero),
            browser: browser ?? .preview(names: []),
            manualInput: manualInput,
            knownRobots: knownRobots ?? .preview([]),
            route: route,
            showPermissions: {}
        )
        .preview()
    }

    /// `hfAccount` is injectable because the account button now sits in every
    /// tab's bar: without one every root capture would show only the signed-out
    /// state.
    static func root(
        _ session: RobotSession,
        viewport: ViewportModel? = nil,
        floating: FloatingViewportModel? = nil,
        tab: ReachyRouter.Tab = .robot,
        hfAccount: HFAccount? = nil,
        remoteLink: RemoteRobotLink? = nil
    ) -> some View {
        ReachyRootView(
            session: session,
            viewport: viewport ?? .preview(),
            floating: floating,
            hfAccount: hfAccount,
            tab: tab,
            remoteLink: remoteLink
        ) {
            Text("Developer tools")
        }
        // **Every root capture takes the fallback placement, and none may take the
        // system's.** `tabViewBottomAccessory` does not merely fail to render
        // headless — an enabled one blanks the entire capture, the way
        // `.buttonStyle(.glass)` does: recorded once without this line and
        // `Root — dock on the robot tab` came back with no Form on it at all, just
        // ghosts of the artwork tile and the tab-bar glyphs. Since a blank reference
        // reads as cover and passes any change, the harness forces the other branch
        // rather than leaving each preview to remember.
        //
        // So the native placement is uncapturable, in the sense `SceneViewport.ready`
        // is, and the device checklist is its only cover. What these images do still
        // certify is everything either placement shares — that the tab bar survives,
        // that the strip is above it, that the tab's content is inset to clear it.
        .environment(\.reachyTabAccessoryStyle, .legacy)
        .preview()
    }

    /// A journal short enough to fit a card, with one line per level the console colours.
    static let journalLines = [
        "2026-08-04T09:12:01 INFO reachy_mini.daemon: starting backend",
        "2026-08-04T09:12:02 WARNING NetworkManager: wlan0 disconnected",
        "2026-08-04T09:12:04 ERROR reachy_mini.daemon: no route to host",
    ]

    /// pip is what the robot's updater actually shells out to.
    static let installerLines = [
        "Collecting reachy-mini==1.9.1",
        "  Downloading reachy_mini-1.9.1-py3-none-any.whl (2.1 MB)",
        "Installing collected packages: reachy-mini",
        "Successfully installed reachy-mini-1.9.1",
    ]

    // MARK: - Provisioning over Bluetooth

    /// Every onboarding step goes through the flow rather than being rendered on its own, so the
    /// snapshot carries the stack and the Cancel button the user actually sees.
    static func onboarding(_ model: OnboardingModel) -> some View {
        OnboardingFlow(model: model, onFinish: { _ in }, onCancel: {})
            .preview()
    }

    static func bleConsole(_ model: BLEConsoleModel) -> some View {
        NavigationHost {
            BLEConsoleScreen(model: model)
        }
        .preview()
    }

    static func commands(_ model: BLEConsoleModel) -> some View {
        NavigationHost {
            BLERecoveryCommandsSheet(model: model)
        }
        .preview()
    }

    static func softwareReset(
        _ model: BLEConsoleModel,
        acknowledged: Bool = false,
        typedID: String = "",
        code: String = "",
        dispatched: Bool = false,
        stillAnswering: Bool? = nil
    ) -> some View {
        NavigationHost {
            BLESoftwareResetScreen(
                model: model,
                script: .describing("SOFTWARE_RESET"),
                acknowledged: acknowledged,
                typedID: typedID,
                code: code,
                dispatched: dispatched,
                stillAnswering: stillAnswering
            )
        }
        .preview()
    }
}

// `NavigationHost` and `View.preview()` live in `PreviewHost.swift` — they were
// file-private here, which is what stopped the scenes being split across two files.
// Two are now three: the app store and the dock are in `PreviewAppScenes.swift`,
// Settings and everything reached from it in `PreviewSettingsScenes.swift`. This
// file is at the length limit, so the next scene joins one of those or starts a
// fourth.
