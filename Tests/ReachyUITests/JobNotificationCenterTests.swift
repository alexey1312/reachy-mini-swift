import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// Records what actually reached the system boundary.
private final class PostSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [JobNotificationPlan.Request] = []

    var posted: [JobNotificationPlan.Request] {
        lock.withLock { requests }
    }

    func record(_ request: JobNotificationPlan.Request) {
        lock.withLock { requests.append(request) }
    }
}

/// `JobNotificationPlanTests` proves the rules; this proves the centre feeds them the
/// right facts. Everything the real one would touch is injected, so nothing here goes
/// near `UNUserNotificationCenter.current()` — which traps rather than fails in a
/// process with no bundle identifier, and would take the whole suite with it.
@MainActor
@Suite("Job notification centre")
struct JobNotificationCenterTests {
    private let notice = JobNotificationPlan.Notice(
        key: .init(kind: .appInstall, robotID: "hw-kitchen", subject: "pollen-bot"),
        robotName: "Kitchen",
        subjectTitle: "PollenBot"
    )

    private func centre(
        enabled: Bool = true,
        authorization: PermissionState = .granted,
        spy: PostSpy
    ) -> JobNotificationCenter {
        JobNotificationCenter(
            isEnabled: { enabled },
            authorization: { authorization },
            post: { spy.record($0) }
        )
    }

    /// Drives one whole job. Delivery is the one asynchronous step, so the caller
    /// waits on the count rather than on a duration.
    private func run(_ centre: JobNotificationCenter) async {
        centre.receive(.started(notice, at: Date()))
        centre.receive(.settled(notice, .succeeded(detail: nil), at: Date()))
    }

    /// Yields until the spy has what was expected, or gives up. A condition rather
    /// than a sleep: the delivery task is scheduled, not timed, and a loaded runner
    /// must not be able to turn this into a flake.
    private func settle(_ spy: PostSpy, expecting count: Int) async {
        for _ in 0 ..< 1000 where spy.posted.count < count {
            await Task.yield()
        }
    }

    /// The negative cases need the same chance to be wrong, or they would pass simply
    /// by being read too early.
    private func settleSilence(_ spy: PostSpy) async {
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        #expect(spy.posted.isEmpty)
    }

    @Test("a job that finishes while nobody is looking is announced")
    func announcesWhenBackgrounded() async {
        let spy = PostSpy()
        let centre = centre(spy: spy)
        await centre.sceneBecame(active: false)

        await run(centre)
        await settle(spy, expecting: 1)

        #expect(spy.posted.count == 1)
    }

    /// The reader is already watching it happen. All three inputs are tested
    /// separately rather than together, because a centre that never posted at all
    /// would satisfy any one of them on its own.
    @Test("nothing is announced while the app is in front")
    func foregroundIsSilent() async {
        let spy = PostSpy()
        let centre = centre(spy: spy)
        await centre.sceneBecame(active: true)

        await run(centre)
        await settleSilence(spy)
    }

    @Test("the setting being off is enough on its own to stay silent")
    func optOutIsSilent() async {
        let spy = PostSpy()
        let centre = centre(enabled: false, spy: spy)
        await centre.sceneBecame(active: false)

        await run(centre)
        await settleSilence(spy)
    }

    @Test("a refused or unanswered system permission is enough on its own to stay silent")
    func withoutAuthorizationIsSilent() async {
        for answer in [PermissionState.denied, .undetermined, .restricted] {
            let spy = PostSpy()
            let centre = centre(authorization: answer, spy: spy)
            await centre.sceneBecame(active: false)

            await run(centre)
            for _ in 0 ..< 100 {
                await Task.yield()
            }

            #expect(spy.posted.isEmpty, "\(answer) should not deliver")
        }
    }

    /// A centre that has never been told the scene phase has never read the system's
    /// answer either, so it must not post on a guess.
    @Test("a centre that was never told the phase announces nothing")
    func staysSilentUntilItHasBeenTold() async {
        let spy = PostSpy()
        let centre = centre(spy: spy)

        await run(centre)
        await settleSilence(spy)
    }

    /// **The ordering the doc comment calls a race fix.** `sceneBecame` assigns
    /// `isForeground` *before* awaiting the authorization read, so a job settling
    /// during that await is judged against the phase the app is actually in. Driven
    /// from inside the stub, so there is no scheduling in the test at all.
    @Test("a job settling while the authorization read is in flight sees the new phase")
    func foregroundIsAppliedBeforeTheAwait() async {
        let spy = PostSpy()
        var centre: JobNotificationCenter?
        let built = JobNotificationCenter(
            isEnabled: { true },
            authorization: {
                // Runs inside `sceneBecame`'s await, after `isForeground` was set.
                if let centre = await MainActor.run(body: { centre }) {
                    await MainActor.run {
                        centre.receive(.started(notice, at: Date()))
                        centre.receive(.settled(notice, .succeeded(detail: nil), at: Date()))
                    }
                }
                return .granted
            },
            post: { spy.record($0) }
        )
        centre = built

        // Foreground first, so authorization is already `.granted` when the second
        // call suspends — the settle below turns on `isForeground` alone.
        await built.sceneBecame(active: true)
        #expect(spy.posted.isEmpty, "the foreground pass must not deliver")
        await built.sceneBecame(active: false)
        await settle(spy, expecting: 1)

        #expect(spy.posted.count == 1)
    }

    /// The plan is mutated synchronously, so a start and a settle issued back to back
    /// cannot be reordered by the scheduler — the primary guard would drop the settle
    /// if they were.
    @Test("a start and a settle issued back to back are never reordered")
    func planIsMutatedSynchronously() async {
        let spy = PostSpy()
        let centre = centre(spy: spy)
        await centre.sceneBecame(active: false)

        for index in 0 ..< 20 {
            let notice = JobNotificationPlan.Notice(
                key: .init(kind: .appInstall, robotID: "hw-kitchen", subject: "app-\(index)"),
                robotName: "Kitchen"
            )
            centre.receive(.started(notice, at: Date()))
            centre.receive(.settled(notice, .succeeded(detail: nil), at: Date()))
        }
        await settle(spy, expecting: 20)

        #expect(spy.posted.count == 20)
    }
}
