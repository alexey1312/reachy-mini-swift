import AppIntents
import Foundation
import ReachyKit

/// Where an entity lives inside the app, as a URL.
///
/// **This is what `EntityIndexing.swift` cannot do.** That file hands Spotlight the
/// words an entity is found by; this one answers what happens when the row is
/// tapped. Without it a tapped app row opens the app onto whichever tab it was
/// left on, because `ReachySpotlightIndex.destination(for:)` reads an identifier as
/// a `ReachyDeepLink` and an entity's is not one.
///
/// It is also the whole implementation of an `OpenIntent`. `AppIntents` supplies
///
/// ```swift
/// extension URLRepresentableIntent where Self: OpenIntent, Self.Value: URLRepresentableEntity {
///     public func perform() async throws -> Never
/// }
/// ```
///
/// so an intent that opens one of these entities writes no `perform()` at all: the
/// system opens the URL below and it arrives on the `onOpenURL` →
/// `ReachyDeepLink.Target` → `RootLifecycle.follow` path the app already has.
///
/// `URLRepresentableEntity` is iOS 18 / macOS 15, this app's floor exactly, so
/// nothing here needs an availability guard — the same note `IndexedEntity` carries.
///
/// **The template is a literal, and it has to be.** `EntityURLRepresentation`'s
/// interpolation accepts only its own `Token` and key paths to `EntityProperty`,
/// never a `String`, so the scheme, the host and the query name cannot be read off
/// `ReachyDeepLink` here. They are a second copy, and `EntityURLTests` is what keeps
/// the two in step — the same trade `ThemeIconNameTests` makes for the icon names.
extension RobotAppEntity: URLRepresentableEntity {
    public static var urlRepresentation: EntityURLRepresentation<RobotAppEntity> {
        "reachy-mini-swift://apps?id=\(.id)"
    }
}
