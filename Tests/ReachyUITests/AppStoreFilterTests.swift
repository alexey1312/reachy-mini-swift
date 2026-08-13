import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// The store's scope and sort. A list of its own rather than
/// `RobotApp.previewCatalogue`: that one is shaped for the reference images, where
/// author order happens to coincide with the daemon's, so a sort test built on it
/// could not tell the two apart.
@MainActor
@Suite("App store filters", .timeLimit(.minutes(1)))
struct AppStoreFilterTests {
    /// Deliberately jumbled: every ordering below differs from the order the apps
    /// are listed in, so an assertion that passes proves the sort ran.
    /// `Bravo` carries no author, no likes and no dates — the installed app whose
    /// metadata the daemon lost.
    private static let apps: [RobotApp] = [
        .preview(
            name: "delta",
            title: "Delta",
            likes: 5,
            publishedAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-05-01T00:00:00.000Z"
        ),
        .preview(
            name: "alpha",
            title: "Alpha",
            author: "zoe",
            likes: 90,
            publishedAt: "2025-01-01T00:00:00.000Z",
            updatedAt: "2026-08-01T00:00:00.000Z"
        ),
        .preview(
            name: "charlie",
            title: "Charlie",
            author: "amir",
            likes: 40,
            isPrivate: true,
            publishedAt: "2026-07-01T00:00:00.000Z",
            updatedAt: "2026-02-01T00:00:00.000Z"
        ),
        .preview(name: "bravo", title: "Bravo", author: nil, likes: nil),
    ]

    private func store(
        scope: AppStoreModel.Scope = .all,
        sort: AppStoreModel.Sort = .recommended,
        catalogue: [RobotApp] = AppStoreFilterTests.apps
    ) -> AppStoreModel {
        .preview(section: .discover, scope: scope, sort: sort, catalogue: catalogue, installed: [])
    }

    // MARK: - Scope

    @Test("the default scope hides nothing")
    func showsEverythingByDefault() {
        #expect(store().visibleApps.map(\.title) == ["Delta", "Alpha", "Charlie", "Bravo"])
    }

    @Test("official is decided by the author, the only signal a Space carries")
    func filtersToOfficial() {
        #expect(store(scope: .official).visibleApps.map(\.title) == ["Delta"])
    }

    /// Community is the complement of official rather than "neither official nor
    /// private", so `Charlie` answers both this and `.privateSpaces`. Partitioning
    /// them would hide a private community Space from a reader who asked for
    /// community apps.
    @Test("community is everything not from Pollen, private Spaces included")
    func filtersToCommunity() {
        #expect(store(scope: .community).visibleApps.map(\.title) == ["Alpha", "Charlie", "Bravo"])
    }

    @Test("private is its own question, overlapping the other two")
    func filtersToPrivate() {
        #expect(store(scope: .privateSpaces).visibleApps.map(\.title) == ["Charlie"])
    }

    @Test("an app with no author at all is community, not official")
    func unattributedIsNotOfficial() throws {
        let bravo = try #require(Self.apps.last)
        #expect(!bravo.isOfficial)
        #expect(AppStoreModel.Scope.community.admits(bravo))
    }

    @Test("the scope narrows the search rather than replacing it")
    func scopeAndSearchCompose() {
        let model = store(scope: .community)
        model.searchText = "alpha"

        #expect(model.visibleApps.map(\.title) == ["Alpha"])

        model.scope = .official
        #expect(model.visibleApps.isEmpty)
    }

    // MARK: - Sort

    /// The daemon puts the curated `app-list.json` entries first and nothing in the
    /// payload records that, so the default order is the one it sent.
    @Test("the default sort leaves the daemon's own order alone")
    func recommendedKeepsDaemonOrder() {
        #expect(store(sort: .recommended).visibleApps.map(\.title) == ["Delta", "Alpha", "Charlie", "Bravo"])
    }

    @Test("name sorts by the title a reader sees")
    func sortsByName() {
        #expect(store(sort: .name).visibleApps.map(\.title) == ["Alpha", "Bravo", "Charlie", "Delta"])
    }

    @Test("author sorts alphabetically and files the unattributed app last")
    func sortsByAuthor() {
        #expect(store(sort: .author).visibleApps.map(\.title) == ["Charlie", "Delta", "Alpha", "Bravo"])
    }

    @Test("likes run high to low, and an unknown count is not zero but last")
    func sortsByLikes() {
        #expect(store(sort: .likes).visibleApps.map(\.title) == ["Alpha", "Charlie", "Delta", "Bravo"])
    }

    @Test("newest reads the Space's creation date")
    func sortsByPublished() {
        #expect(store(sort: .published).visibleApps.map(\.title) == ["Charlie", "Delta", "Alpha", "Bravo"])
    }

    /// Different from `.published` on the same four apps, which is the point: a
    /// Space created long ago and updated yesterday is new to nobody and stale to
    /// nobody either.
    @Test("recently updated reads the last commit, not the creation date")
    func sortsByUpdated() {
        #expect(store(sort: .updated).visibleApps.map(\.title) == ["Alpha", "Delta", "Charlie", "Bravo"])
    }

    /// `sorted(by:)` is not stable, so equal keys need a total order of their own.
    /// Without the tie-break these two swap places between redraws of a list nobody
    /// touched.
    @Test("apps equal on the sort key fall back to their titles")
    func breaksTiesByTitle() {
        let sameAuthor: [RobotApp] = [
            .preview(name: "zulu", title: "Zulu", author: "amir", likes: 1),
            .preview(name: "kilo", title: "Kilo", author: "amir", likes: 1),
        ]
        let titles = store(sort: .author, catalogue: sameAuthor).visibleApps.map(\.title)

        #expect(titles == ["Kilo", "Zulu"])
        #expect(store(sort: .likes, catalogue: sameAuthor).visibleApps.map(\.title) == titles)
    }

    // MARK: - What the toolbar says about itself

    @Test("the toolbar reports a non-default scope or sort, and only that")
    func reportsWhetherAnythingIsInForce() {
        let model = store()
        #expect(!model.isFiltering)

        model.sort = .name
        #expect(model.isFiltering)

        model.sort = .recommended
        model.scope = .privateSpaces
        #expect(model.isFiltering)
    }

    /// Both sections go through one path, so a scope chosen in Discover is still in
    /// force after a switch — which is what makes the empty state's wording true
    /// there too.
    @Test("the scope survives a section switch")
    func scopeAppliesToBothSections() {
        let model = AppStoreModel.preview(
            section: .discover,
            scope: .privateSpaces,
            catalogue: Self.apps,
            installed: [.preview(name: "installed_thing", title: "Installed Thing", installed: true)]
        )

        #expect(model.visibleApps.map(\.title) == ["Charlie"])

        model.section = .installed
        #expect(model.visibleApps.isEmpty)
    }
}
