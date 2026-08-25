import Foundation

/// What the mirror needs from `NSUbiquitousKeyValueStore`, and nothing more.
///
/// `UserDefaults` satisfies it too, and that is the test seam: the real store has no suite
/// equivalent, so `swift test --parallel` would have every suite fighting over one table.
public protocol UbiquitousStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
    @discardableResult
    func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: UbiquitousStore {}
extension UserDefaults: UbiquitousStore {}

/// Mirrors a fixed set of `UserDefaults` keys into iCloud's key-value store and back.
///
/// One direction per notification: an external change is copied into the suite, a local
/// change is pushed to the cloud. Both directions compare before writing, so the pull's own
/// `didChangeNotification` finds equality and nothing echoes back — which is what lets every
/// writer of these keys stay unaware that a mirror exists.
@MainActor
public final class CloudSettingsMirror {
    /// The app's one instance, created in the app target's `init`. A `shared` slot rather
    /// than an injected collaborator for the reason `QuickActionInbox.shared` gives:
    /// `RootLifecycle` is at its collaborator limit, and only the app process may hold the
    /// entitlement this mirrors through.
    public static var shared: CloudSettingsMirror?

    private let defaults: UserDefaults
    private let cloud: UbiquitousStore
    private let keys: [String]
    private let onDidApplyExternalChange: @MainActor () -> Void
    /// Never unregistered: the mirror lives as long as the process, and a dropped test
    /// instance leaves observers that no-op through their `weak self`. A `deinit` cannot
    /// touch this property under strict concurrency anyway.
    private var observers: [NSObjectProtocol] = []
    /// `defaults.set` posts `didChangeNotification` synchronously, so a pull re-enters
    /// `pushLocalChanges` mid-loop — which would push a stale local value over a cloud key
    /// the same batch has not applied yet. The flag pauses pushes for the apply's duration.
    private var isApplyingExternalChange = false

    public init(
        defaults: UserDefaults,
        cloud: UbiquitousStore,
        keys: [String],
        onDidApplyExternalChange: @escaping @MainActor () -> Void = {}
    ) {
        self.defaults = defaults
        self.cloud = cloud
        self.keys = keys
        self.onDidApplyExternalChange = onDidApplyExternalChange
    }

    public func start() {
        cloud.synchronize()
        var applied = false
        for key in keys {
            applied = reconcile(key) || applied
        }
        if applied {
            onDidApplyExternalChange()
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] notification in
            let changed = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated {
                self?.applyExternalChange(toKeys: changed ?? [])
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pushLocalChanges()
            }
        })
    }

    /// The foreground nudge. KVS uploads and downloads on its own schedule, and asking on
    /// scene activation is the one lever the app has over that schedule.
    public func synchronize() {
        cloud.synchronize()
    }

    /// One key's first meeting of the two stores. The cloud wins a difference — an offline
    /// local write already sits in the cloud store's on-device cache, so it is not lost —
    /// and a cloud that has never seen the key learns the local value, which is the
    /// existing-installation first launch with no marker flag needed.
    private func reconcile(_ key: String) -> Bool {
        let cloudValue = cloud.object(forKey: key)
        let localValue = defaults.object(forKey: key)
        if cloudValue != nil {
            guard !isEqual(cloudValue, localValue) else { return false }
            defaults.set(cloudValue, forKey: key)
            return true
        }
        if localValue != nil {
            cloud.set(localValue, forKey: key)
        }
        return false
    }

    // ponytail: whole-value last-writer-wins per key — two devices writing concurrently
    // lose one add. Self-healing for the robots blob: every handshake re-remembers, and
    // remember() is an upsert. Upgrade path: per-key union merge on lastConnected.
    private func applyExternalChange(toKeys changed: [String]) {
        var applied = false
        isApplyingExternalChange = true
        for key in changed where keys.contains(key) {
            let cloudValue = cloud.object(forKey: key)
            guard !isEqual(cloudValue, defaults.object(forKey: key)) else { continue }
            if let cloudValue {
                defaults.set(cloudValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            applied = true
        }
        isApplyingExternalChange = false
        if applied {
            onDidApplyExternalChange()
        }
    }

    private func pushLocalChanges() {
        guard !isApplyingExternalChange else { return }
        for key in keys {
            let localValue = defaults.object(forKey: key)
            guard !isEqual(localValue, cloud.object(forKey: key)) else { continue }
            cloud.set(localValue, forKey: key)
        }
    }

    /// Both synced values bridge to `NSObject` (`Data`, `String`), and `isEqual` is what
    /// plist types compare by.
    private func isEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs as NSObject, rhs as NSObject):
            lhs.isEqual(rhs)
        default:
            false
        }
    }
}
