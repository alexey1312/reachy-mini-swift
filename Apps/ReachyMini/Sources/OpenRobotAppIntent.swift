import AppIntents
import ReachyUI
import ReachyWidgetUI

/// "Open the conversation app" — the second schema, and the one that needs no body.
///
/// `AppIntents` supplies `perform()` for an `OpenIntent` whose target is a
/// `URLRepresentableEntity`:
///
/// ```swift
/// extension URLRepresentableIntent where Self: OpenIntent, Self.Value: URLRepresentableEntity {
///     public func perform() async throws -> Never
/// }
/// ```
///
/// so the whole implementation is `RobotAppEntity.urlRepresentation` in
/// `EntityURLs.swift`. The system opens that URL, `RootLifecycle.onOpenURL` parses
/// it as a `ReachyDeepLink.Target`, and the identifier reaches `AppStoreScreen`
/// through `AppStoreRequestInbox`. Nothing here routes anything.
///
/// **iOS 27, and the gate is on the type rather than inside it.** `.system.open` is
/// a 27 schema — unlike `.system.search`, which is iOS 18 and ships at this app's
/// floor. Below 27 the app simply has no such action, which is the honest shape:
/// there is no partial version of "the assistant understands this domain".
///
/// **Only apps.** A move and a sound have no selection state on their screens to
/// open onto, and a robot other than the connected one is a connection rather than
/// a destination — each needs a screen change first and an entity URL second.
/// `docs/research/ios-27.md` §3.1 carries the reasoning.
///
/// In the app target beside `CallRobotIntent`, for the reason recorded there:
/// `OpenIntent` hands out `openAppWhenRun` from a protocol extension the author
/// cannot decline, and that flag errors at runtime in an appex.
@available(iOS 27.0, macOS 27.0, *)
@AppIntent(schema: .system.open)
struct OpenRobotAppIntent {
    static let title: LocalizedStringResource = "Open a Reachy Mini App"
    static let description = IntentDescription(
        "Opens the page for one of your Reachy Mini's apps, where you can start, update or remove it."
    )

    var target: RobotAppEntity
}
