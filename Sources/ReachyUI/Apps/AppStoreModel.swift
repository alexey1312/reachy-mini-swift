import Foundation
import Observation
import ReachyDesign
import ReachyKit

/// Drives the robot's app store: what is installed, what could be, and what is
/// running right now.
@MainActor
@Observable
final class AppStoreModel {
    enum Section: Int, CaseIterable, Identifiable {
        case installed
        case discover

        var id: Int {
            rawValue
        }

        var title: LocalizedStringResource {
            switch self {
            case .installed: .reachy("Installed")
            case .discover: .reachy("Discover")
            }
        }
    }

    var section: Section = .installed
    var searchText = ""

    /// Held so `runningApp` can read through to it. The mutating calls still take a
    /// session of their own — collapsing them is a separate change.
    private let session: RobotSession

    private(set) var installed: [RobotApp] = []
    private(set) var catalogue: [RobotApp] = []
    private(set) var startupApp: String?
    private(set) var updates: AppUpdatesSummary?
    private(set) var lock: RobotAppLockStatus?
    private(set) var loading = false
    private(set) var busy = false
    private(set) var lastError: String?
    /// A successful answer, including `[]`, is different from never having received
    /// the catalogue. That distinction keeps empty and loading states honest.
    private var hasCatalogueResult = false
    private var attemptedCatalogueLoad = false

    /// Coalesces overlapping loads: a slow catalogue must not overwrite the result
    /// of a refresh the user asked for afterwards (`MovesModel`'s pattern).
    private var loadID: UUID?

    init(session: RobotSession) {
        self.session = session
    }

    /// Read through rather than stored: the session is the single writer, and the
    /// global dock renders the same value. Two copies would drift the moment one
    /// screen acted and the other did not hear about it.
    var runningApp: RobotAppStatus? {
        session.runningApp
    }

    /// Initial load and a retry without data replace the empty content area. Refreshing
    /// a catalogue already on screen does not.
    var isContentLoading: Bool {
        !hasCatalogueResult && (loading || !attemptedCatalogueLoad)
    }

    var visibleApps: [RobotApp] {
        let apps = switch section {
        case .installed: installed
        case .discover: catalogue
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }
        return apps.filter { $0.matchesSearch(query) }
    }

    /// The installed row a catalogue card stands for. Everything the daemon does to
    /// an app — start, stop, remove, update, auto-start — is keyed by *that* name,
    /// which the Space author chose independently of the slug.
    func installedTwin(of app: RobotApp) -> RobotApp? {
        if app.isInstalled {
            return app
        }
        return installed.first { app.matches(installed: $0) }
    }

    func isInstalled(_ app: RobotApp) -> Bool {
        installedTwin(of: app) != nil
    }

    func hasUpdate(_ app: RobotApp) -> Bool {
        guard let updates, let twin = installedTwin(of: app) else { return false }
        return updates.hasUpdate(for: twin) || updates.hasUpdate(for: app)
    }

    func isRunning(_ app: RobotApp) -> Bool {
        guard let runningApp, let twin = installedTwin(of: app) else { return false }
        return runningApp.app.name == twin.name
    }

    func isStartupApp(_ app: RobotApp) -> Bool {
        guard let startupApp, let twin = installedTwin(of: app) else { return false }
        return startupApp == twin.name
    }

    /// Someone is driving this robot from outside the LAN. Worth distinguishing
    /// from a local app: the user cannot simply stop it from here.
    var isHeldRemotely: Bool {
        lock?.state == .remoteSession
    }

    var lockHolder: String? {
        lock?.holderName
    }

    func load(session: RobotSession, refresh: Bool = false) async {
        let requestID = UUID()
        loadID = requestID
        loading = true
        defer {
            if loadID == requestID {
                loading = false
            }
        }

        do {
            // One `list-available` carries the catalogue and the installed list
            // together (`list_all_available_apps`), so the two sections cost one
            // round trip rather than two.
            let apps = try await session.appCatalogue(refresh: refresh)
            guard loadID == requestID, !Task.isCancelled else { return }
            catalogue = apps.filter { !$0.isInstalled }
            installed = apps.filter(\.isInstalled)
            hasCatalogueResult = true
            attemptedCatalogueLoad = true
            lastError = nil
        } catch {
            guard loadID == requestID, !Task.isCancelled else { return }
            attemptedCatalogueLoad = true
            lastError.recordDaemonFailure(error)
            return
        }

        // Everything below is decoration: a robot whose store loaded is usable
        // even if its update check timed out.
        //
        // The running app is not assigned here — `currentApp()` writes it into the
        // session. A failed call therefore leaves the last known app standing
        // rather than blanking the dock, which is what a mid-restart daemon
        // deserves.
        _ = try? await session.currentApp()
        // Read first, assign behind the same guard as the catalogue: a refresh
        // started meanwhile must not have its decoration overwritten by this
        // older load finishing last.
        let lock = try? await session.appLockStatus()
        let startupApp = try? await session.startupApp()
        let updates = try? await session.appUpdates()
        guard loadID == requestID, !Task.isCancelled else { return }
        self.lock = lock
        self.startupApp = startupApp
        self.updates = updates
    }

