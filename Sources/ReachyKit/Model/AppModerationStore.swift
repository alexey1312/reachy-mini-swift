import Foundation

/// What a reader decided about apps written by strangers, on this device: whose
/// apps to leave out, and which version of the notice about them they agreed to.
///
/// App Review guideline 1.2 asks three things of a store that lists other people's
/// work — a way to report it, a way to block its author, and an agreement before
/// any of it is shown (`docs/adr/0006-js-apps.md`, decision 4). Reporting needs no
/// state: it is the Hub's own form (`HubSpacePage.reportURL`). The other two live
/// here, under keys of their own beside `PinnedAppStore`'s.
///
/// **Not per robot**, unlike a pin. A pin says what one robot is for; an author the
/// reader would rather not see is a fact about the reader, and stays hidden on the
/// next robot too. **Not synced** either: the list never leaves the device, which
/// the privacy policy's "your preferences" already covers.
public struct AppModerationStore {
    /// The notice a reader has to have agreed to. Bump it when the notice comes to
    /// say something materially new — web apps receiving a Hugging Face token is
    /// the change already expected (ADR 0006) — so that an agreement to the older
    /// text asks again. A copy edit does not bump it.
    public static let noticeVersion = 1

    static let hiddenAuthorsKey = "ReachyKit.hiddenAppAuthors"
    static let noticeKey = "ReachyKit.communityAppsNoticeVersion"

    private let defaults: UserDefaults

    /// Injectable for the reason `PinnedAppStore` is: `swift test --parallel` runs
    /// suites concurrently against one `UserDefaults` table.
    public init(defaults: UserDefaults = KnownRobots.defaults) {
        self.defaults = defaults
    }

    /// Hub user names, in the order they were hidden — which is the order the list
    /// of them reads in, so the one hidden by mistake a moment ago is at the end.
    public var hiddenAuthors: [String] {
        defaults.stringArray(forKey: Self.hiddenAuthorsKey) ?? []
    }

    public func hide(_ author: String) {
        var authors = hiddenAuthors
        guard !author.isEmpty, !authors.contains(author) else { return }
        authors.append(author)
        defaults.set(authors, forKey: Self.hiddenAuthorsKey)
    }

    public func unhide(_ author: String) {
        let authors = hiddenAuthors.filter { $0 != author }
        defaults.set(authors.isEmpty ? nil : authors, forKey: Self.hiddenAuthorsKey)
    }

    /// Whether the agreement on record is to the notice as it reads today. A
    /// reader who never agreed reads as version 0, which is older than any notice.
    public var hasAcceptedNotice: Bool {
        defaults.integer(forKey: Self.noticeKey) >= Self.noticeVersion
    }

    public func acceptNotice() {
        defaults.set(Self.noticeVersion, forKey: Self.noticeKey)
    }
}
