import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

@MainActor
@Suite("App moderation", .timeLimit(.minutes(1)))
struct AppModerationTests {
    /// Its own suite name per test: `swift test --parallel` shares one `UserDefaults` table.
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "AppModerationTests.\(UUID().uuidString)"))
    }

    private func moderation(_ defaults: UserDefaults) -> AppModeration {
        AppModeration(store: AppModerationStore(defaults: defaults))
    }

    /// `StoreRobotClient`'s store: Dance Party by pollen-robotics and Chess Coach by
    /// someone in Discover, and one installed app with no card at all.
    private func loaded(_ moderation: AppModeration) async throws -> AppStoreModel {
        let session = RobotSession { _ in StoreRobotClient() }
        #expect(await session.connect(to: .init(host: "127.0.0.1")))
        let pins = try PinnedAppStore(defaults: defaults())
        let model = AppStoreModel(session: session, pins: pins, moderation: moderation)
        await model.load(session: session)
        model.section = .discover
        return model
    }

    private func chess(in model: AppStoreModel) throws -> RobotApp {
        try #require(model.catalogue.first { $0.title == "Chess Coach" })
    }

    @Test("hiding an author takes their apps out of Discover, and says so")
    func hidingLeavesDiscover() async throws {
        let moderation = try moderation(defaults())
        moderation.acceptNotice()
        let model = try await loaded(moderation)
        #expect(!model.hidesSomeOfDiscover)

        try moderation.hideAuthor(of: chess(in: model))

        #expect(model.visibleApps.map(\.title) == ["Dance Party"])
        #expect(moderation.hiddenAuthors == ["someone"])
        #expect(model.hidesSomeOfDiscover)
    }

    @Test("unhiding brings them back")
    func unhidingReturns() async throws {
        let moderation = try moderation(defaults())
        moderation.acceptNotice()
        let model = try await loaded(moderation)
        try moderation.hideAuthor(of: chess(in: model))

        moderation.unhide(author: "someone")

        #expect(model.visibleApps.map(\.title).contains("Chess Coach"))
        #expect(!model.hidesSomeOfDiscover)
    }

    /// Hiding there would leave an app on the robot with no page left to stop or
    /// remove it from.
    @Test("Installed is not moderated, and an installed row offers no hide")
    func installedIsUntouched() async throws {
        let moderation = try moderation(defaults())
        let model = try await loaded(moderation)
        try moderation.hideAuthor(of: chess(in: model))
        model.section = .installed

        let installed = try #require(model.visibleApps.first)
        #expect(model.visibleApps.count == 1)
        #expect(!moderation.canHideAuthor(of: installed))
        #expect(!model.showsCommunityNotice)
        #expect(!model.hidesSomeOfDiscover)
    }

    /// The row says something true of Discover as a whole, so a search must not
    /// make it come and go with each keystroke.
    @Test("the hidden row stays through a search that matches none of the hidden apps")
    func hiddenRowIgnoresSearch() async throws {
        let moderation = try moderation(defaults())
        moderation.acceptNotice()
        let model = try await loaded(moderation)
        try moderation.hideAuthor(of: chess(in: model))

        model.searchText = "dance"

        #expect(model.hidesSomeOfDiscover)
    }

    @Test("the notice stands in front of Discover until it is agreed to, and only there")
    func noticeGatesDiscover() async throws {
        let defaults = try defaults()
        let moderation = moderation(defaults)
        let model = try await loaded(moderation)

        #expect(model.showsCommunityNotice)
        // The list is still the list; the screen is what keeps it off the page.
        #expect(!model.visibleApps.isEmpty)
        model.section = .installed
        #expect(!model.showsCommunityNotice)

        model.section = .discover
        moderation.acceptNotice()
        #expect(!model.showsCommunityNotice)
        #expect(self.moderation(defaults).hasAcceptedNotice)
    }

    /// The row is hidden behind the notice too, so it cannot be the first thing a
    /// reader who has agreed to nothing is told about.
    @Test("the hidden row waits for the notice")
    func hiddenRowWaitsForNotice() async throws {
        let moderation = try moderation(defaults())
        let model = try await loaded(moderation)
        try moderation.hideAuthor(of: chess(in: model))

        #expect(!model.hidesSomeOfDiscover)
    }

    /// The fixture's installed app has no card at all, so the test above would pass
    /// on the author alone. This one has an author and is still not a card.
    @Test("an installed app offers no hide even when it names an author")
    func installedWithAuthorNoHide() throws {
        let moderation = try moderation(defaults())
        let installed = RobotApp.preview(name: "chess", author: "someone", installed: true)

        #expect(!moderation.canHideAuthor(of: installed))
        moderation.hideAuthor(of: installed)
        #expect(moderation.hiddenAuthors.isEmpty)
    }

    @Test("an app the Hub gives no author offers no hide, and hiding it does nothing")
    func noAuthorNoHide() throws {
        let moderation = try moderation(defaults())
        let anonymous = RobotApp.preview(name: "mystery", author: nil)

        #expect(!moderation.canHideAuthor(of: anonymous))
        moderation.hideAuthor(of: anonymous)
        #expect(moderation.hiddenAuthors.isEmpty)
        #expect(!moderation.isHidden(anonymous))
    }

    /// A preview must render the state it was handed, whatever somebody hid on the
    /// simulator the suite runs on.
    @Test("a preview reads nothing the reader stored")
    func previewIgnoresStore() {
        let moderation = AppModeration.preview(noticeAccepted: false, hiddenAuthors: ["someone"])

        #expect(!moderation.hasAcceptedNotice)
        #expect(moderation.hiddenAuthors == ["someone"])
        #expect(AppModeration.preview().hasAcceptedNotice)
        #expect(AppModeration.preview().hiddenAuthors.isEmpty)
    }
}
