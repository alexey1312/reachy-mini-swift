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

    @State private var model: AppStoreModel
    @State private var install: AppInstallModel
    @State private var selected: RobotApp?
    @Environment(\.reachyPreviewMode) private var previewMode

    /// `model` is `nil` rather than a defaulted value: it now needs `session`, and a
    /// default argument cannot read another parameter.
    init(
        session: RobotSession,
        runningApp: RunningAppModel,
        model: AppStoreModel? = nil,
        install: AppInstallModel? = nil
    ) {
        self.session = session
        self.runningApp = runningApp
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
                        .font(.caption)
                        .foregroundStyle(.red)
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
                }
            }
        }
        .overlay {
            if model.visibleApps.isEmpty, !model.isContentLoading {
                emptyState
            }
        }
        .contentLoading(isPresented: model.isContentLoading, title: .reachy("Browsing the robot app aisle…"))
        .navigationTitle(.reachy("Apps"))
        .searchable(text: $model.searchText, prompt: String(localized: .reachy("Search apps")))
        // No running-app inset here any more: the dock is mounted on the root
        // `TabView`, below the tab bar, and is on screen for every tab. A second
        // copy on this one would be the same control twice.
        .minimizedSearchToolbar()
        .toolbar {
            Button {
                Task { await model.load(session: session, refresh: true) }
            } label: {
                Label(.reachy("Refresh"), systemImage: "arrow.clockwise")
            }
            .disabled(model.loading || model.isContentLoading)
        }
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
        .task {
            guard !previewMode else { return }
            await model.load(session: session)
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

    @ViewBuilder
    private var emptyState: some View {
        if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else if model.lastError != nil {
            ContentUnavailableView(
                .reachy("Store unavailable"),
                systemImage: "wifi.exclamationmark",
                description: Text(
                    .reachy("The robot could not reach Hugging Face. Pull to refresh once it is back online.")
                )
            )
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
            VStack(alignment: .leading, spacing: 2) {
                Text(.reachy("In use remotely"))
                    .font(.subheadline.weight(.semibold))
                Text(
                    model.lockHolder
                        .map { String(localized: .reachy("\($0) is driving this robot over Hugging Face.")) }
                        ?? String(localized: .reachy("Someone is driving this robot over Hugging Face."))
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.tint)
        }
    }
}

private extension View {
    /// iOS 26 collapses a bottom search field into a button until it is used. The
    /// deployment floor is iOS 18, so this is opt-in per availability rather than
    /// a project-wide setting.
    ///
    /// The member is `.minimize`, not `.minimized` — Apple's own documentation for
    /// `searchToolbarBehavior(_:)` shows the latter in its example, and it does not
    /// compile.
    @ViewBuilder
    func minimizedSearchToolbar() -> some View {
        #if os(iOS)
            if #available(iOS 26, *) {
                searchToolbarBehavior(.minimize)
            } else {
                self
            }
        #else
            self
        #endif
    }
}
