import Foundation
@testable import ReachyKit
import Testing

/// The scheme is shared with the OAuth callback, so parsing has to be exact:
/// anything it does not recognise belongs to somebody else.
@Suite("Deep links")
struct ReachyDeepLinkTests {
    @Test("a link round-trips through its URL")
    func roundTrips() {
        for link in ReachyDeepLink.allCases {
            #expect(ReachyDeepLink(url: link.url) == link)
        }
    }

    @Test("the robot link names the app's own scheme")
    func usesTheAppScheme() {
        #expect(ReachyDeepLink.robot.url.scheme == "reachy-mini-swift")
    }

    /// The destination is a URL *host*, which is case-insensitive and normalised as
    /// such — so a raw value carrying case would not survive the round trip above.
    @Test("no destination depends on its case surviving a URL")
    func namesDestinationsInLowercase() {
        for link in ReachyDeepLink.allCases {
            #expect(link.rawValue == link.rawValue.lowercased())
        }
    }

    @Test("the running app has a destination of its own")
    func addressesTheRunningApp() throws {
        let url = try #require(URL(string: "reachy-mini-swift://running-app"))

        #expect(ReachyDeepLink(url: url) == .runningApp)
    }

    /// `ASWebAuthenticationSession` claims the callback while a sign-in is running,
    /// but the app must not mistake one for a destination if it ever arrives here.
    @Test("the OAuth callback is not a destination")
    func ignoresTheOAuthCallback() throws {
        let callback = try #require(URL(string: "reachy-mini-swift://oauth-callback?code=abc"))

        #expect(ReachyDeepLink(url: callback) == nil)
    }

    @Test("another app's scheme is not ours")
    func ignoresAForeignScheme() throws {
        let foreign = try #require(URL(string: "reachy-mini://robot"))

        #expect(ReachyDeepLink(url: foreign) == nil)
    }

    @Test("an unknown destination in our own scheme is refused rather than guessed")
    func refusesAnUnknownDestination() throws {
        let unknown = try #require(URL(string: "reachy-mini-swift://telemetry"))

        #expect(ReachyDeepLink(url: unknown) == nil)
    }
}

/// The identifier is what an `OpenIntent` puts in a destination's URL, so it has to
/// survive a round trip through `URLComponents` and has to be *optional* at every
/// reader that predates it.
@Suite("Deep link targets")
struct ReachyDeepLinkTargetTests {
    @Test("a target round-trips through its URL")
    func roundTrips() {
        for destination in ReachyDeepLink.allCases {
            let target = ReachyDeepLink.Target(destination: destination, identifier: "pollen/happy-dance")

            #expect(ReachyDeepLink.Target(url: target.url) == target)
        }
    }

    /// Move ids are `owner/name` and an app's is a Hub slug, so the one character
    /// certain to appear is the one a URL path would have swallowed — which is why
    /// the identifier is a query item.
    @Test("an identifier carrying a slash survives percent-encoding")
    func carriesASlash() throws {
        let target = ReachyDeepLink.Target(destination: .apps, identifier: "pollen/reachy-mini-conversation")

        let parsed = try #require(ReachyDeepLink.Target(url: target.url))

        #expect(parsed.identifier == "pollen/reachy-mini-conversation")
    }

    /// Every caller that predates the identifier reads `ReachyDeepLink`, so a URL
    /// carrying one must still land on the tab rather than be refused.
    @Test("a link carrying an identifier still parses as its bare destination")
    func staysReadableWithoutTheIdentifier() {
        let url = ReachyDeepLink.apps.url(identifier: "pollen/happy-dance")

        #expect(ReachyDeepLink(url: url) == .apps)
    }

    @Test("a destination with no identifier builds the URL it always did")
    func leavesTheBareURLAlone() {
        #expect(ReachyDeepLink.robot.url(identifier: nil) == ReachyDeepLink.robot.url)
        #expect(ReachyDeepLink.robot.url.query() == nil)
    }

    /// An empty query item is not an identifier, and normalising it here is what
    /// keeps two targets that mean the same thing compare equal.
    @Test("an empty identifier is no identifier")
    func refusesAnEmptyIdentifier() throws {
        let url = try #require(URL(string: "reachy-mini-swift://apps?id="))

        #expect(ReachyDeepLink.Target(url: url)?.identifier == nil)
        #expect(ReachyDeepLink.Target(destination: .apps, identifier: "").identifier == nil)
    }

    @Test("a query item nobody declared is not an identifier")
    func ignoresAnUnknownQueryItem() throws {
        let url = try #require(URL(string: "reachy-mini-swift://apps?name=happy-dance"))

        #expect(ReachyDeepLink.Target(url: url) == ReachyDeepLink.Target(destination: .apps))
    }

    /// The same exactness the enum has: a target is refused for a foreign scheme,
    /// an unknown host, and the sign-in callback that shares this scheme.
    @Test("a target refuses everything the destination refuses")
    func refusesWhatTheDestinationRefuses() throws {
        let callback = try #require(URL(string: "reachy-mini-swift://oauth-callback?code=abc"))
        let foreign = try #require(URL(string: "reachy-mini://robot"))
        let unknown = try #require(URL(string: "reachy-mini-swift://telemetry?id=1"))

        #expect(ReachyDeepLink.Target(url: callback) == nil)
        #expect(ReachyDeepLink.Target(url: foreign) == nil)
        #expect(ReachyDeepLink.Target(url: unknown) == nil)
    }
}
