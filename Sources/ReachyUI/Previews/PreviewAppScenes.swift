import ReachyDesign
import ReachyKit
@testable import ReachyUI
import SwiftUI

/// Preview wrappers for the app store and the running-app dock.
///
/// Split out of `PreviewScenes.swift` only because that file is at its length
/// limit. Same rules apply: not `private`, because Prefire copies each preview body
/// into a generated file and anything a body names has to be visible target-wide.
@MainActor
extension PreviewScene {
    static func appStore(
        _ session: RobotSession,
        model: AppStoreModel? = nil,
        install: AppInstallModel? = nil,
        runningApp: RunningAppModel? = nil
    ) -> some View {
        NavigationHost {
            AppStoreScreen(
                session: session,
                runningApp: runningApp ?? .preview(),
                // Built on *this* session, not one of its own: the model reads the
                // running app through it, and two sessions would put the screen and
                // the dock on different robots.
                model: model ?? .preview(session: session),
                install: install ?? .preview(state: .idle, session: session)
            )
        }
        .preview()
    }

    /// The one page about an app, previewed on its own: it carries the whole
    /// install flow — a snapshot of it is the only view of a job in flight — and,
    /// when the session says this app holds the robot, the process controls and the
    /// app's own settings row.
    static func appDetail(
        _ session: RobotSession,
        app: RobotApp,
        model: AppStoreModel? = nil,
        install: AppInstallModel? = nil,
        runningApp: RunningAppModel? = nil,
        conversation: ConversationModel? = nil
    ) -> some View {
        NavigationHost {
            AppDetailSheet(
                app: app,
                model: model ?? .preview(session: session),
                session: session,
                install: install ?? .preview(state: .idle, session: session),
                runningApp: runningApp ?? .preview(),
                conversation: conversation ?? .preview(),
                dismiss: {}
            )
        }
        .preview()
    }

    /// The same page reached from the dock. The status is parked on the session,
    /// which is where the running app lives — handing the page a status the session
    /// did not agree with would preview a state the app cannot reach.
    ///
    /// `conversationTurn` seeds the conversation model this builds — it moved off
    /// `RunningAppModel` with the rest of the conversation state, so the two are now
    /// separate arguments rather than one.
    static func runningAppDetail(
        _ status: RobotAppStatus,
        phase: RobotSession.ConnectionPhase = .connected(.preview),
        model: RunningAppModel? = nil,
        conversationTurn: ConversationTurn? = nil
    ) -> some View {
        let session = RobotSession.preview(phase: phase, runningApp: status)
        return appDetail(
            session,
            // The running app is installed by definition, and the store model is
            // what the page asks. Left at the default catalogue it would offer
            // "Install" for the app currently holding the robot.
            app: status.app,
            model: .preview(session: session, section: .installed, installed: [status.app]),
            runningApp: model ?? .preview(),
            conversation: .preview(turn: conversationTurn)
        )
    }

    /// The app's own settings page. Only the states *around* the web view can be
    /// captured — see the note in `AppSettingsPreviews`.
    static func appSettings(_ phase: AppSettingsScreen.Phase) -> some View {
        // The real seam rather than a literal: a preview session parks a LAN
        // address and the conversation app declares 7860, so this is the URL the
        // screen is handed on a robot. It is never dialled — `reachyPreviewMode`
        // leaves the web view unmounted.
        let url = RobotSession.preview().appSettingsURL(for: .previewConversation)!
        return NavigationHost {
            AppSettingsScreen(url: url, phase: phase)
        }
        .preview()
    }

    /// The bottom strip on its own. Sized to fit rather than to a device: it is a
    /// component, and a full-screen capture of one would be mostly empty.
    ///
    /// `placement` defaults to `.standalone`, which is both the environment's own
    /// default and the shape the strip takes below iOS 26.1 — so every capture here
    /// is of the half a root capture on an iOS 26 simulator can never show. `.inline`
    /// is the other one: nothing scrolls in a snapshot, so a minimised tab bar is
    /// unreachable from a root preview and this is the only way to cover it.
    static func runningAppDock(
        _ status: RobotAppStatus,
        conversationTurn: ConversationTurn? = nil,
        isMicrophoneMuted: Bool = false,
        // `true` because the model's own default is: the controls are offered until
        // an app answers `-32601`. A preview defaulting the other way would picture
        // the rarer half of the fork.
        offersConversationControls: Bool = true,
        isReachable: Bool = true,
        busy: Bool = false,
        wedged: Bool = false,
        actionFailure: String? = nil,
        placement: ReachyAccessoryPlacement = .standalone
    ) -> some View {
        RunningAppDockContent(
            status: status,
            conversationTurn: conversationTurn,
            isMicrophoneMuted: isMicrophoneMuted,
            offersConversationControls: offersConversationControls,
            isReachable: isReachable,
            busy: busy,
            wedged: wedged,
            actionFailure: actionFailure,
            expand: {},
            perform: { _ in }
        )
        .environment(\.reachyAccessoryPlacement, placement)
        .preview()
    }
}

/// The soundboard, which is not an app — it lives in this file only because
/// `PreviewScenes.swift` is at its length limit and a fourth scene file for one
/// wrapper would be worse.
@MainActor
extension PreviewScene {
    static func soundboard(
        _ session: RobotSession,
        model: SoundboardModel? = nil,
        presence: PresenceModel? = nil
    ) -> some View {
        NavigationHost {
            SoundboardScreen(
                session: session,
                presence: presence ?? .preview(),
                model: model ?? .preview()
            )
        }
        .preview()
    }
}

extension PreviewScene {
    /// The conversation screen, handed a model already in the state being pictured.
    ///
    /// Not `private`, like every other factory here: Prefire copies each preview body
    /// verbatim into a generated file, where a `private` helper is out of scope.
    static func conversation(
        _ model: ConversationModel,
        session: RobotSession? = nil,
        app: RobotApp = .previewConversation
    ) -> some View {
        // `nil` and resolved here, never a defaulted `@MainActor` value: that spelling
        // compiles in the SwiftPM targets and fails in the `Apps/` ones, which is a
        // failure `swift build` cannot see because `Previews/` is excluded from it.
        let session = session ?? .preview(runningApp: RobotAppStatus(app: app, state: .running))
        return NavigationHost {
            ConversationScreen(app: app, session: session, model: model)
        }
        .preview()
    }

    /// The personality and voice sheet, previewed as the form it is — the sheet
    /// presentation itself captures as nothing.
    static func conversationVoices(
        _ model: ConversationVoiceModel,
        session: RobotSession? = nil
    ) -> some View {
        let session = session ?? .preview(
            runningApp: RobotAppStatus(app: .previewConversation, state: .running)
        )
        return ConversationVoiceSheet(app: .previewConversation, session: session, model: model)
            .preview()
    }
}
