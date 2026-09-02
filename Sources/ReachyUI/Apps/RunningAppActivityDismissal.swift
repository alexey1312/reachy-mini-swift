import Foundation
import ReachyJSON
import ReachyKit

/// Which runs the reader has already waved away, so the next foreground pass does
/// not put them back.
///
/// **The one piece of durable state this feature adds, and it exists because of a
/// hole nothing else can cover.** A swipe ends the activity without stopping
/// anything, which is correct — removing a card does not cancel what it was about.
/// But the reconciliation pass then sees a running app and no card and would start a
/// fresh one, so the reader would have to dismiss the same card for as long as their
/// robot went on dancing. `RunningAppModel.Dismissal` solves the same problem for the
/// dock's failure row, keyed the same way.
///
/// It is written and read only by the app: the widget extension has no activity to
/// dismiss. It lives in the App Group suite anyway, beside `RobotAppLaunchStateStore`
/// and `RobotPowerTransitionStore` — the same storage every other cross-process fact
/// about an app uses, and the same storage the tile's own start path would reach if
/// it ever needs to consult this.
struct RunningAppActivityDismissalStore {
    static let key = "ReachyUI.activityDismissals"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = KnownRobots.defaults) {
        self.defaults = defaults
    }

    /// Run keys still suppressed at `date`.
    ///
    /// **Entries expire**, and the window is `RobotSnapshotStore.freshness` rather
    /// than a number of its own: past half an hour nothing else in this app believes
    /// the reading the dismissal was about either. Without expiry, an app stopped and
    /// restarted while this process was closed — an edge nobody observed, so nothing
    /// cleared the key — would be suppressed for ever.
    func current(at date: Date = Date()) -> Set<String> {
        Set(stored().filter { date.timeIntervalSince($0.value) <= RobotSnapshotStore.freshness }.keys)
    }

    func remember(_ runKey: String, at date: Date = Date()) {
        var entries = stored()
        entries[runKey] = date
        write(entries)
    }

    /// The run is over, so a later one is news again.
    func forget(_ runKey: String) {
        var entries = stored()
        guard entries.removeValue(forKey: runKey) != nil else { return }
        write(entries)
    }

    private func stored() -> [String: Date] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONCodec.stored.decode([String: Date].self, from: data)) ?? [:]
    }

    private func write(_ entries: [String: Date]) {
        guard let data = try? JSONCodec.stored.encode(entries) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
