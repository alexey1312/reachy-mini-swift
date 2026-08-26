import HuggingFaceAuth
import ReachyKit
import ReachyMedia
import SwiftUI

/// Entry point for the shared UI. It owns what outlives a screen — the session,
/// the account and its robot list, the viewport, the running-app dock and the
/// router — and chooses between exactly two things: connecting, or being
/// connected.
///
/// The tab bar lives below this rather than in the app target because every tab
/// shares one `RobotSession` and one `ViewportModel`. The app target's own
/// developer screen is injected and handed to Settings, so it keeps owning that
/// screen without a tab or a nested tab bar.
public struct ReachyRootView<Developer: View>: View {
    @State private var session: RobotSession
    @State private var viewport: ViewportModel
    /// Where that viewport is drawn. It outlives the shell for the same reason the
    /// viewport does — a corner the user chose must survive a network blip — and it
    /// is read by the lifecycle, which is above the shell.
    @State private var floating: FloatingViewportModel
    /// One Hugging Face session for the whole app, restored from the Keychain on
    /// launch and handed down through the environment — the account outlives any
    /// one robot connection, and several screens read it.
    @State private var hfAccount: HFAccount
    /// The account's robot list, held here rather than built by the sheet that
    /// shows it.
    ///
    /// A `.sheet` content closure is re-run on **every** update of the view it
    /// hangs off, so a model constructed inside one is replaced by a fresh, empty
    /// one each time. This body reads `session.phase`, and the candidate sweep
    /// walks it `idle → handshaking → idle` every 10 s while the gate is up — so
    /// the list of robots the user was reading was replaced within seconds by a
    /// model that had never asked central anything, and `.task` does not get a
    /// second turn to ask again.
    @State private var remoteRobots: YourReachiesModel
    @State private var runningApp: RunningAppModel
    @State private var router: ReachyRouter
    /// Held for as long as the remote session is: dropping it would close the peer
    /// connection the session is talking over.
    @State private var remoteLink: RemoteRobotLink?
    /// Frames the two-way session as a system call (issue #78). Owned here
    /// because a call outlives tab changes and the shell itself — its keep-alive
    /// is read by the lifecycle, which is above the shell. Constructing it is
    /// inert: the LiveCommunicationKit manager only exists from the first call.
    @State private var call: RobotCallController
    /// What the gate's rail is showing. Owned here rather than by the gate because
    /// the fork below is what destroys the gate, and this is what defers that fork.
    @State private var progress: ConnectProgressModel

    private let developer: Developer

    @MainActor
    public init(@ViewBuilder developer: () -> Developer) {
        self.init(session: RobotSession(), developer: developer)
    }

    /// Internal so previews can park the root in a phase a real connection would have to reach.
    @MainActor
    init(
        session: RobotSession,
        viewport: ViewportModel = ViewportModel(),
        floating: FloatingViewportModel? = nil,
        hfAccount: HFAccount? = nil,
        remoteRobots: YourReachiesModel? = nil,
        runningApp: RunningAppModel? = nil,
        tab: ReachyRouter.Tab = .robot,
        remoteLink: RemoteRobotLink? = nil,
        progress: ConnectProgressModel? = nil,
        call: RobotCallController? = nil,
        @ViewBuilder developer: () -> Developer
    ) {
        _session = State(initialValue: session)
        _call = State(initialValue: call ?? RobotCallController())
        _progress = State(initialValue: progress ?? ConnectProgressModel(initialPhase: session.phase))
        _viewport = State(initialValue: viewport)
        _floating = State(initialValue: floating ?? FloatingViewportModel())
        _runningApp = State(initialValue: runningApp ?? RunningAppModel())
        _router = State(initialValue: ReachyRouter(tab: tab))
        _remoteLink = State(initialValue: remoteLink)
        let account = hfAccount ?? HFAccount(store: KeychainHFTokenStore())
        _hfAccount = State(initialValue: account)
        _remoteRobots = State(initialValue: remoteRobots ?? Self.yourReachies(for: account))
        self.developer = developer()
    }

