import Foundation

/// Persistence for the robots this app has connected to.
/// Manual reconnection to a known address is a first-class flow (issue #269).
public enum KnownRobots {
    static let onboardingKey = "ReachyKit.hasCompletedOnboarding"
    static let provisionedKey = "ReachyKit.pendingProvisionedHardwareID"
    /// Set on the destination, so the copy happens once and the shared suite is
    /// the truth from then on.
    static let migratedKey = "ReachyKit.migratedToAppGroup"

    /// Everything this app persists, in the order it was added. Migration copies
    /// the lot rather than picking: a key left behind is a setting that silently
    /// resets on update.
    static let persistedKeys = [
        KnownRobotStore.knownRobotsKey,
        KnownRobotStore.lastAddressKey,
        onboardingKey,
        provisionedKey,
    ]

    /// Carries an existing installation into the shared suite the first time this
    /// app runs with an app group.
    ///
    /// Copied rather than moved: a user who downgrades still has their robots, and
    /// there is nothing to gain from destroying the originals. Runs once — by the
    /// second launch the shared suite is authoritative, and copying again would
    /// resurrect robots the user has since removed.
    static func migrate(from legacy: UserDefaults, to shared: UserDefaults) {
        guard !shared.bool(forKey: migratedKey) else { return }
        for key in persistedKeys {
            guard let value = legacy.object(forKey: key) else { continue }
            shared.set(value, forKey: key)
        }
        shared.set(true, forKey: migratedKey)
    }

    /// The Info.plist key naming the app group, declared by the app and by every
    /// extension that shares its storage.
    static let appGroupInfoKey = "ReachyAppGroupIdentifier"

    /// The group this process may share, or `nil` where none is entitled: a fork
    /// without the entitlement, and every unit test.
    ///
    /// Read by `defaults` for the shared suite and by `RobotCatalogueCache` for the
    /// shared container — two different kinds of storage behind one answer, so a
    /// bundle that names no group degrades both the same way.
    static var appGroupIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: appGroupInfoKey) as? String
    }

    /// The defaults every part of this app shares — including the widget
    /// extension, which is its own process and cannot see the app's container.
    ///
    /// Named by the bundle rather than compiled in: this is a library, and one
    /// developer account's group identifier has no business being hard-coded in
    /// it. Absent — a fork without the entitlement, or any unit test — the app
    /// keeps working on its own storage instead of losing every setting.
    ///
    /// Migration runs here because this is the first thing to touch the group,
    /// and it must happen before anything reads it.
    /// `nonisolated(unsafe)` because `UserDefaults` is thread-safe but not marked
    /// `Sendable` — the annotation states what Apple documents, rather than
    /// waiving a real risk. The initialiser runs once, before any reader.
    public nonisolated(unsafe) static let defaults: UserDefaults = {
        guard let group = appGroupIdentifier,
              let shared = UserDefaults(suiteName: group)
        else { return .standard }
        migrate(from: .standard, to: shared)
        return shared
    }()

    public static var store: KnownRobotStore {
        KnownRobotStore(defaults: defaults)
    }

    /// Robots seen through a completed handshake, most recent first.
    public static var all: [KnownRobot] {
        store.all
    }

    /// The address to offer first: what the manual field shows and what the candidate
    /// sweep tries before anything else. Identity-keyed records live in `all`.
    public static var lastAddress: RobotAddress? {
        get { store.lastAddress }
        set { store.lastAddress = newValue }
    }

    public static func remember(identity: RobotIdentity, address: RobotAddress, at date: Date = Date()) {
        store.remember(identity: identity, address: address, at: date)
    }

    public static func forget(_ key: String) {
        store.forget(key)
    }

    /// Whether the first-run flow has already run. It only stops onboarding from opening
    /// itself a second time — the flow is never a gate, and stays reachable by hand.
    public static var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: onboardingKey) }
        set { defaults.set(newValue, forKey: onboardingKey) }
    }

    /// A robot just given a Wi-Fi password over Bluetooth, waiting to be recognised once
    /// it appears on the network.
    ///
    /// The hardware id rather than the address, because the address is exactly what
    /// changes: the robot is provisioned on its own hotspot and comes back on the home
    /// network at whatever DHCP hands out (rule 4).
    public static var pendingProvisionedHardwareID: String? {
        get { defaults.string(forKey: provisionedKey) }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: provisionedKey)
                return
            }
            defaults.set(newValue, forKey: provisionedKey)
        }
    }
}
