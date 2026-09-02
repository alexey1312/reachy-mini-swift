import HuggingFaceAuth
import ReachyDesign
import ReachyKit
import ReachyWidgetUI
import SwiftUI

/// The robot's app store: what is installed, what the Hub offers, and what is
/// running right now.
struct AppStoreScreen: View {
    let session: RobotSession
    /// The dock's model, adopted rather than owned: a row opens the same page the
    /// dock does, and that page carries Restart and Stop.
    let runningApp: RunningAppModel
    /// Opening the account sheet belongs to the root, which owns it. Discover needs
    /// it because a robot with no Hugging Face session has no catalogue to show.
    let signIn: () -> Void

    @State private var model: AppStoreModel
    @State private var install: AppInstallModel
    @State private var selected: RobotApp?
    @Environment(\.reachyPreviewMode) private var previewMode
    /// This app's own session, which is where a replacement token for the robot
    /// comes from. Optional because a preview host has none.
    @Environment(HFAccount.self) private var hfAccount: HFAccount?

    /// `model` is `nil` rather than a defaulted value: it now needs `session`, and a
    /// default argument cannot read another parameter.
    init(
        session: RobotSession,
        runningApp: RunningAppModel,
        model: AppStoreModel? = nil,
        install: AppInstallModel? = nil,
        signIn: @escaping () -> Void = {}
    ) {
        self.session = session
        self.runningApp = runningApp
        self.signIn = signIn
        _model = State(initialValue: model ?? AppStoreModel(session: session))
        _install = State(initialValue: install ?? AppInstallModel(session: session))
    }

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                Picker(.reachy("Section"), selection: $model.section) {
                    ForEach(AppStoreModel.Section.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
            }

            if model.isHeldRemotely {
                Section {
                    remoteSessionNotice
                }
            }

            if let lastError = model.lastError, !model.isContentLoading {
                Section {
                    Text(lastError)
                        .font(Typography.status)
                        .foregroundStyle(Tone.danger.style)
                }
            }

            Section {
                ForEach(model.visibleApps) { app in
                    Button {
                        selected = app
                    } label: {
                        AppStoreRow(
                            app: app,
                            isInstalled: model.isInstalled(app),
                            isRunning: model.isRunning(app),
                            hasUpdate: model.hasUpdate(app),
                            isStartupApp: model.isStartupApp(app),
                            isPinned: model.isPinned(app)
                        )
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .leading) {
                        pinButton(for: app)
                    }
                    // Both gestures, on purpose: the swipe is the fast path for a
                    // reader who knows it is there, the menu is the discoverable one
                    // and the only one with room for a second action.
                    .contextMenu {
                        if model.canStart(app) {
                            Button {
                                Task { await model.start(app, session: session) }
                            } label: {
                                Label(.reachy("Start"), systemImage: "play.fill")
                            }
                        }
                        pinButton(for: app)
                    }
                    .reachyEntityIdentifier(RobotAppEntity.self, id: app.id)
                }
            }
        }
        .overlay {
            if model.section == .discover, model.discoverNeedsHFSignIn {
                signInGate
            } else if model.visibleApps.isEmpty, !model.isContentLoading {
                emptyState
            }
        }
        .readablePage()
        .contentLoading(isPresented: model.isContentLoading, title: .reachy("Browsing the robot app aisle…"))
        .navigationTitle(.reachy("Apps"))
        .searchable(text: $model.searchText, prompt: String(localized: .reachy("Search apps")))
        .refreshable { await reload(refresh: true) }
        // An install is a minute of progress the reader may have put down; the end
        // of it is worth a tick either way.
        .sensoryFeedback(trigger: install.state) { _, state in
            switch state {
            case .succeeded, .daemonRestarted: .success
            case .failed: .error
            case .idle, .running: nil
            }
        }
        // No running-app inset here any more: the dock is mounted on the root
        // `TabView`, below the tab bar, and is on screen for every tab. A second
        // copy on this one would be the same control twice.
        .minimizedSearchToolbar()
        .toolbar { filterMenu }
        .reachyRefreshToolbar(isDisabled: model.loading || model.isContentLoading) { await reload(refresh: true) }
        .sheet(item: $selected) { app in
            NavigationStack {
                AppDetailSheet(
                    app: app,
                    model: model,
                    session: session,
                    install: install,
                    runningApp: runningApp
                ) { selected = nil }
            }
            .presentationDetents([.medium, .large])
            .reachySheet()
        }
        // A page somebody asked for from outside this screen — `.system.open`, or a
        // tapped Spotlight row for an app entity. Keyed on the lists as well as on
        // the request, because the request routinely arrives before the catalogue
        // has loaded: `installed` is what a cold launch fills first, and a Discover
        // row needs the Hub round trip behind it.
        .onChange(of: openRequest, initial: true) { _, _ in openRequestedApp() }
        .task {
            guard !previewMode else { return }
            await reload()
        }
    }

    /// Everything resolving a requested page waits on, in one `Equatable` value —
    /// the `RoutingTrigger` shape `RootCallLifecycle` uses. The counts rather than
    /// the arrays: what matters is that a list *changed*, and comparing two
    /// catalogues of four hundred apps on every redraw is not free.
    private struct OpenRequest: Equatable {
        let appID: String?
        let installedCount: Int
        let catalogueCount: Int
    }

    private var openRequest: OpenRequest {
        OpenRequest(
            appID: model.requestedAppID,
            installedCount: model.installed.count,
            catalogueCount: model.catalogue.count
        )
    }

    /// Opens the page for an app named from outside this screen.
    ///
    /// **Installed first, deliberately.** The two lists key on the same `RobotApp.id`
    /// but only the installed one is filled without a Hub round trip, and an app
    /// somebody asks to open by name is overwhelmingly one they have.
    ///
    /// An id that matches nothing is *kept* while the screen is still loading and
    /// dropped once it is not: a request cleared mid-load would be a page that never
    /// opens for a reader whose catalogue was a second behind, and a request kept
    /// for ever would open a page the moment an unrelated app was installed.
    private func openRequestedApp() {
        guard let id = model.requestedAppID else { return }
        if let app = model.installed.first(where: { $0.id == id })
            ?? model.catalogue.first(where: { $0.id == id })
        {
            model.requestedAppID = nil
            selected = app
        } else if !model.isContentLoading, !model.loading {
            model.requestedAppID = nil
        }
    }

    /// The store reads the robot's Hugging Face session on the way in, so every
    /// load carries the token that can renew it.
    private func reload(refresh: Bool = false) async {
        await model.load(session: session, refresh: refresh) { await hfAccount?.currentToken() }
    }

    /// Discover with no Hub behind it.
    ///
    /// The robot searches Hugging Face with its own token, and an expired one leaves
    /// the daemon answering with the handful of curated apps instead of the whole
    /// catalogue. Showing that list would be showing a store that is quietly missing
    /// most of itself, so the section asks for the sign-in that fixes it. Installed
    /// apps are untouched — they are on the robot already.
    private var signInGate: some View {
        ContentUnavailableView {
            Label(.reachy("Sign in to browse apps"), systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Text(.reachy(
                // swiftlint:disable:next line_length
                "The robot searches Hugging Face with your account, and its session has ended. Installed apps keep working."
            ))
        } actions: {
            Button(.reachy("Sign in to Hugging Face"), action: signIn)
        }
    }

    /// One button, two hosts — the swipe and the menu must not drift into saying
    /// different things about the same app.
    private func pinButton(for app: RobotApp) -> some View {
        Button {
            model.togglePin(app)
        } label: {
            Label(
                model.isPinned(app) ? .reachy("Unpin") : .reachy("Pin"),
                systemImage: model.isPinned(app) ? "pin.slash" : "pin"
            )
        }
    }

    /// One menu holding two inline `Picker`s, which is what buys the checkmarks,
    /// the VoiceOver wording and the platform's own menu chrome for free. A pair of
    /// hand-rolled rows would have to earn each of those back.
    private var filterMenu: some View {
        @Bindable var model = model
        return Menu {
            Picker(.reachy("Show"), selection: $model.scope) {
                ForEach(AppStoreModel.Scope.allCases) { scope in
                    Label(scope.title, systemImage: scope.symbol).tag(scope)
                }
            }
            .pickerStyle(.inline)

            Picker(.reachy("Sort by"), selection: $model.sort) {
                ForEach(AppStoreModel.Sort.allCases) { sort in
                    Label(sort.title, systemImage: sort.symbol).tag(sort)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(
                .reachy("Filter and sort"),
                systemImage: model.isFiltering
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .help(Text(.reachy("Filter and sort")))
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else if model.lastError != nil {
            ContentUnavailableView(
                .reachy("Store unavailable"),
                systemImage: "wifi.exclamationmark",
                description: Text(
                    .reachy("The robot could not reach Hugging Face. Refresh once it is back online.")
                )
            )
            // Below the error on purpose: a filter over a catalogue that never arrived
            // is not why the list is empty, and saying so would send the reader to
            // clear a filter that was never the problem.
        } else if model.scope != .all {
            ContentUnavailableView {
                Label(.reachy("Nothing matches this filter"), systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(.reachy("No app in this section is filed under that heading."))
            } actions: {
                Button(.reachy("Show all apps")) { model.scope = .all }
            }
        } else {
            switch model.section {
            case .installed:
                ContentUnavailableView(
                    .reachy("No apps installed"),
                    systemImage: "square.stack.3d.up.slash",
                    description: Text(.reachy("Browse Discover to install one from Hugging Face."))
                )
            case .discover:
                ContentUnavailableView(
                    .reachy("Nothing to show"),
                    systemImage: "square.stack.3d.up.slash",
                    description: Text(.reachy("The robot found no apps on Hugging Face."))
                )
            }
        }
    }

    /// A relay session holds the same lock a local app does, and the user cannot
    /// take it back from here — saying so beats a disabled button with no reason.
    private var remoteSessionNotice: some View {
        Label {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(.reachy("In use remotely"))
                    .font(Typography.subtitle.weight(.semibold))
                Text(
                    model.lockHolder
                        .map { String(localized: .reachy("\($0) is driving this robot over Hugging Face.")) }
                        ?? String(localized: .reachy("Someone is driving this robot over Hugging Face."))
                )
                .font(Typography.status)
                .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.tint)
        }
    }
}

private extension View {
    @ViewBuilder
    func minimizedSearchToolbar() -> some View {
        #if os(iOS)
            if #available(iOS 26.0, *) {
                searchToolbarBehavior(.minimize)
            } else {
                self
            }
        #else
            self
        #endif
    }
}
