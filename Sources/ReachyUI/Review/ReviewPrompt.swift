import Foundation
import StoreKit
import SwiftUI

/// The App Store's side of a rating: where the page is, and what suppresses a prompt.
enum ReviewPrompt {
    /// How long the reader has to stay on Settings before the prompt may appear.
    /// Apple's sample waits two seconds for the same reason: a prompt the instant a
    /// tab opens lands on top of whatever the reader came there to do.
    static let dwell: Duration = .seconds(2)

    /// The one app record, iOS and macOS alike (`docs/release.md`).
    static let appStoreID = "6799644194"

    /// The product page with its review sheet open — Apple's documented
    /// `action=write-review`. The Mac App Store takes its own scheme; the web page
    /// would open in a browser there.
    static var writeReviewURL: URL {
        var components = URLComponents()
        #if os(macOS)
            components.scheme = "macappstore"
        #else
            components.scheme = "https"
        #endif
        components.host = "apps.apple.com"
        components.path = "/app/id\(appStoreID)"
        components.queryItems = [URLQueryItem(name: "action", value: "write-review")]
        guard let url = components.url else {
            preconditionFailure("the review URL's components are fixed and valid")
        }
        return url
    }

    /// A development build shows the prompt on *every* request, so a flow that
    /// taps Settings would find it covering the tab bar. `Apps/Maestro/sim-daemon.yaml`
    /// passes this; `--reachy-smoke` needs nothing, because it sets
    /// `reachyPreviewMode`, which suppresses the prompt as well.
    static let suppressingArgument = "--reachy-no-review-prompt"

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

/// Where `ReviewPromptPlan` is kept between launches.
///
/// `UserDefaults.standard`, not the App Group and not the iCloud mirror: the
/// system's three showings a year are counted per device, and a count arriving
/// from another device would be a count of something this one never spent.
@MainActor
final class ReviewPromptStore {
    static let shared = ReviewPromptStore()

    private(set) var plan: ReviewPromptPlan
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        plan = ReviewPromptPlan(
            visitsSinceRequest: defaults.integer(forKey: Key.visits),
            requestsMade: defaults.integer(forKey: Key.requests),
            lastRequestDate: defaults.object(forKey: Key.date) as? Date,
            lastRequestVersion: defaults.string(forKey: Key.version)
        )
    }

    func settingsVisited() {
        plan.settingsVisited()
        save()
    }

    /// Decides and records in one step, so two windows settling on Settings at
    /// once cannot both ask.
    func claimRequest(now: Date, version: String) -> Bool {
        guard plan.mayRequest(now: now, version: version) else { return false }
        plan.requested(now: now, version: version)
        save()
        return true
    }

    private func save() {
        defaults.set(plan.visitsSinceRequest, forKey: Key.visits)
        defaults.set(plan.requestsMade, forKey: Key.requests)
        defaults.set(plan.lastRequestDate, forKey: Key.date)
        defaults.set(plan.lastRequestVersion, forKey: Key.version)
    }

    private enum Key {
        static let visits = "reviewPrompt.visitsSinceRequest"
        static let requests = "reviewPrompt.requestsMade"
        static let date = "reviewPrompt.lastRequestDate"
        static let version = "reviewPrompt.lastRequestVersion"
    }
}

extension View {
    /// Asks for an App Store rating when the reader settles on Settings — see
    /// `ReviewPromptPlan` for when, and why it can only ever be a guess.
    func reviewPrompt(tab: ReachyRouter.Tab) -> some View {
        modifier(ReviewPromptModifier(tab: tab))
    }
}

/// What one shell has seen of the Settings tab.
///
/// The root rebuilds `ReachyTabShell` on every connect, and the new shell starts on
/// whatever tab the router still holds. So a reconnect with Settings showing builds a
/// shell that starts on Settings, and that is not a visit: it may neither count one
/// nor start the dwell. Only a change of tab inside one shell is an arrival.
struct ReviewPromptArrival: Equatable {
    private var tab: ReachyRouter.Tab
    /// The reader came to Settings by a change of tab in this shell, and is still there.
    private(set) var hasArrived = false

    init(startingOn tab: ReachyRouter.Tab) {
        self.tab = tab
    }

    /// Records the shell's tab, and answers whether that was an arrival on Settings.
    mutating func select(_ tab: ReachyRouter.Tab) -> Bool {
        guard tab != self.tab else { return false }
        self.tab = tab
        hasArrived = tab == .settings
        return hasArrived
    }
}

private struct ReviewPromptModifier: ViewModifier {
    let tab: ReachyRouter.Tab
    /// Starts on the tab this shell was built on, which is never an arrival.
    @State private var arrival: ReviewPromptArrival

    @Environment(\.requestReview) private var requestReview
    @Environment(\.reachyPreviewMode) private var previewMode
    @Environment(\.scenePhase) private var scenePhase

    init(tab: ReachyRouter.Tab) {
        self.tab = tab
        _arrival = State(initialValue: ReviewPromptArrival(startingOn: tab))
    }

    func body(content: Content) -> some View {
        content
            // A visit is arriving on the tab. Coming back to the app with Settings
            // already showing is not one, which is why this keys on the tab alone —
            // and neither is a shell rebuilt on Settings, which is why there is no
            // `initial: true` (`ReviewPromptArrival`).
            .onChange(of: tab) { _, tab in
                guard arrival.select(tab), isEnabled else { return }
                ReviewPromptStore.shared.settingsVisited()
            }
            // The dwell does restart on the scene phase: a prompt timed across a trip
            // to the background would appear the moment the app came back, which is
            // the "on launch" Apple asks apps not to do.
            .task(id: Dwell(hasArrived: arrival.hasArrived, isActive: scenePhase == .active)) {
                guard arrival.hasArrived, scenePhase == .active, isEnabled else { return }
                try? await Task.sleep(for: ReviewPrompt.dwell)
                guard !Task.isCancelled,
                      ReviewPromptStore.shared.claimRequest(now: Date(), version: ReviewPrompt.appVersion)
                else { return }
                requestReview()
            }
    }

    private var isEnabled: Bool {
        !previewMode && !ProcessInfo.processInfo.arguments.contains(ReviewPrompt.suppressingArgument)
    }

    private struct Dwell: Equatable {
        let hasArrived: Bool
        let isActive: Bool
    }
}
