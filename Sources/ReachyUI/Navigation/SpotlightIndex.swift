import CoreSpotlight
import Foundation
import OSLog
import ReachyDesign
import ReachyKit
import UniformTypeIdentifiers

/// The app's own rows in Spotlight.
///
/// **A third system, not either of the two next to it.** App Shortcuts
/// (`ReachyShortcuts`, in the app target) put *commands* in Spotlight and run them
/// headless; `ReachyQuickAction` fills the Home Screen icon's menu. This puts
/// *destinations* there — rows the index can match against words the app's name
/// does not contain, each opening the app where the row says.
///
/// It exists because Spotlight matches an installed app on its display name and
/// nothing else, and this app's name is two words, one of which is "Hey" — a token
/// so common in mail, messages and contacts that the app is ranked under all of
/// them. A searchable item is the only supported way to hand the index more words
/// than the name has.
///
/// **What it cannot do is change how the system _matches_.** Query length,
/// tokenization and ranking are iOS's, and no key here overrides any of them; a
/// short or very common query can still come back without the app in it. Read this
/// as widening what is findable, never as a fix for one particular query.
enum ReachySpotlightIndex {
    /// One row per destination, so a result opens where its words promised rather
    /// than at whichever tab the app was last left on.
    ///
    /// A plain value with no `CoreSpotlight` in it, because that is the half worth
    /// asserting on: `CSSearchableItem` cannot be read back out of the index by any
    /// API, so a test that built one could only inspect what it had just written.
    struct Entry: Equatable {
        let link: ReachyDeepLink
        let title: String
        let description: String
        let keywords: [String]
    }

    /// The brand, read from the running bundle rather than written down here.
    ///
    /// The single spelling is `CFBundleDisplayName` in `Apps/Project.swift`; a copy
    /// in this file would be a second answer to "what is this app called" that can
    /// go stale, which is the drift `ThemeIconNameTests` exists to catch elsewhere.
    /// `CFBundleName` is the fallback because the widget extension declares only the
    /// display name and the app declares both.
    static var appName: String {
        let info = Bundle.main.infoDictionary
        let candidates = [info?["CFBundleDisplayName"] as? String, info?["CFBundleName"] as? String]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    /// The two destinations worth a row of their own. `.runningApp` is deliberately
    /// absent: it is a state the robot may or may not be in, and a Spotlight row
    /// promising an app that is not running is worse than no row.
    static func entries(appName: String) -> [Entry] {
        let words = keywords(appName: appName)
        return [
            Entry(
                link: .robot,
                title: appName,
                description: String(
                    localized: .reachy("Connect to your Reachy Mini, wake it and see what it is doing.")
                ),
                keywords: words
            ),
            Entry(
                link: .apps,
                title: String(localized: .reachy("Robot apps")),
                description: String(
                    localized: .reachy("Start and stop the apps installed on your Reachy Mini.")
                ),
                keywords: words
            ),
        ]
    }

    /// Every word a reader might reach for, in one list.
    ///
    /// The brand half is *derived* from the name — the whole of it, then each word
    /// of it — so "Hey" is in the index as a term in its own right rather than only
    /// as the first half of something. The descriptive half is one comma-separated
    /// catalogue string rather than four keys: a translator replaces that list
    /// wholesale, because the words somebody would type are not a translation of
    /// these words and there are not necessarily four of them.
    ///
    /// Deduplicated case-insensitively while keeping the order, so a one-word app
    /// name does not put the same token in twice.
    static func keywords(appName: String) -> [String] {
        let brand = [appName] + appName.split(whereSeparator: \.isWhitespace).map(String.init)
        let described = String(localized: .reachy("robot, remote control, Reachy Mini, Pollen"))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var seen = Set<String>()
        return (brand + described).filter { word in
            !word.isEmpty && seen.insert(word.lowercased()).inserted
        }
    }

    /// Writes the rows, unless the same ones are already there.
    ///
    /// The marker is about not writing to the system index on every launch, not
    /// about correctness — indexing the same identifiers again is a replace. It
    /// carries the language as well as the build, because the titles, the
    /// descriptions and half the keywords come out of the catalogue: a reader who
    /// switches the phone's language must not keep the old ones.
    ///
    /// **`@MainActor` here and nowhere else in this file, and the reason is
    /// `UserDefaults`.** It is not `Sendable` — `KnownRobots.defaults` needs
    /// `nonisolated(unsafe)` to be a static at all — so a `nonisolated` function
    /// taking one would be handed it across an isolation boundary by the only
    /// caller, which is a `@MainActor` `.task`. Pinning this half to the caller's
    /// actor means the only thing that crosses into `index(appName:)` is a `String`.
    @MainActor
    static func indexIfNeeded(defaults: UserDefaults = .standard) async {
        let name = appName
        guard !name.isEmpty else {
            log.error("no bundle name to index; leaving Spotlight alone")
            return
        }
        let stamp = [
            Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            Locale.preferredLanguages.first ?? "",
            name,
        ].joined(separator: "|")
        guard defaults.string(forKey: stampKey) != stamp else { return }
        guard await index(appName: name) else { return }
        defaults.set(stamp, forKey: stampKey)
    }

    /// `false` when the index refused the write, which is what keeps the stamp
    /// unset so the next launch tries again.
    ///
    /// Stays off the main actor, and the items are built and spent inside it: a
    /// `CSSearchableItem` is not `Sendable`, so an array assembled on one actor and
    /// awaited on another is the one shape this could not take.
    @discardableResult
    static func index(appName: String) async -> Bool {
        do {
            try await CSSearchableIndex.default().indexSearchableItems(
                entries(appName: appName).map(searchableItem(for:))
            )
            return true
        } catch {
            log.error("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The destination behind a tapped row, or `nil` for an activity that is not
    /// one of ours.
    ///
    /// The identifier *is* the deep link, so the row goes back through the same
    /// parsing `onOpenURL` uses and there is no second table mapping identifiers to
    /// places.
    static func destination(for activity: NSUserActivity) -> ReachyDeepLink? {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let url = URL(string: identifier)
        else { return nil }
        return ReachyDeepLink(url: url)
    }

    private static func searchableItem(for entry: Entry) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = entry.title
        attributes.displayName = entry.title
        attributes.contentDescription = entry.description
        attributes.keywords = entry.keywords
        // Two lists of the same words on purpose. Both are documented as search
        // input, they are matched by different machinery, and iOS 17/18 has been
        // reported to ignore `keywords` for content items — filling only one is
        // betting on which report is current.
        attributes.alternateNames = entry.keywords
        let item = CSSearchableItem(
            uniqueIdentifier: entry.link.url.absoluteString,
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
        // **Not decoration: the default is one month.** An item left to expire takes
        // the app back out of every search these words reach, and does it silently
        // and long after anybody would connect it to this file. Nothing here goes
        // out of date while the app is installed.
        item.expirationDate = .distantFuture
        return item
    }

    private static let domainIdentifier = "com.alexey1312.ReachyMini.destination"
    private static let stampKey = "reachy.spotlight.indexed"

    private static let log = Logger(
        subsystem: "com.alexey1312.ReachyMini",
        category: "SpotlightIndex"
    )
}
