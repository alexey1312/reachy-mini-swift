import CoreSpotlight
import HuggingFaceAuth
import ReachyKit
import ReachyMedia
import SwiftUI

/// Every effect the root runs, in one place.
///
/// Applied with `.modifier(_:)` rather than through a `View` extension like its
/// neighbours: the cluster needs seven collaborators, and a helper taking seven
/// arguments is a SwiftLint violation while a memberwise initialiser is not.
struct RootLifecycle: ViewModifier {
    let session: RobotSession
    let viewport: ViewportModel
    let floating: FloatingViewportModel
    let hfAccount: HFAccount
    let remoteRobots: YourReachiesModel
    let runningApp: RunningAppModel
    let router: ReachyRouter
    @Binding var remoteLink: RemoteRobotLink?

    /// A `let` with a value, so it stays out of the memberwise initialiser and the
    /// eighth collaborator does not reach the call site. Nothing injects it: the
    /// scene delegate that fills it is built by UIKit, and what is worth asserting
    /// lives in `QuickActionInbox` rather than in a `ViewModifier`.
    private let quickActions = QuickActionInbox.shared

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.reachyPreviewMode) private var previewMode

    func body(content: Content) -> some View {
        content
            .task {
                guard !previewMode else { return }
                hfAccount.restore()
                ReachyQuickAction.install()
                // Here rather than in `ReachyMiniApp.init` for the reason the line
                // above is: both write into a system index off the app's one
                // catalogue, and both must stay behind `previewMode` so a snapshot
                // run and the storybook do not file rows for the simulator.
                await ReachySpotlightIndex.indexIfNeeded()
            }
            // The robot's own apps and moves, as entities rather than destinations —
            // `ReachyEntityIndex` explains the difference. Keyed on both halves so
            // one effect covers connecting, switching robots, and coming back to the
            // app after something was installed: the list is content-stamped, so a
            // run that finds nothing changed costs two small reads and stops.
            .task(id: entityIndexTrigger) {
                guard !previewMode, scenePhase == .active else { return }
                await ReachyEntityIndex.indexIfNeeded(robotID: connectedRobotID)
            }
            .task(id: scenePhase) {
                await noticeEndedMove()
            }
            // `initial: true` because a cold launch fills the inbox in
            // `scene(_:willConnectTo:)`, before this body has ever run.
            .onChange(of: quickActions.pending, initial: true) { _, _ in
                guard !previewMode else { return }
                runQuickAction()
            }
            .onChange(of: hfAccount.state, initial: true) { _, _ in
                guard !previewMode else { return }
                remoteRobots.accountChanged()
            }
            .task(id: viewportTarget) {
                guard !previewMode else { return }
                if let viewportTarget {
                    viewport.attach(to: viewportTarget)
                } else {
                    viewport.detach()
                }
            }
            .onChange(of: viewportIsOnScreen, initial: true) { _, onScreen in
                guard !previewMode else { return }
                viewport.setActive(onScreen)
            }
            .onChange(of: keepsRemoteLinkAlive) { _, keepAlive in
                guard !keepAlive else { return }
                stopRemoteLink()
            }
            .onOpenURL { url in
                // Only a destination this app owns. The OAuth callback shares this
                // scheme and belongs to the sign-in session, so `ReachyDeepLink`
                // refuses it rather than landing the user on a tab mid-authorisation.
                guard let link = ReachyDeepLink(url: url) else { return }
                follow(link)
            }
            // A tapped Spotlight row. Its identifier *is* the deep link, so it lands
            // exactly where a widget's tap does — the `.runningApp` completion
            // included, which no row asks for today and one added later would get
            // without this having to be remembered.
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                guard let link = ReachySpotlightIndex.destination(for: activity) else { return }
                follow(link)
            }
            .widgetReload(session: session, isPreview: previewMode)
    }

    /// A move outlives this process being put away, and the poll that notices one
    /// ending does not — it sleeps with the app. So a screen locked mid-dance comes
    /// back offering Stop over a move the daemon has already forgotten, and that
    /// Stop is a 500; the music is worse, because a recorded move's audio is a
    /// daemon task only this client ever stops.
    ///
    /// It belongs to the root rather than to the Moves screen for the reason the
    /// dance itself does: the robot owns the move, and a track playing over a robot
    /// that has stopped dancing is audible from every tab — including the four this
    /// effect would never run on if it hung off the one showing it.
    ///
    /// A body of its own only because the guard costs `body` its last point of
    /// cyclomatic budget; `runQuickAction` is here for the same reason.
    private func noticeEndedMove() async {
        guard !previewMode, scenePhase == .active else { return }
        await session.refreshMoveActivity()
    }

    /// What makes the entity index re-check itself, in one `Equatable` value.
    ///
    /// The scene phase is in here rather than in a second modifier because
    /// "something was installed while the app was in the background" is the case a
    /// connect-only trigger misses, and it is the ordinary one — the widget and
    /// Shortcuts both start apps without this process running.
    private struct EntityIndexTrigger: Equatable {
        let robotID: String?
        let isActive: Bool
    }

    private var entityIndexTrigger: EntityIndexTrigger {
        EntityIndexTrigger(robotID: connectedRobotID, isActive: scenePhase == .active)
    }

    /// The identity behind the current phase. `RobotSession` keeps its own copy of
    /// this for its caches, and it is not `public` — a screen that needs the robot's
    /// key derives it the same way `SettingsScreen` and `RobotScreen` do.
    private var connectedRobotID: String? {
        switch session.phase {
        case let .connected(identity), let .unreachable(identity): identity.deduplicationKey
        case .idle, .connecting: nil
        }
    }

    /// Selecting the tab is `ReachyRouter`'s; whatever a link has to *do* on arrival
    /// is the caller's, and there are two callers now.
    private func follow(_ link: ReachyDeepLink) {
        router.follow(link)
        if case .runningApp = link {
            runningApp.requestExpansion(for: session)
        }
    }

    /// Both the geometry and the state routes sit behind the backend, so a link
    /// alone is not enough to show anything.
    ///
    /// Over the relay the camera is the peer connection `RemoteRobotLink` already
    /// holds — the same one carrying the commands — rather than one this view would
    /// dial. Reading `session.address` here is what used to make the Live tab
    /// impossible to reach from outside the robot's network.
    private var viewportTarget: ViewportModel.Source? {
        RootViewportTarget.source(session: session, remoteLink: remoteLink)
    }

    /// The single lever for battery: nothing streams unless the viewport is the
    /// thing the user is actually looking at — and a sleeping robot is never that,
    /// however visible the tab is.
    ///
    /// Two ways of being looked at now, not one. The floating window is the second,
    /// and its tab at the edge is what turns it off: `isStreaming` is false the
    /// moment the window is docked, and false on a regular width, where there is no
    /// window at all.
    private var viewportIsOnScreen: Bool {
        guard scenePhase == .active, viewportTarget != nil, session.isAwake else { return false }
        return router.tab == .live || floating.isStreaming
    }

    private var keepsRemoteLinkAlive: Bool {
        RemoteLinkLifetime.shouldKeepAlive(isRemote: session.isRemote, phase: session.phase)
    }

    private func stopRemoteLink() {
        remoteLink?.stop()
        remoteLink = nil
    }

    /// A quick action lands on the Robot tab either way, because that is where the
    /// transition and any failure are shown.
    ///
    /// **It only runs against a robot already connected**, which on a cold launch
    /// is none: the app opens on the gate, the command is dropped, and the tab it
    /// selected is the one it would have opened on anyway. Queueing it until the
    /// session settles is a change to this one guard, and worth making only if the
    /// warm case — the app still resident, which on iOS is most of the time —
    /// turns out not to cover it.
    private func runQuickAction() {
        guard let action = quickActions.take() else { return }
        router.tab = .robot
        guard case .connected = session.phase else { return }
        Task { await action.perform(on: session) }
    }
}

/// Shared by the lifecycle, which decides when to stream, and the Live tab, which
/// decides what to draw. Both ask the same question and must not drift.
enum RootViewportTarget {
    @MainActor
    static func source(session: RobotSession, remoteLink: RemoteRobotLink?) -> ViewportModel.Source? {
        guard session.isBackendRunning else { return nil }
        switch session.link {
        case let .lan(address): return .lan(address)
        case .remote: return remoteLink.map { .remote($0.camera) }
        case .none: return nil
        }
    }
}
