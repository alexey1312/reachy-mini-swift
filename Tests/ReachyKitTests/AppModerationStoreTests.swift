import Foundation
import ReachyJSON
@testable import ReachyKit
import Testing

@Suite("AppModerationStore")
struct AppModerationStoreTests {
    /// Its own suite name per test: `swift test --parallel` runs suites concurrently and
    /// `UserDefaults.standard` is one table shared by all of them.
    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "AppModerationStoreTests.\(UUID().uuidString)"))
    }

    @Test("a reader who has done nothing has hidden nobody and agreed to nothing")
    func startsEmpty() throws {
        let store = try AppModerationStore(defaults: makeDefaults())

        #expect(store.hiddenAuthors.isEmpty)
        #expect(!store.hasAcceptedNotice)
    }

    /// The order is the list's reading order, so the author hidden by mistake a
    /// moment ago is the last row rather than somewhere in a sorted list.
    @Test("hidden authors keep the order they were hidden in, once each")
    func keepsOrderOnce() throws {
        let store = try AppModerationStore(defaults: makeDefaults())
        store.hide("someone")
        store.hide("another")
        store.hide("someone")
        store.hide("")

        #expect(store.hiddenAuthors == ["someone", "another"])
    }

    @Test("a hidden author survives a second store over the same defaults")
    func hidingPersists() throws {
        let defaults = try makeDefaults()
        AppModerationStore(defaults: defaults).hide("someone")

        #expect(AppModerationStore(defaults: defaults).hiddenAuthors == ["someone"])
    }

    @Test("unhiding the last author removes the record rather than storing an empty list")
    func unhidingClears() throws {
        let defaults = try makeDefaults()
        let store = AppModerationStore(defaults: defaults)
        store.hide("someone")
        store.hide("another")

        store.unhide("someone")
        #expect(store.hiddenAuthors == ["another"])

        store.unhide("another")
        #expect(store.hiddenAuthors.isEmpty)
        #expect(defaults.object(forKey: AppModerationStore.hiddenAuthorsKey) == nil)
    }

    @Test("an agreement is remembered across stores")
    func agreementPersists() throws {
        let defaults = try makeDefaults()
        AppModerationStore(defaults: defaults).acceptNotice()

        #expect(AppModerationStore(defaults: defaults).hasAcceptedNotice)
    }

    /// The whole reason the record is a version and not a flag: a notice that comes
    /// to say something new — a web app being handed a token — is read again.
    @Test("an agreement to an older notice asks again")
    func olderAgreementAsksAgain() throws {
        let defaults = try makeDefaults()
        defaults.set(AppModerationStore.noticeVersion - 1, forKey: AppModerationStore.noticeKey)
        #expect(!AppModerationStore(defaults: defaults).hasAcceptedNotice)

        defaults.set(AppModerationStore.noticeVersion, forKey: AppModerationStore.noticeKey)
        #expect(AppModerationStore(defaults: defaults).hasAcceptedNotice)
    }
}

@Suite("HubSpacePage")
struct HubSpacePageTests {
    @Test("a store card links to its Space and to the Hub's report form for it")
    func storeCardLinks() {
        let app = RobotApp.preview(name: "chess-coach", author: "someone")

        #expect(app.spaceURL?.absoluteString == "https://huggingface.co/spaces/someone/chess-coach")
        #expect(app.reportURL?.absoluteString == "https://huggingface.co/spaces/someone/chess-coach?report=true")
    }

    /// An installed app whose metadata the daemon lost carries only its entry
    /// point. A link guessed from that would point at somebody else's Space.
    @Test("an app with no Space id links nowhere")
    func noSpaceNoLinks() throws {
        let app = try JSONCodec.daemon.decode(
            RobotApp.self,
            from: Data(#"{"name": "reachy_mini_dance", "source_kind": "installed", "extra": {}}"#.utf8)
        )

        #expect(app.spaceID == nil)
        #expect(app.spaceURL == nil)
        #expect(app.reportURL == nil)
    }

    @Test("the web catalogue builds the same two links")
    func webAppsAgree() {
        let app = JSApp(id: "someone/chess-coach", title: "Chess Coach")

        #expect(app.cardURL == RobotApp.preview(name: "chess-coach", author: "someone").spaceURL)
        #expect(app.reportURL == RobotApp.preview(name: "chess-coach", author: "someone").reportURL)
    }
}