    func start(_ app: RobotApp, session: RobotSession) async {
        guard let twin = installedTwin(of: app) else { return }
        await run { _ = try await session.startApp(named: twin.name) }
    }

    /// `nil` clears it. Sent under the installed name, which is the only one the
    /// daemon will accept.
    func setStartupApp(_ app: RobotApp?, session: RobotSession) async {
        let name = app.flatMap { installedTwin(of: $0)?.name }
        await run { startupApp = try await session.setStartupApp(name) }
    }

    /// Re-reads what an install or removal changed, without re-fetching the
    /// catalogue from Hugging Face.
    /// Enough to say whether this app is installed, whether it auto-starts, and
    /// which installed row its commands are keyed by — without the Hugging Face
    /// round trip the catalogue costs.
    ///
    /// The detail sheet opens from two places now, and only one of them has been
    /// through the store: reached from the dock it would otherwise offer "Install"
    /// for the app currently running.
    func loadInstalledIfNeeded(session: RobotSession) async {
        guard installed.isEmpty else { return }
        installed = await (try? session.installedApps()) ?? installed
        startupApp = try? await session.startupApp()
    }

    func reloadInstalled(session: RobotSession) async {
        installed = await (try? session.installedApps(refresh: true)) ?? installed
        _ = try? await session.currentApp()
        startupApp = try? await session.startupApp()
    }

    private func run(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            lastError = nil
        } catch {
            lastError.recordDaemonFailure(error)
        }
    }
}

private extension RobotApp {
    /// Title, name, author and Space id all answer — a user who knows an app by
    /// its Hub URL should find it by pasting the owner in.
    func matchesSearch(_ query: String) -> Bool {
        [title, name, author, spaceID, summary]
            .compactMap(\.self)
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

#if DEBUG
    extension AppStoreModel {
        /// A store parked in one state. Lives here rather than in `Previews/`:
        /// everything it writes is `private(set)`, which `@testable` does not reach
        /// from another module.
        ///
        /// The running app is **not** a parameter here any more — it lives on the
        /// session, which the dock reads too. Park it with
        /// `RobotSession.preview(runningApp:)` and hand that same session in, or the
        /// screen and the dock will be looking at two different robots.
        ///
        /// `session` defaults to `nil` rather than to a value: a default argument is
        /// evaluated nonisolated, and `RobotSession` is main-actor isolated.
        static func preview(
            session: RobotSession? = nil,
            section: Section = .discover,
            catalogue: [RobotApp] = RobotApp.previewCatalogue,
            installed: [RobotApp] = RobotApp.previewInstalled,
            startupApp: String? = nil,
            hasUpdate: Bool = false,
            lock: RobotAppLockStatus? = nil,
            loading: Bool = false,
            error: String? = nil
        ) -> AppStoreModel {
            let model = AppStoreModel(session: session ?? .preview())
            model.section = section
            model.catalogue = catalogue
            model.installed = installed
            model.startupApp = startupApp
            model.lock = lock
            model.loading = loading
            model.lastError = error
            model.hasCatalogueResult = !catalogue.isEmpty || !installed.isEmpty || (!loading && error == nil)
            model.attemptedCatalogueLoad = !loading || model.hasCatalogueResult
            if hasUpdate, let first = installed.first {
                model.updates = .preview(appName: first.name)
            }
            return model
        }
    }

    extension AppUpdatesSummary {
        static func preview(appName: String) -> AppUpdatesSummary {
            let json = """
            {"apps_with_updates": [{"app_name": "\(appName)", "space_id": "pollen-robotics/\(appName)",
              "installed_sha": "a1b2c3", "latest_sha": "d4e5f6", "update_available": true}],
             "apps_checked": 2, "apps_skipped": 0}
            """
            // swiftlint:disable:next force_try
            return try! AppUpdatesSummary(JSONDecoder().decode(
                Components.Schemas.AppUpdatesResponse.self,
                from: Data(json.utf8)
            ))
        }
    }
#endif
