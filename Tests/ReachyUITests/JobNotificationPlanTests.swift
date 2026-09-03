import Foundation
@testable import ReachyUI
import Testing

/// A job notification is an event, not a card: once delivered it cannot be taken
/// back, corrected, or read in context. So most of these assert what the plan
/// *refuses* to do — announce a job it never watched begin, announce twice,
/// announce while the reader is already looking at the screen, or turn a register
/// that failed to answer into a verdict about the robot.
///
/// Nothing here touches `UNUserNotificationCenter`; the whole point of the reducer
/// living apart from the system adapter is that this suite runs under SwiftPM on
/// macOS, where that singleton would trap rather than fail.
@Suite("Job notification plan")
struct JobNotificationPlanTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func plan(permitted: Bool = true) -> JobNotificationPlan {
        var plan = JobNotificationPlan()
        plan.isPermitted = permitted
        return plan
    }

    private func notice(
        _ kind: JobNotificationPlan.Kind,
        robot: String? = "hw-kitchen",
        robotName: String? = "Kitchen",
        subject: String? = "pollen-bot",
        title: String? = "PollenBot"
    ) -> JobNotificationPlan.Notice {
        JobNotificationPlan.Notice(
            key: .init(kind: kind, robotID: robot, subject: kind == .systemUpdate ? nil : subject),
            robotName: robotName,
            subjectTitle: kind == .systemUpdate ? nil : title
        )
    }

    private func posted(_ effects: [JobNotificationPlan.Effect]) -> [JobNotificationPlan.Request] {
        effects.compactMap { effect in
            guard case let .post(request) = effect else { return nil }
            return request
        }
    }

    /// Drive one whole job and return what it posted.
    private func run(
        _ plan: inout JobNotificationPlan,
        _ notice: JobNotificationPlan.Notice,
        _ result: JobNotificationPlan.Result,
        settledAt offset: TimeInterval = 60
    ) -> [JobNotificationPlan.Request] {
        _ = plan.handle(.started(notice, at: now))
        return posted(plan.handle(.settled(notice, result, at: now.addingTimeInterval(offset))))
    }

    // MARK: - The primary guard

    /// The rule that covers a relaunched process, a stale model, and a `check` that
    /// failed before any job existed — without any of them being enumerated.
    @Test("a job that was never watched begin is never announced when it ends")
    func settleWithoutStartIsSilent() {
        var plan = plan()
        let effects = plan.handle(.settled(notice(.appInstall), .succeeded(detail: nil), at: now))
        #expect(posted(effects).isEmpty)
    }

    @Test("a job settles once — a repeat settle for the same key says nothing")
    func settlesOnlyOnce() {
        var plan = plan()
        let notice = notice(.systemUpdate)
        let first = run(&plan, notice, .succeeded(detail: "1.10.0"))
        let second = posted(plan.handle(.settled(notice, .succeeded(detail: "1.10.0"), at: now)))
        #expect(first.count == 1)
        #expect(second.isEmpty)
    }

    // MARK: - The timer that must not become a verdict

    /// The pair is the test. `.unanswered` alone proves nothing — a plan that
    /// announced nothing at all would pass it — so the same job settling `.failed`
    /// has to come out the other way in the same breath.
    @Test("a register that never answered is silence, while a register that reported a failure is not")
    func timeoutIsSilentButFailureIsNot() {
        var silent = plan()
        var loud = plan()
        let notice = notice(.appInstall)
        #expect(run(&silent, notice, .unanswered).isEmpty)
        #expect(run(&loud, notice, .failed("pip exited 1")).count == 1)
    }

    /// Neither success nor failure, and the copy has to say exactly that rather than
    /// pick one. Asserted against the other two rather than against English text, so
    /// the suite survives a translated catalogue.
    @Test("a daemon that restarted mid-job is announced as neither installed nor failed")
    func daemonRestartedIsItsOwnAnnouncement() {
        var restarted = plan()
        var succeeded = plan()
        var failed = plan()
        let notice = notice(.appInstall)
        let a = run(&restarted, notice, .inconclusive)
        let b = run(&succeeded, notice, .succeeded(detail: nil))
        let c = run(&failed, notice, .failed("pip exited 1"))
        #expect(a.count == 1)
        #expect(a[0].title != b[0].title)
        #expect(a[0].title != c[0].title)
        #expect(a[0].body != b[0].body)
        #expect(a[0].body != c[0].body)
    }

    // MARK: - Permission, and when it is read

    @Test("nothing is announced while the reader is looking at the app")
    func foregroundIsSilent() {
        var plan = plan(permitted: false)
        #expect(run(&plan, notice(.appInstall), .succeeded(detail: nil)).isEmpty)
    }

    /// The key is consumed even when nothing was posted, so a settle refused for
    /// being in the foreground cannot be re-delivered by a later one.
    @Test("a settle refused in the foreground still consumes the job")
    func refusedSettleStillConsumesTheKey() {
        var plan = plan(permitted: false)
        let notice = notice(.appInstall)
        _ = run(&plan, notice, .succeeded(detail: nil))
        plan.isPermitted = true
        let again = posted(plan.handle(.settled(notice, .succeeded(detail: nil), at: now)))
        #expect(again.isEmpty)
    }

    /// The one asymmetry in the whole reducer, and without a test somebody will
    /// "simplify" it away: a start is recorded whether or not posting is permitted,
    /// because permission belongs to the moment of delivery.
    @Test("permission granted midway through a long job still announces its end")
    func permissionIsReadAtDeliveryNotAtStart() {
        var plan = plan(permitted: false)
        let notice = notice(.systemUpdate)
        _ = plan.handle(.started(notice, at: now))
        plan.isPermitted = true
        let effects = plan.handle(.settled(notice, .succeeded(detail: "1.10.0"), at: now.addingTimeInterval(600)))
        #expect(posted(effects).count == 1)
    }

    // MARK: - Which jobs earn an announcement

    @Test("a successful removal says nothing, because the app list already shows it")
    func successfulRemovalIsSilent() {
        var plan = plan()
        #expect(run(&plan, notice(.appRemove), .succeeded(detail: nil)).isEmpty)
    }

    /// The mirror of the case above: the app is still there, which is a fact about
    /// the robot rather than the absence of one.
    @Test("a failed removal is announced")
    func failedRemovalIsAnnounced() {
        var plan = plan()
        #expect(run(&plan, notice(.appRemove), .failed("still in use")).count == 1)
    }

    @Test("an install and an update both announce success")
    func installAndUpdateAnnounceSuccess() {
        for kind in [JobNotificationPlan.Kind.appInstall, .appUpdate] {
            var plan = plan()
            #expect(run(&plan, notice(kind), .succeeded(detail: nil)).count == 1, "\(kind) should announce")
        }
    }

    // MARK: - What the request carries

    @Test("the daemon's own words are the body of a failure")
    func failureBodyIsTheDaemonsWords() {
        var plan = plan()
        let requests = run(&plan, notice(.appInstall), .failed("No matching distribution found"))
        #expect(requests[0].body == "No matching distribution found")
    }

    @Test("a finished system update names the version it landed on")
    func systemUpdateNamesTheVersion() {
        var plan = plan()
        let requests = run(&plan, notice(.systemUpdate), .succeeded(detail: "1.10.0"))
        #expect(requests[0].body.contains("1.10.0"))
        #expect(requests[0].body.contains("Kitchen"))
    }

    /// Identity is captured when the job starts, so a settle that lands after the
    /// app has moved on still names the robot the job was about — which is the whole
    /// reason a system update can be announced at all.
    @Test("the announcement names the robot the job started on")
    func namesTheRobotTheJobBeganOn() {
        var plan = plan()
        let kitchen = notice(.systemUpdate, robot: "hw-kitchen", robotName: "Kitchen")
        let requests = run(&plan, kitchen, .succeeded(detail: "1.10.0"))
        #expect(requests[0].body.contains("Kitchen"))
        #expect(requests[0].threadIdentifier.contains("hw-kitchen"))
    }

    /// Sub-second on purpose: a job the daemon refuses outright settles in well under
    /// a second, so a retry inside the same second is the case that would collide.
    @Test("two runs of the same job stack rather than replace one another")
    func repeatRunsGetDistinctIdentifiers() {
        var plan = plan()
        let notice = notice(.appInstall)
        let first = run(&plan, notice, .failed("pip exited 1"), settledAt: 0.05)
        let second = run(&plan, notice, .succeeded(detail: nil), settledAt: 0.4)
        #expect(first[0].identifier != second[0].identifier)
        #expect(first[0].threadIdentifier == second[0].threadIdentifier)
    }

    /// A cheap guard against a catalogue key that silently resolved to nothing, and
    /// against a copy branch nobody filled in.
    @Test("every announcement carries a title and a body")
    func everyAnnouncementIsLegible() {
        let results: [JobNotificationPlan.Result] = [
            .succeeded(detail: "1.10.0"), .succeeded(detail: nil), .failed("because"), .inconclusive, .unanswered,
        ]
        for kind in JobNotificationPlan.Kind.allCases {
            for result in results {
                var plan = plan()
                for request in run(&plan, notice(kind), result) {
                    #expect(!request.title.isEmpty, "\(kind) / \(result) posted an empty title")
                    #expect(!request.body.isEmpty, "\(kind) / \(result) posted an empty body")
                }
            }
        }
    }

    /// An unnamed robot is a real state — `RobotIdentity.name` is optional — and the
    /// copy must not come out with a hole in it. Empty counts as unnamed:
    /// `/api/daemon/robot-name` can answer with an empty body, which arrives as `""`
    /// rather than `nil` and would otherwise leave the sentence starting mid-air.
    @Test("an unnamed robot still produces a sentence, empty name included")
    func unnamedRobotStillReads() {
        for name in [nil, "", "   "] {
            var plan = plan()
            let anonymous = notice(.systemUpdate, robot: nil, robotName: name)
            let requests = run(&plan, anonymous, .succeeded(detail: "1.10.0"))
            #expect(!requests[0].body.isEmpty)
            #expect(!requests[0].body.hasPrefix(" "), "\(String(describing: name)) left a hole")
            #expect(requests[0].body.contains("Reachy Mini"))
        }
    }
}
