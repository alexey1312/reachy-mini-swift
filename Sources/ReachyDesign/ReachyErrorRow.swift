import SwiftUI

/// One failure, in a form row, with the way out beside it.
///
/// Seven screens used to spell this by hand — `Text(error)` in `Typography.consoleLine`
/// and `Tone.danger`, in a `Section` of its own — and only one of them offered anything
/// to do next. A red sentence with no button under it tells the reader what happened
/// and leaves them to guess at what to try, which is the "disabled control with no
/// reason" mistake from the other side.
///
/// The text takes `Typography.status`, not the console role: a daemon's refusal is a
/// sentence, and monospace belongs to a traceback (`AppDetailSheet.failureRow` keeps
/// it). `retry` is optional because two of those screens genuinely have nothing to
/// offer — the connection gate's rail owns its own "Try again", and the Robot tab's
/// error sits beside the row that reconnects.
///
/// `OnboardingErrorText` is the same idea in `Typography.detail` and stays where it is
/// for now; folding it in is a later pass.
public struct ReachyErrorRow: View {
    private let message: String
    private let retry: (() -> Void)?

    public init(_ message: String, retry: (() -> Void)? = nil) {
        self.message = message
        self.retry = retry
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Tone.danger.style)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(message)
                    .font(Typography.status)
                    .foregroundStyle(Tone.danger.style)
                    .fixedSize(horizontal: false, vertical: true)
                if let retry {
                    Button(.reachy("Try again"), action: retry)
                        .reachyButton(.quiet)
                }
            }
        }
    }
}
