import ReachyKit
@testable import ReachyUI
import SwiftUI

/// Preview wrappers for the on-device explanation, and for the console it hangs off.
///
/// Its own file rather than an addition to `PreviewScenes.swift`, which sits exactly
/// on SwiftLint's length limit — the same reason `PermissionScenes.swift` and
/// `PreviewSettingsScenes.swift` exist. Not `private`, because Prefire copies each
/// preview body into a generated file and anything a body names must be visible
/// target-wide.
@MainActor
extension PreviewScene {
    /// The console, which lives here rather than in `PreviewScenes.swift` because #72
    /// gave it a fourth argument and that file is at its length limit.
    ///
    /// **The explanation gate defaults to unavailable, and that is what decides how
    /// many references move.** Left to build its own model, `LogConsoleScreen` would
    /// read the *simulator's* real Apple Intelligence state, so these nine references
    /// would differ between machines. Defaulting it off also keeps every one of them
    /// byte-identical to what it was before #72, and covers the absence — which is the
    /// state of every device below iOS 26. The presence gets a preview of its own.
    static func logConsole(
        _ model: LogConsoleModel? = nil,
        setupError: String? = nil,
        session: RobotSession? = nil,
        explain: LogExplanationModel? = nil
    ) -> some View {
        NavigationHost {
            LogConsoleScreen(
                session: session ?? .preview(),
                model: model ?? .preview(),
                setupError: setupError,
                explain: explain ?? .preview(.unavailable(.deviceNotEligible))
            )
        }
        .preview()
    }

    /// The sheet's content rendered standalone, never by presenting a `.sheet` — the
    /// shape every other sheet preview here uses, and the only one Prefire can capture.
    ///
    /// The model is always injected and already in its end state, because a preview is
    /// captured on its first frame: awaiting a real `LanguageModelSession` would render
    /// an empty form and prove nothing.
    static func logExplanation(_ phase: LogExplanationModel.Phase) -> some View {
        NavigationHost {
            LogExplanationSheet(
                model: .preview(phase),
                entries: [],
                filterSummary: nil,
                dismiss: {}
            )
        }
        .preview()
    }
}
