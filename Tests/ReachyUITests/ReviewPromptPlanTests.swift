import Foundation
@testable import ReachyUI
import Testing

/// StoreKit reports nothing back, so the plan is the only place the policy can be
/// seen at all — and a prompt shown too often is a prompt the system silently stops
/// showing for a year. Most of these assert when the plan does *not* ask.
@Suite("Review prompt plan")
struct ReviewPromptPlanTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    @Test("the pauses grow 1, 3, 5, 8, 13, 21")
    func pausesGrow() {
        #expect((1 ... 6).map { ReviewPromptPlan.pause(afterRequest: $0) } == [1, 3, 5, 8, 13, 21])
    }

    /// The schedule on its own, with both gates held open: every visit a new
    /// version, every visit a month after the last.
    @Test("with the gates open, the requests land on visits 1, 3, 7, 13, 22 and 36")
    func requestsOnTheSchedule() {
        var plan = ReviewPromptPlan()
        var asked: [Int] = []
        for visit in 1 ... 40 {
            plan.settingsVisited()
            let now = start.addingTimeInterval(Double(visit) * 31 * day)
            if plan.mayRequest(now: now, version: "0.\(visit)") {
                plan.requested(now: now, version: "0.\(visit)")
                asked.append(visit)
            }
        }
        #expect(asked == [1, 3, 7, 13, 22, 36])
    }

    @Test("nothing is asked before the first visit")
    func notBeforeAVisit() {
        #expect(!ReviewPromptPlan().mayRequest(now: start, version: "0.7.0"))
    }

    @Test("one version is never asked about twice, however long it lasts")
    func oncePerVersion() {
        var plan = ReviewPromptPlan()
        plan.settingsVisited()
        plan.requested(now: start, version: "0.7.0")
        for visit in 1 ... 20 {
            plan.settingsVisited()
            #expect(!plan.mayRequest(now: start.addingTimeInterval(Double(visit) * 60 * day), version: "0.7.0"))
        }
        #expect(plan.mayRequest(now: start.addingTimeInterval(365 * day), version: "0.8.0"))
    }

    /// The gate that keeps a daily reader from spending the system's three showings
    /// in a week.
    @Test("a new version still waits thirty days after the last request")
    func thirtyDaysApart() {
        var plan = ReviewPromptPlan()
        plan.settingsVisited()
        plan.requested(now: start, version: "0.7.0")
        plan.settingsVisited()
        plan.settingsVisited()

        #expect(!plan.mayRequest(now: start.addingTimeInterval(29 * day), version: "0.8.0"))
        #expect(plan.mayRequest(now: start.addingTimeInterval(30 * day), version: "0.8.0"))
    }

    /// A request that fell due behind a shut gate is owed, not forfeited: the first
    /// visit after the gate opens asks, rather than the next scheduled one.
    @Test("a request due behind a gate is made on the first visit after it opens")
    func dueRequestWaitsForTheGate() {
        var plan = ReviewPromptPlan()
        plan.settingsVisited()
        plan.requested(now: start, version: "0.7.0")
        for _ in 1 ... 10 {
            plan.settingsVisited()
        }
        #expect(!plan.mayRequest(now: start.addingTimeInterval(5 * day), version: "0.7.0"))

        plan.settingsVisited()
        #expect(plan.mayRequest(now: start.addingTimeInterval(40 * day), version: "0.8.0"))
    }

    /// The pause is counted from the request, so the visit that made it does not
    /// count towards the next one.
    @Test("the visit a request was made on does not count towards the next pause")
    func pauseCountsFromTheRequest() {
        var plan = ReviewPromptPlan()
        plan.settingsVisited()
        plan.requested(now: start, version: "0.7.0")
        plan.settingsVisited()

        #expect(!plan.mayRequest(now: start.addingTimeInterval(60 * day), version: "0.8.0"))
        plan.settingsVisited()
        #expect(plan.mayRequest(now: start.addingTimeInterval(60 * day), version: "0.8.0"))
    }
}

@Suite("Review prompt store")
@MainActor
struct ReviewPromptStoreTests {
    /// Each test on a suite of its own, for the reason `AppStoreRequestInboxTests`
    /// builds its own inbox: `--parallel` runs suites side by side.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "ReviewPromptStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test("the schedule survives a relaunch")
    func persists() {
        withDefaults { defaults in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let first = ReviewPromptStore(defaults: defaults)
            first.settingsVisited()
            #expect(first.claimRequest(now: now, version: "0.7.0"))
            first.settingsVisited()

            let relaunched = ReviewPromptStore(defaults: defaults)
            #expect(relaunched.plan == first.plan)
            #expect(relaunched.plan.requestsMade == 1)
            #expect(relaunched.plan.lastRequestVersion == "0.7.0")
            #expect(relaunched.plan.lastRequestDate == now)
        }
    }

    /// Two windows settling on Settings at once must not both ask.
    @Test("a claim is spent by the first caller")
    func claimsOnce() {
        withDefaults { defaults in
            let store = ReviewPromptStore(defaults: defaults)
            store.settingsVisited()
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            #expect(store.claimRequest(now: now, version: "0.7.0"))
            #expect(!store.claimRequest(now: now, version: "0.7.0"))
        }
    }
}

/// The root rebuilds the shell on every connect, and the new shell starts on the tab
/// the router still holds — so a reconnect with Settings showing must not read as
/// arriving there.
@Suite("Review prompt arrival")
struct ReviewPromptArrivalTests {
    /// A mutating call cannot sit inside `#expect`, so each answer is read out first.
    @Test("a shell built on Settings has not arrived there")
    func aRebuiltShellIsNotAVisit() {
        var arrival = ReviewPromptArrival(startingOn: .settings)

        let visited = arrival.select(.settings)

        #expect(!visited)
        #expect(!arrival.hasArrived)
    }

    @Test("a change of tab to Settings is an arrival, and leaving ends it")
    func aChangeOfTabIsAVisit() {
        var arrival = ReviewPromptArrival(startingOn: .settings)

        let away = arrival.select(.robot)
        let back = arrival.select(.settings)
        #expect(!away)
        #expect(back)
        #expect(arrival.hasArrived)

        let left = arrival.select(.apps)
        #expect(!left)
        #expect(!arrival.hasArrived)
    }
}

@Suite("Review link")
struct ReviewLinkTests {
    @Test("the link opens this app's review sheet")
    func opensTheReviewSheet() throws {
        let url = ReviewPrompt.writeReviewURL
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.host == "apps.apple.com")
        #expect(components.path == "/app/id6799644194")
        #expect(components.queryItems == [URLQueryItem(name: "action", value: "write-review")])
        #if os(macOS)
            #expect(components.scheme == "macappstore")
        #else
            #expect(components.scheme == "https")
        #endif
    }
}
