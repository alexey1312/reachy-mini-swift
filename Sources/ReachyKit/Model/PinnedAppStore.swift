import Foundation
import ReachyJSON

/// The apps a reader put at the top of the store, per robot.
///
/// One `UserDefaults` value rather than a record per robot: a person owns a
/// handful of robots and pins a handful of apps, so the whole table is smaller
/// than the code that would page it.
public struct PinnedAppStore {
    static let key = "ReachyKit.pinnedApps"

    private let defaults: UserDefaults

    /// Injectable for the reason `MovePlaybackStore` is: `swift test --parallel`
    /// runs suites concurrently against one `UserDefaults` table, so a shared
    /// store makes one suite's writes another's reads.
    public init(defaults: UserDefaults = KnownRobots.defaults) {
        self.defaults = defaults
    }

    /// - Parameter robotID: `RobotIdentity.deduplicationKey` (rule 4 — never an address).
    public func pinned(for robotID: String) -> [String] {
        table()[robotID] ?? []
    }

    public func toggle(_ appID: String, for robotID: String) {
        var table = table()
        var apps = table[robotID] ?? []
        if let index = apps.firstIndex(of: appID) {
            apps.remove(at: index)
        } else {
            apps.append(appID)
        }
        table[robotID] = apps.isEmpty ? nil : apps
        guard let data = try? JSONCodec.stored.encode(table) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private func table() -> [String: [String]] {
        guard let data = defaults.data(forKey: Self.key),
              let table = try? JSONCodec.stored.decode([String: [String]].self, from: data)
        else { return [:] }
        return table
    }
}
