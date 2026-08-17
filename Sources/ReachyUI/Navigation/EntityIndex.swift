import AppIntents
import CoreSpotlight
import CryptoKit
import Foundation
import OSLog
import ReachyKit
import ReachyWidgetUI

/// The robot's apps and moves, in Spotlight as entities rather than as rows.
///
/// **Its neighbour files destinations; this files things.** `ReachySpotlightIndex`
/// exists because Spotlight matches an installed app on its display name alone, and
/// it hands the index two rows that open two tabs. An indexed `AppEntity` is a
/// different kind of result: it carries its type, so Spotlight can offer the intents
/// that take that type — searching for a dance offers to *play* it, searching for an
/// app offers to *start* it. That is the whole of what issue #67 asked for, and it
/// is why this is `IndexedEntity` rather than a second table of hand-rolled deep
/// links.
///
/// **Never the network.** All three lists come out of what the entity queries already
/// read: `RobotAppsCacheStore` for installed apps, `MoveEntityQuery` for moves, and
/// `SoundEntityQuery` for sounds — the last of which is not a cache at all but this
/// device's own library, so it is the one list that is never empty for want of a warm
/// connection. `RobotAppQuery.suggestedEntities()` is deliberately *not* used — it
/// carries a 2 s live refresh that this has no use for, and it *writes* the cache.
/// `MoveEntityQuery` is safe to call because it is documented as reading only: a
/// second writer stamping `Date()` would re-date every library the app had merely
/// read off disk, and the move index would then never expire.
/// **`@MainActor` on `indexIfNeeded` and nowhere else**, which is the split
/// `ReachySpotlightIndex` already makes and for the same reason: `UserDefaults` is
/// not `Sendable` (`KnownRobots.defaults` needs `nonisolated(unsafe)` to be a static
/// at all), so the stamp read and write stay on the caller's actor and only
/// `Sendable` values — a `String`, two arrays of entities — cross out of it.
enum ReachyEntityIndex {
    /// Writes both types, unless what is on disk is already what was written last
    /// time.
    ///
    /// The stamp is over the *content*, not over the build: unlike the two
    /// destination rows next door, this list changes while the app is installed —
    /// every install, removal and `reset-apps` moves it. It carries the language for
    /// the same reason `ReachySpotlightIndex.indexIfNeeded` does, because the
    /// descriptions and half the keywords come out of the catalogue.
    ///
    /// A `nil` robot is a session that has let its robot go. Nothing is deleted for
    /// it: the entities stay findable, the same way `RobotAppsCacheStore.clear` is
    /// deliberately not called on disconnect. What a *changed* robot does is
    /// replace them, because the stamp includes its identity.
    @MainActor
    static func indexIfNeeded(robotID: String?, defaults: UserDefaults = .standard) async {
        guard let robotID else { return }
        let apps = installedApps(for: robotID)
        let moves = await (try? MoveEntityQuery().suggestedEntities()) ?? []
        let sounds = await (try? SoundEntityQuery().suggestedEntities()) ?? []
        // Nothing to say is not the same as "index an empty list": a cold launch
        // before the catalogues have been warmed would otherwise delete every row
        // and stamp itself as done.
        guard !apps.isEmpty || !moves.isEmpty || !sounds.isEmpty else { return }

        // Named `current` rather than `stamp`: a local `let stamp = stamp(…)`
        // shadows the static it is calling.
        let current = stamp(robotID: robotID, apps: apps, moves: moves, sounds: sounds)
        guard defaults.string(forKey: stampKey) != current else { return }
        guard await index(apps: apps, moves: moves, sounds: sounds) else { return }
        defaults.set(current, forKey: stampKey)
    }

    /// `false` when the index refused a write, which is what leaves the stamp unset
    /// so the next launch tries again.
    ///
    /// **Deletion is by entity type and never `deleteAllSearchableItems()`.**
    /// `ReachySpotlightIndex` files its two destination rows into this same default
    /// index, and a blanket delete would take them with it — silently, and long
    /// after anybody would connect the two files. Deleting first is what retires an
    /// app that has been removed from the robot; re-indexing an identifier that is
    /// still there is a replace, so the rest costs nothing.
    ///
    /// A failure between the delete and the write leaves nothing indexed and the
    /// stamp unset, so the next launch repairs it. That is the safe end of the
    /// mistake: the alternative is stale rows promising an app the robot no longer
    /// has.
    /// `sounds` is defaulted so the two-list call sites in the tests still read as
    /// statements about apps and moves.
    @discardableResult
    static func index(
        apps: [RobotAppEntity],
        moves: [MoveEntity],
        sounds: [SoundEntity] = []
    ) async -> Bool {
        do {
            let spotlight = CSSearchableIndex.default()
            try await spotlight.deleteAppEntities(ofType: RobotAppEntity.self)
            try await spotlight.deleteAppEntities(ofType: MoveEntity.self)
            try await spotlight.deleteAppEntities(ofType: SoundEntity.self)
            try await spotlight.indexAppEntities(apps)
            try await spotlight.indexAppEntities(moves)
            try await spotlight.indexAppEntities(sounds)
            return true
        } catch {
            log.error("entity indexing failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Only what the robot actually has. The catalogue holds hundreds of apps
    /// nobody has installed, and a Spotlight row offering to start one of those
    /// would be a row that cannot do what it promises — the same reason
    /// `ReachySpotlightIndex` leaves `.runningApp` out.
    static func installedApps(for robotID: String) -> [RobotAppEntity] {
        let cache = RobotAppsCacheStore().current(for: robotID)
        return (cache?.installed ?? []).map { RobotAppEntity($0, isInstalled: true) }
    }

    /// A digest rather than the list itself, because a robot with four hundred apps
    /// would otherwise put a few kilobytes of identifiers in `UserDefaults` on every
    /// launch.
    ///
    /// **SHA-256 rather than `hashValue`.** Swift seeds `Hasher` per process, so a
    /// stored `hashValue` compares unequal on the next launch and this would
    /// re-index every time — the exact failure the stamp exists to prevent, and one
    /// that would never show up as anything but battery. The idiom is
    /// `RobotCatalogueCache`'s.
    static func stamp(
        robotID: String,
        apps: [RobotAppEntity],
        moves: [MoveEntity],
        sounds: [SoundEntity] = []
    ) -> String {
        let identifiers = [robotID, Locale.preferredLanguages.first ?? ""]
            + apps.map(\.id).sorted()
            + moves.map(\.id).sorted()
            + sounds.map(\.id).sorted()
        let digest = SHA256.hash(data: Data(identifiers.joined(separator: "\u{1}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let stampKey = "reachy.spotlight.entities"

    private static let log = Logger(
        subsystem: "com.alexey1312.ReachyMini",
        category: "EntityIndex"
    )
}
