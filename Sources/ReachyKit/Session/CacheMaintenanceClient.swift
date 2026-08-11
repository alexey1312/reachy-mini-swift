import Foundation

/// The robot's two maintenance actions. Both of them delete something, and
/// neither can be undone from this app.
///
/// `POST /cache/clear-hf` and `POST /cache/reset-apps`, from
/// `daemon/app/routers/cache.py`. Mounted at the **app root** — no `/api` — and
/// only when the daemon was started with `--wireless-version`, exactly like
/// `/wifi/*` and `/update/*`. The committed OpenAPI spec is generated without
/// that flag, so the generated client cannot reach either one and both are
/// hand-written here. A Lite robot 404s, which `wirelessData` turns into
/// ``ReachyKitError/wirelessFeaturesUnavailable``.
///
/// Each route answers 200 whether it deleted anything or found the directory
/// already gone, and 500 with a `detail` otherwise. The distinction between
/// "cleared" and "was already empty" lives only in an English `message` the
/// daemon composes, so it is dropped here rather than shown: the outcome is the
/// same either way, and a screen cannot translate it.
public protocol CacheMaintenanceClient: Sendable {
    /// Deletes `/home/pollen/.cache/huggingface` — every model weight the robot
    /// has downloaded. They come back on demand, at the cost of the download.
    func clearHuggingFaceCache() async throws

    /// Deletes `/venvs/apps_venv/` in one `shutil.rmtree`: every installed app
    /// **and** the Python environment they share.
    ///
    /// The daemon does not stop a running app first and does not put anything
    /// back — a process left running is a process whose interpreter has been
    /// deleted out from under it. Callers are responsible for both.
    func resetApps() async throws
}

extension RobotConnection: CacheMaintenanceClient {
    public func clearHuggingFaceCache() async throws {
        try await wirelessData(method: "POST", path: "/cache/clear-hf")
    }

    public func resetApps() async throws {
        try await wirelessData(method: "POST", path: "/cache/reset-apps")
    }
}

public extension RobotSession {
    /// False on a Lite robot and over the relay, neither of which mounts
    /// `/cache/*`.
    var canPerformMaintenance: Bool {
        client is any CacheMaintenanceClient && supportsWirelessFeatures
    }

    func clearHuggingFaceCache() async throws {
        try await withMaintenanceClient { try await $0.clearHuggingFaceCache() }
    }

    /// Uninstalls every app. See ``CacheMaintenanceClient/resetApps()`` for what
    /// the daemon does *not* do around it.
    ///
    /// Both app caches go with it. They are the same two an install or a remove
    /// job invalidates, and this deletes the environment every entry in them
    /// described — a catalogue still marking apps installed would offer Open and
    /// Remove on rows the robot no longer has.
    func resetApps() async throws {
        try await withMaintenanceClient { try await $0.resetApps() }
        appCatalogueCache = nil
        installedAppsCache = nil
        await forgetPersistedCatalogue()
    }
}

extension RobotSession {
    func withMaintenanceClient<T>(_ call: (any CacheMaintenanceClient) async throws -> T) async throws -> T {
        guard let client else { throw ReachyKitError.notConnected }
        guard let maintenance = client as? any CacheMaintenanceClient else {
            throw ReachyKitError.wirelessFeaturesUnavailable
        }
        return try await call(maintenance)
    }
}
