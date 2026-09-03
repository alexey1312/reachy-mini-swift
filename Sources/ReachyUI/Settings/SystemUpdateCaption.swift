import Foundation
import ReachyDesign

/// One robot software update state in words, for the two screens that show one.
///
/// Here rather than inside either view for the reason `DaemonStateCaption` gives,
/// and for a second one this file has that the others do not. The nine phrasings
/// used to live inside a `@ViewBuilder` switch on each screen, where every arm was
/// a differently-typed view *and* a `LocalizedStringResource` interpolation — nine
/// `_ConditionalContent`s deep in one expression, twice. `docs/research/ios-27.md`
/// recorded one of those two as "unable to type-check in reasonable time". A plain
/// `switch` returning a small value type-checks each arm on its own.
///
/// Four of the nine arms were already identical on both screens, which is rule 10's
/// trigger, and the hazard `RunningAppCaption` names applies here in the same words:
/// two surfaces that may not be allowed to say the same fact two ways.
enum SystemUpdateCaption {
    /// Which question the surface is asking, because the same state answers two of
    /// them. Not "which screen" — the screen is not the reason the words differ.
    ///
    /// In settings an update is an *offer*, so being up to date is the good news. In
    /// front of a robot below this app's floor it is a *requirement*, and being up to
    /// date is the dead end: the newest published release is still too old, nothing
    /// here can fix it, and the row has to say so rather than tick a green check.
    /// The same shape `RunningAppCaption.Failure` has, and the same reason.
    enum Purpose: Sendable {
        case offered
        case required
    }

    /// What the row *is*. Three shapes rather than a view, so the whole of this file
    /// stays reachable from `swift test`: no `Text`, no `Image`, no `@ViewBuilder`
    /// and no `@MainActor`. `SystemUpdateStatusRow` renders it.
    enum Row: Equatable, Sendable {
        /// A `Label`. `tone` is nil for the states nothing colours — five of the nine
        /// rows carry no `.foregroundStyle` at all today, and adding one "for
        /// symmetry" would move a reference.
        case label(String, symbol: String, tone: Tone?)
        /// A `LabeledContent` with a plain value: the installed version.
        case value(title: String, value: String)
        /// A `LabeledContent` whose value is monospaced: two version numbers and an
        /// arrow, which line up only in a fixed-width font. Its own case rather than a
        /// `Bool` on the one above, because `.monospaced(false)` is not documented to
        /// render identically to not applying the modifier, and a moved reference
        /// would be the first thing to say so.
        case versions(title: String, value: String)
    }

    /// A resolved `String` rather than a `LocalizedStringResource`, and rule 9's
    /// second bullet is the authority rather than taste: `.failed(message)` puts the
    /// daemon's own sentence in the same slot as a translated phrase, `.idle` and
    /// `.available` put version numbers in the value slot, and
    /// `SystemUpdateCaptionTests` asserts on the result. A slot that has to hold
    /// runtime text resolves early; `BLERecoveryScriptCaption` made the same trade
    /// for a script's file name.
    ///
    /// `installed` is `session.lastStatus?.version` and reaches `.idle` alone. It is
    /// deliberately not on the model: the state says nothing has been checked, and
    /// what is installed is the session's reading rather than the check's.
    ///
    /// One switch and no branching inside it — every fork on `purpose` is a function
    /// of its own. Nine arms is cyclomatic complexity 10, which is exactly what
    /// `--strict` allows; one `if` or `??` here would be 11 and fail the build. That
    /// is the same wall `RunningAppCaption.stuck` was extracted for.
    static func row(
        for state: SystemUpdateModel.State,
        purpose: Purpose,
        installed: String? = nil
    ) -> Row {
        switch state {
        case .idle:
            idle(purpose: purpose, installed: installed)
        case .checking:
            checking
        case let .upToDate(current):
            upToDate(current, purpose: purpose)
        case let .robotOffline(current):
            robotOffline(current, purpose: purpose)
        case let .available(current, latest):
            available(current, latest, purpose: purpose)
        case .installing:
            .label(
                String(localized: .reachy("Installing — this takes a minute or two…")),
                symbol: "arrow.down.circle",
                tone: nil
            )
        case .restarting:
            .label(
                String(localized: .reachy("The robot is restarting…")),
                symbol: "arrow.clockwise",
                tone: nil
            )
        case let .finished(version):
            .label(
                String(localized: .reachy("Updated to \(version).")),
                symbol: "checkmark.circle",
                tone: .success
            )
        // The daemon's own sentence, carried rather than replaced — the same rule
        // `RunningAppCaption` keeps for `.unknown(state)`, and project rule 3.
        case let .failed(message):
            .label(message, symbol: "xmark.octagon", tone: .danger)
        }
    }

    /// The gate checks on appearance, so it never renders an idle row — `.idle` there
    /// is the frame before the check starts, and "Installed 1.8.2" would be a version
    /// that screen already states twice above.
    private static func idle(purpose: Purpose, installed: String?) -> Row {
        switch purpose {
        case .offered:
            .value(title: String(localized: .reachy("Installed")), value: installed ?? "—")
        case .required:
            checking
        }
    }

    private static var checking: Row {
        .label(
            String(localized: .reachy("Checking for updates…")),
            symbol: "arrow.triangle.2.circlepath",
            tone: nil
        )
    }

    /// The one state where the two surfaces disagree about whether the news is good.
    private static func upToDate(_ current: String, purpose: Purpose) -> Row {
        switch purpose {
        case .offered:
            .label(
                String(localized: .reachy("Up to date — \(current)")),
                symbol: "checkmark.circle",
                tone: .success
            )
        case .required:
            .label(
                String(localized: .reachy("The robot is on \(current), the newest release available to it.")),
                symbol: "exclamationmark.triangle",
                tone: .warning
            )
        }
    }

    /// Same verdict on both, and a longer sentence where the reader is stuck: the
    /// gate has room and has to explain why retrying will not help.
    private static func robotOffline(_ current: String, purpose: Purpose) -> Row {
        switch purpose {
        case .offered:
            .label(
                String(localized: .reachy("\(current) — the robot can't reach the internet")),
                symbol: "wifi.exclamationmark",
                tone: .warning
            )
        case .required:
            .label(
                String(
                    localized: .reachy(
                        "The robot (\(current)) can't reach the internet, so it can't download an update."
                    )
                ),
                symbol: "wifi.exclamationmark",
                tone: .warning
            )
        }
    }

    /// Only the title differs. In settings this is news among other rows and has to
    /// name itself; on the gate it is the answer to the sentence above it.
    private static func available(_ current: String, _ latest: String, purpose: Purpose) -> Row {
        let versions = String(localized: .reachy("\(current) → \(latest)"))
        switch purpose {
        case .offered:
            return .versions(title: String(localized: .reachy("Update available")), value: versions)
        case .required:
            return .versions(title: String(localized: .reachy("Available")), value: versions)
        }
    }
}
