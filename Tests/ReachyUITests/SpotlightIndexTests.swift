import CoreSpotlight
import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// The index is written and never read back — no API hands a `CSSearchableItem`
/// returned, so the only way this can be wrong on a device is silently. What is
/// assertable is the part that decides what gets written and where a tap lands, and
/// that is the part that carries the whole point of the feature: the app's name is
/// two words, and "Hey" being one of them in its own right is the reason any of
/// this exists.
@Suite("Spotlight index")
struct SpotlightIndexTests {
    @Test("every word of the app's name is a keyword of its own")
    func indexesEachWordOfTheName() {
        let words = ReachySpotlightIndex.keywords(appName: "Hey Reachy")

        #expect(words.contains("Hey"))
        #expect(words.contains("Reachy"))
        #expect(words.contains("Hey Reachy"))
    }

    /// A one-word name makes the whole name and its only word the same string, and
    /// the same token twice is a keyword list that says less than it looks like.
    @Test("the same word is not indexed twice")
    func deduplicatesKeywords() {
        let words = ReachySpotlightIndex.keywords(appName: "Reachy")

        #expect(words.filter { $0.caseInsensitiveCompare("Reachy") == .orderedSame }.count == 1)
    }

    /// The descriptive half arrives as one comma-separated catalogue string, so the
    /// space after each comma is part of the source and would be indexed with it.
    @Test("no keyword carries the separator's whitespace")
    func trimsTheDescriptiveList() {
        let words = ReachySpotlightIndex.keywords(appName: "Hey Reachy")

        let untrimmed = words.map { $0 != $0.trimmingCharacters(in: .whitespaces) }
        #expect(untrimmed.contains(true) == false)
        #expect(words.map(\.isEmpty).contains(true) == false)
    }

    /// The identifier is the routing table. A row whose identifier does not parse
    /// back opens the app at whatever tab it was left on, which reads as the search
    /// result having been ignored.
    @Test("every row's identifier parses back to the destination it promises")
    func identifiersRoundTrip() {
        for entry in ReachySpotlightIndex.entries(appName: "Hey Reachy") {
            let identifier = entry.link.url.absoluteString
            let parsed = ReachySpotlightIndex.destination(for: searchActivity(identifier: identifier))

            #expect(parsed == entry.link, "\(identifier) did not parse back to \(entry.link)")
        }
    }

    @Test("a row is titled and described")
    func everyRowCarriesWords() {
        let entries = ReachySpotlightIndex.entries(appName: "Hey Reachy")

        #expect(entries.isEmpty == false)
        #expect(entries.map(\.title.isEmpty).contains(true) == false)
        #expect(entries.map(\.description.isEmpty).contains(true) == false)
        #expect(entries.map(\.keywords.isEmpty).contains(true) == false)
    }

    /// `.runningApp` is a state the robot may not be in. A row for it would promise
    /// an app that is not running, which is worse than the app not being found.
    @Test("only stable destinations get a row")
    func indexesNoTransientDestination() {
        let links = ReachySpotlightIndex.entries(appName: "Hey Reachy").map(\.link)

        #expect(links.contains(.runningApp) == false)
        #expect(Set(links).count == links.count)
    }

    @Test("an activity this app did not file is refused")
    func refusesAForeignActivity() {
        let foreignType = NSUserActivity(activityType: "com.example.other")
        foreignType.userInfo = [CSSearchableItemActivityIdentifier: ReachyDeepLink.robot.url.absoluteString]

        #expect(ReachySpotlightIndex.destination(for: foreignType) == nil)
        #expect(ReachySpotlightIndex.destination(for: searchActivity(identifier: "https://example.com")) == nil)
        #expect(ReachySpotlightIndex.destination(for: NSUserActivity(activityType: CSSearchableItemActionType)) == nil)
    }

    private func searchActivity(identifier: String) -> NSUserActivity {
        let activity = NSUserActivity(activityType: CSSearchableItemActionType)
        activity.userInfo = [CSSearchableItemActivityIdentifier: identifier]
        return activity
    }
}
