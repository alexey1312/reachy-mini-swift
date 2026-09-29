import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// A tapped job notification opens the job it was about, through the same deep
/// link a widget uses — so what is pinned here is which link each job carries, and
/// that nothing but this app's own destinations comes back out of `userInfo`.
@Suite("Job notification links")
struct JobNotificationLinkTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func posted(
        _ notice: JobNotificationPlan.Notice,
        _ result: JobNotificationPlan.Result = .succeeded(detail: nil)
    ) throws -> JobNotificationPlan.Request {
        var plan = JobNotificationPlan()
        plan.isPermitted = true
        _ = plan.handle(.started(notice, at: now))
        let effects = plan.handle(.settled(notice, result, at: now.addingTimeInterval(60)))
        let requests = effects.compactMap { effect -> JobNotificationPlan.Request? in
            guard case let .post(request) = effect else { return nil }
            return request
        }
        return try #require(requests.first)
    }

    private func appNotice(_ kind: JobNotificationPlan.Kind) -> JobNotificationPlan.Notice {
        JobNotificationPlan.Notice(
            key: .init(kind: kind, robotID: "hw-kitchen", subject: "reachy_mini_dance"),
            robotName: "Kitchen",
            subjectTitle: "Dance",
            subjectID: "pollen-robotics/reachy_mini_dance"
        )
    }

    /// By the Space id, which is what the Apps tab finds a row by — never by the
    /// daemon's `name`, which is the key's subject.
    @Test("an installed or updated app opens its own row", arguments: [
        JobNotificationPlan.Kind.appInstall, .appUpdate,
    ])
    func appJobOpensTheApp(kind: JobNotificationPlan.Kind) throws {
        let request = try posted(appNotice(kind))

        #expect(request.link == ReachyDeepLink.Target(
            destination: .apps,
            identifier: "pollen-robotics/reachy_mini_dance"
        ))
    }

    /// A successful removal is never announced, so the one removal that posts is a
    /// failed one — and that app is still installed, with a row to open.
    @Test("a failed removal opens the app it could not remove")
    func failedRemovalOpensTheApp() throws {
        let request = try posted(appNotice(.appRemove), .failed("Permission denied"))

        #expect(request.link == ReachyDeepLink.Target(
            destination: .apps,
            identifier: "pollen-robotics/reachy_mini_dance"
        ))
    }

    @Test("a system update opens Settings, where the update lives")
    func systemUpdateOpensSettings() throws {
        let request = try posted(JobNotificationPlan.Notice(
            key: .init(kind: .systemUpdate, robotID: "hw-kitchen"),
            robotName: "Kitchen"
        ))

        #expect(request.link == ReachyDeepLink.Target(destination: .settings))
    }

    @Test("the link survives the round trip through userInfo")
    func roundTrips() throws {
        let target = ReachyDeepLink.Target(destination: .apps, identifier: "pollen-robotics/reachy_mini_dance")
        let userInfo: [AnyHashable: Any] = JobNotificationLink.userInfo(for: target)

        let url = try #require(JobNotificationLink.url(in: userInfo))

        #expect(ReachyDeepLink.Target(url: url) == target)
    }

    /// The OAuth callback shares the scheme; a notification must not replay it, nor
    /// open anything that is not one of this app's destinations.
    @Test("nothing but this app's destinations comes back out", arguments: [
        "reachy-mini-swift://oauth-callback?code=abc",
        "https://example.com/apps",
        "not a url",
    ])
    func refusesForeignLinks(raw: String) {
        #expect(JobNotificationLink.url(in: [JobNotificationLink.key: raw]) == nil)
    }

    @Test("a notification with no link opens nothing")
    func missingLink() {
        #expect(JobNotificationLink.url(in: [:]) == nil)
    }

    @Test("Settings is reachable by link")
    @MainActor
    func routerFollowsSettings() {
        let router = ReachyRouter(tab: .robot)

        router.follow(.settings)

        #expect(router.tab == .settings)
    }
}
