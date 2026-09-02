import ReachyDesign
import ReachyKit
import ReachyMedia
import SwiftUI

/// The connected interface: five tabs that are always there.
///
/// `.sidebarAdaptable` is iOS 18 / macOS 15 — on the deployment floor, not an
/// iOS 26 API — and it replaces the hand-written `HStack { viewport | Divider |
/// column }` the root used to build for a regular width. Five unconditional tabs
/// are what make it possible: a sidebar cannot adapt around a destination that
/// appears and disappears under it.
struct ReachyTabShell: View {
    let session: RobotSession
    let viewport: ViewportModel
    let floating: FloatingViewportModel
    let runningApp: RunningAppModel
    let router: ReachyRouter
    let remoteLink: RemoteRobotLink?
    /// Owned by the root — a call outlives the shell's tabs the way the
    /// viewport does — and read here by the two viewport hosts.
    let call: RobotCallController
    let findRobot: () -> Void

    /// The store's two models live here rather than inside the Apps tab because the
    /// dock expands into the *same* page a store row opens, and it does so from
    /// every tab. One copy, or the two surfaces disagree about what is installed the
    /// moment either one acts. They are inert until `load()`, so holding them for
    /// the life of a connection costs nothing — and a connection is exactly how long
    /// the caches behind them live.
    @State private var store: AppStoreModel
    @State private var install: AppInstallModel

    /// The one record of what this robot was last asked for. `LiveTab` owned it, and
    /// its own note said why it could not live in `ViewportView`: that view is
    /// *conditional*, and a `@State` model inside something that unmounts forgets the
    /// robot's behaviours. The column is the third thing that unmounts it — after a
    /// sleeping robot and the floating window — and the first that unmounts the tab
    /// as well, so the record moves up one more level. One instance per connection is
    /// also the truthful shape: presence belongs to the robot, and two copies could
    /// disagree about what it was asked for.
    @State private var presence = PresenceModel()

    init(
        session: RobotSession,
        viewport: ViewportModel,
        floating: FloatingViewportModel,
        runningApp: RunningAppModel,
        router: ReachyRouter,
        remoteLink: RemoteRobotLink?,
        call: RobotCallController,
        findRobot: @escaping () -> Void
    ) {
        self.session = session
        self.viewport = viewport
        self.floating = floating
        self.runningApp = runningApp
        self.router = router
        self.remoteLink = remoteLink
        self.call = call
        self.findRobot = findRobot
        _store = State(initialValue: AppStoreModel(session: session))
        _install = State(initialValue: AppInstallModel(session: session))
    }

    var body: some View {
        @Bindable var router = router
        return TabView(selection: $router.tab) {
            Tab(value: ReachyRouter.Tab.robot) {
                docked {
                    RobotTab(session: session, router: router)
                }
            } label: {
                Label(.reachy("Robot"), systemImage: "figure.wave")
            }
            Tab(value: ReachyRouter.Tab.live) {
                docked {
                    LiveTab(
                        session: session,
                        viewport: viewport,
                        floating: floating,
                        router: router,
                        remoteLink: remoteLink,
                        presence: presence,
                        call: call
                    )
                }
            } label: {
                Label(.reachy("Live"), systemImage: "cube.transparent")
            }
            Tab(value: ReachyRouter.Tab.moves) {
                docked {
                    MovesTab(session: session, router: router, presence: presence)
                }
            } label: {
                Label(.reachy("Moves"), systemImage: "music.note")
            }
            Tab(value: ReachyRouter.Tab.apps) {
                docked {
                    AppsTab(
                        session: session,
                        router: router,
                        runningApp: runningApp,
                        store: store,
                        install: install,
                        findRobot: findRobot
                    )
                }
            } label: {
                Label(.reachy("Apps"), systemImage: "square.grid.2x2")
            }
            Tab(value: ReachyRouter.Tab.settings) {
                docked {
                    SettingsTab(session: session, router: router)
                }
            } label: {
                Label(.reachy("Settings"), systemImage: "gearshape")
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // The strip lives in the system's accessory slot, which is the row a
        // minimised bar shrinks to make. Order against `floatingViewport` is free —
        // measured on iOS 26.4, an accessory applied either side of the overlay
        // reports the same geometry to the point.
        .reachyTabAccessory(isPresented: dockIsUp) { dock }
        // The bar gets out of the way while reading a list and comes back on the way
        // up. iPhone only, and the fork lives in `ReachyChrome` — a sidebar has
        // nothing to minimise. It used to be switched off while the dock was up,
        // for a reason the accessory removes; `reachyMinimizingTabBar` carries it.
        .reachyMinimizingTabBar()
        // The router is read here rather than inside the model: `placement` is a
        // function of which tab is showing, and this is the one place that knows.
        .onChange(of: router.tab, initial: true) { _, tab in
            floating.isLiveTabSelected = tab == .live
        }
        // Neither placement the strip can take is reported to an overlay on the
        // `TabView`, the way the tab bar is not, so the window is told rather than
        // left to measure.
        .onChange(of: dockIsUp, initial: true) { _, isUp in
            floating.hasBottomAccessory = isUp
        }
        .floatingViewport(model: floating, viewport: viewport, session: session) {
            router.tab = .live
        }
        // The other second place, and the two are mutually exclusive by construction:
        // `placement` yields a window or a column, never both, so only one of these
        // two modifiers ever has anything to draw.
        .viewportColumn(
            model: floating,
            viewport: viewport,
            session: session,
            presence: presence,
            call: call
        )
        // Not mounted in the gate: with no connection `RunningAppModel.canPoll` is
        // false and the dock draws nothing, so the polling should die with the shell
        // rather than idle behind the gate.
        .runningApp(session: session, model: runningApp, store: store, install: install)
    }

    private var dockIsUp: Bool {
        runningApp.visibleStatus(for: session) != nil
    }

    /// The strip, wherever it is drawn. One definition, six mount points, of which
    /// exactly one is live on any given OS.
    private var dock: some View {
        RunningAppDock(session: session, model: runningApp)
    }

    /// Below iOS 26.1, and on every macOS, the inset belongs to the **tab**: on the
    /// `TabView` a bottom `safeAreaInset` is drawn straight over the bar, and on a
    /// tab's content it lands above it. A no-op wherever the system slot is live, so
    /// the two can never both draw a strip.
    ///
    /// Five copies of the strip therefore exist below the floor, since the shell
    /// builds all five tabs at once. That is layout only — every effect the dock has
    /// lives in `runningApp`, mounted once — so do not collapse these into a single
    /// overlay on the `TabView`: an overlay does not inset a tab's content, and the
    /// last row of every list would sit under the strip forever.
    private func docked(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .reachyTabAccessoryFallback(isPresented: dockIsUp) { dock }
            // A window resting in a bottom corner covers the last rows of whatever
            // list it floats over, and a form cannot scroll a row out from under
            // an overlay it knows nothing about. So the tab is told: the window's
            // height plus its margins, only while it is down there.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if floating.placement.restsAtBottomCorner {
                    Color.clear.frame(height: Metrics.floatingViewport.height + Space.lg * 2)
                }
            }
    }
}
