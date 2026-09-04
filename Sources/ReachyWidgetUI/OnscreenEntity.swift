import AppIntents
import SwiftUI

public extension View {
    /// Tells the system which entity this screen is *about*, so a request made while
    /// looking at it resolves against what is on screen.
    ///
    /// Onscreen awareness: "start this one" said in front of an app's page means that
    /// app, without the reader naming it and without a picker. What it costs is one
    /// modifier per screen that is genuinely about a single entity, and the honest
    /// limit is exactly that — a list is not about one thing, and marking it with the
    /// row somebody happened to scroll past would make the assistant confidently
    /// wrong. `appEntityIdentifier(forSelectionType:identifier:)` is the shape for a
    /// list, and it needs a selection this app's catalogues do not have.
    ///
    /// **The availability here is two different things and it reads as one.** The
    /// runtime floor is iOS 18.4 / macOS 15.4, which is *above* this app's deployment
    /// target by a point release — hence the `#available`. The *declaration* ships
    /// only in the 27 SDK, which is what kept this out of the tree until `lint-test`
    /// moved off Xcode 26.2 (#124): `_AppIntents_SwiftUI`'s interface in
    /// `MacOSX26.5.sdk` does not contain the name at all. So an `@available`
    /// annotation was never going to save it, and `#if canImport` cannot see it
    /// either — the overlay module exists in both SDKs and only the member is
    /// missing.
    ///
    /// Here rather than in `ReachyUI` because the entities are here, and both
    /// surfaces may come to want it. Nil is passed through rather than skipped: it is
    /// how the system is told this screen has stopped being about anything.
    @ViewBuilder
    func onscreenEntity(_ identifier: EntityIdentifier?) -> some View {
        if #available(iOS 18.4, macOS 15.4, watchOS 11.4, tvOS 18.4, visionOS 2.4, *) {
            appEntityIdentifier(identifier)
        } else {
            self
        }
    }
}
