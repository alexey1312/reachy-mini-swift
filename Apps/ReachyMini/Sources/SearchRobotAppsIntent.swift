import AppIntents
import ReachyUI

/// "Search Hey Reachy for a chess app" — the app's first App Intents *schema*.
///
/// **A schema rather than a phrase, and that is the whole point.** Every other
/// intent this app ships is its own type, reachable only through one of the ten
/// `AppShortcut` phrases `ReachyShortcuts` spells out — a ceiling the system
/// enforces silently. `.system.search` binds this one to a domain the assistant
/// already understands, so it needs no phrase, displaces none of the ten, and asks
/// nothing of a translator.
///
/// **It searches the app catalogue and nothing else, and the description says so.**
/// That is the one full-text search this app has; moves, sounds and robots are
/// reachable as *entities* instead — indexed in Spotlight, and marked on screen by
/// `reachyEntityIdentifier`. A broader promise would be a lie on the Apps tab,
/// which is the only place a term can land. It is a lie in one more place worth
/// naming: with no robot connected `AppsTab` draws `AppsUnavailableView`, which has
/// no search field at all, so someone who asks this of a disconnected app gets the
/// screen that explains why rather than a filled field. Scoping the sentence is
/// what keeps that an honest answer instead of a broken one.
///
/// **In the app target, and it must stay here** — the same rule `CallRobotIntent`
/// records. `ShowInAppSearchResultsIntent` supplies `openAppWhenRun` from a
/// framework protocol extension, which the author never writes and cannot decline,
/// and that flag errors at runtime when an intent runs in an appex. Living here
/// keeps it out of the extension's `Metadata.appintents` entirely.
///
/// Cross-platform, for the reason `CallRobotIntent` is: the metadata check reads
/// the macOS bundle too, so an `#if os(iOS)` here would fail the macOS release
/// build.
@AppIntent(schema: .system.search)
struct SearchRobotAppsIntent {
    static let title: LocalizedStringResource = "Search Reachy Mini Apps"
    static let description = IntentDescription(
        "Searches the apps you can install on your Reachy Mini, and opens the store showing what matched."
    )

    /// `[.general]` is the only scope that means anything here — the other three
    /// are `movies`, `tv` and `freeformVideo`.
    static let searchScopes: [StringSearchScope] = [.general]

    var criteria: StringSearchCriteria

    /// Nothing is awaited: the search is a screen change, and the screen is the
    /// only thing that can report it. `AppStoreRequestInbox` is the same seam
    /// `CallRequestInbox` is, and `ReachyTabShell` is what honours it — including
    /// on the frame the shell first appears, so a request made while the connect
    /// gate is up is not dropped.
    @MainActor
    func perform() async throws -> some IntentResult {
        AppStoreRequestInbox.shared.receive(term: criteria.term)
        return .result()
    }
}