    /// Central, authenticated with this app's own Hugging Face session — which is
    /// the only thing that makes a robot visible to its owner and to nobody else.
    @MainActor
    private static func yourReachies(for account: HFAccount) -> YourReachiesModel {
        YourReachiesModel(
            listing: CentralRelayClient { [account] in await account.currentToken() },
            // `.needsReauth` also carries a username, so the state is the question,
            // not whether a name is known.
            isSignedIn: { [account] in
                if case .signedIn = account.state {
                    true
                } else {
                    false
                }
            }
        )
    }

    public var body: some View {
        Group {
            if isConnectedEnough {
                ReachyTabShell(
                    session: session,
                    viewport: viewport,
                    floating: floating,
                    runningApp: runningApp,
                    router: router,
                    remoteLink: remoteLink,
                    call: call,
                    findRobot: findRobotButtonTapped
                )
            } else {
                ConnectGate(session: session, router: router, progress: progress)
            }
        }
        // Opacity and nothing geometric. Crossing this line throws the whole tree
        // below it away along with its `@State`, which is right — a new robot
        // deserves a fresh app list — but it means there is no shared geometry for
        // a matched transition to move between.
        .transition(.opacity)
        .environment(\.reachyDeveloperScreen) { [developer] in AnyView(developer) }
        .environment(runningApp)
        .environment(hfAccount)
        .environment(router)
        .modifier(
            RootSheets(
                session: session,
                hfAccount: hfAccount,
                remoteRobots: remoteRobots,
                router: router,
                connect: connectRemotely
            )
        )
        .modifier(
            RootLifecycle(
                session: session,
                viewport: viewport,
                floating: floating,
                hfAccount: hfAccount,
                remoteRobots: remoteRobots,
                runningApp: runningApp,
                router: router,
                call: call,
                remoteLink: $remoteLink
            )
        )
        .modifier(
            RootCallLifecycle(
                session: session,
                viewport: viewport,
                router: router,
                call: call,
                remoteLink: remoteLink
            )
        )
    }

    /// The fork the old `robotTab` made, with one condition added. `.unreachable`
    /// stays on the shell side deliberately: a network blip must not pull the tab
    /// bar out from under a finger, and the robot screen already says so in place.
    ///
    /// **The progress checks only ever delay.** The displayed phase must first catch
    /// `.connected`, otherwise the child observing the transition could be removed
    /// before it sees it. `holdsGate` then keeps that final frame visible for its
    /// dwell. The model releases on a ceiling that depends on nothing (`maxHold`),
    /// so no state it can reach keeps the reader out of a connected app; and at
    /// `dwell: .zero` it never holds at all, which is why every reference image
    /// behaves exactly as it did before this existed. `.unreachable` bypasses both:
    /// a later network blip belongs to the shell and must never resurrect the gate.
    private var isConnectedEnough: Bool {
        switch session.phase {
        case let .connected(identity):
            !progress.holdsGate && progress.displayed == .connected(identity)
        case .unreachable:
            true
        case .idle, .connecting: false
        }
    }

    /// Opens the relay session first, then hands the session a client that speaks
    /// over it. `start()` only begins asking central for a session — nothing has
    /// reached the robot yet, and the control channel's own deadline is what bounds
    /// the wait if it never answers.
    private func connectRemotely(to robot: CentralRobot) {
        router.showsRemoteRobots = false
        stopRemoteLink()
        let link = RemoteRobotLink(
            robot: robot,
            relay: CentralRelayClient { [hfAccount] in await hfAccount.currentToken() }
        )
        remoteLink = link
        link.start()
        router.tab = .robot
        Task { await session.connect(using: link.client) }
    }

    private func stopRemoteLink() {
        remoteLink?.stop()
        remoteLink = nil
    }

    private func findRobotButtonTapped() {
        if session.isRemote {
            session.disconnect()
        }
        router.tab = .robot
    }
}
