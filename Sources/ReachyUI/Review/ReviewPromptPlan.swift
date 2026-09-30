import Foundation

/// When the app asks StoreKit for an App Store rating, as a pure value.
///
/// **StoreKit answers nothing, and that decides the whole shape.** `requestReview`
/// returns no result: the app cannot tell whether a prompt appeared, whether it was
/// dismissed, or whether the reader rated. The system also decides on its own whether
/// to show one at all — at most three times in 365 days on a device, and after a
/// rating only for a new version a year on. So "ask less often after a refusal" can
/// only be "ask less often after *every* request": each one is treated as possibly
/// declined, and the next waits longer.
///
/// The moment is arriving on the Settings tab, which exists only once a robot has
/// answered — so the reader has already done the one thing this app is for. The
/// visits between requests grow 1, 3, 5, 8, 13, 21 …, which puts the requests on
/// visits 1, 3, 7, 13, 22, 36 …
///
/// Two gates sit on top, both from Apple's own sample: never twice for one version,
/// and never within thirty days of the last request. Without the second, somebody
/// who opens Settings daily spends the system's three showings in a week and every
/// request after that is silently ignored for the rest of the year. A request that
/// falls due while a gate is shut is not skipped: it waits, and the first visit after
/// the gate opens asks.
struct ReviewPromptPlan: Equatable, Sendable {
    /// Visits to Settings since the last request — or since install, before the first.
    var visitsSinceRequest = 0
    /// How many times the app has asked. Not how many times anybody saw a prompt:
    /// nothing reports that.
    var requestsMade = 0
    var lastRequestDate: Date?
    /// `CFBundleShortVersionString` at the last request.
    var lastRequestVersion: String?

    static let minimumInterval: TimeInterval = 30 * 24 * 60 * 60

    /// Visits skipped after the `count`-th request: 1, 3, 5, then each the sum of
    /// the two before it.
    static func pause(afterRequest count: Int) -> Int {
        var pauses = [1, 3, 5]
        while pauses.count < count {
            pauses.append(pauses[pauses.count - 1] + pauses[pauses.count - 2])
        }
        return pauses[max(count, 1) - 1]
    }

    /// Counted on arrival, whether or not a request follows: the pause is measured
    /// in visits, and one that leaves before the prompt would have appeared is a
    /// visit all the same.
    mutating func settingsVisited() {
        visitsSinceRequest += 1
    }

    func mayRequest(now: Date, version: String) -> Bool {
        let isDue = requestsMade == 0
            ? visitsSinceRequest >= 1
            : visitsSinceRequest > Self.pause(afterRequest: requestsMade)
        guard isDue, version != lastRequestVersion else { return false }
        guard let lastRequestDate else { return true }
        return now.timeIntervalSince(lastRequestDate) >= Self.minimumInterval
    }

    mutating func requested(now: Date, version: String) {
        requestsMade += 1
        visitsSinceRequest = 0
        lastRequestDate = now
        lastRequestVersion = version
    }
}
