import AppIntents
import SwiftUI

/// Tells the system which entity a row on screen *is*.
///
/// **The fifth system beside the four `EntityIndexing.swift` names**, and the only
/// one that is about the moment rather than about an index. `appEntityIdentifier`
/// annotates a view with an `EntityIdentifier`, so when someone looks at the Moves
/// screen and says "play this one", the assistant has something to resolve "this
/// one" against — the row under their eyes rather than a name they had to say.
///
/// Nothing is drawn, so no reference image covers any of it; what a given phrase
/// resolves to is a device check.
///
/// **iOS 18.4 / macOS 15.4**, four tenths above this app's floor, which is why the
/// check lives here rather than at each call site: one `#available` in the target
/// that owns the entities, the same shape `ReachyChrome` uses for the design
/// system's own platform gates.
public extension View {
    /// - Parameters:
    ///   - type: The entity type the row stands for.
    ///   - id: That entity's identifier — `MoveEntity.id`, `SoundEntity.id`
    ///     (the filename), `RobotAppEntity.id` (the stable Hub id, never the entry
    ///     point) or `RobotEntity.id` (`RobotIdentity.deduplicationKey`).
    @ViewBuilder
    func reachyEntityIdentifier<Entity: AppEntity>(_ type: Entity.Type, id: Entity.ID) -> some View {
        if #available(iOS 18.4, macOS 15.4, *) {
            appEntityIdentifier(EntityIdentifier(for: type, identifier: id))
        } else {
            self
        }
    }
}
