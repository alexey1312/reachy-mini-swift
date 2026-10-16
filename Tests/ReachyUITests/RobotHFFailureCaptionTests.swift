import Foundation
@testable import ReachyUI
import Testing

/// Daemon 1.12 words a failed robot sign-in with fixed sentences
/// (pollen-robotics/reachy_mini#1363); anything else is a daemon before it, whose
/// text may be the provider's own.
@Suite("A failed robot sign-in, in this app's words")
struct RobotHFFailureCaptionTests {
    @Test(
        "every sentence 1.12 sends has a translation of its own",
        arguments: [
            "Authentication failed. Please try again.",
            "Authorization was denied.",
            "Login expired. Please try again.",
            "Sign-in was cancelled. Please try again.",
            "Could not save credentials. Please try again.",
            "Invalid token or network error",
            "Invalid or expired session. Please try again.",
            "Session expired or not found",
        ]
    )
    func knowsTheDaemonsSentences(sentence: String) {
        let text = RobotHFFailureCaption.text(for: sentence)
        #expect(text != sentence)
        #expect(text != RobotHFFailureCaption.general)
    }

    @Test("text it does not know is replaced, and so is none at all", arguments: [
        "401 Client Error: Unauthorized for url: https://huggingface.co/oauth/token?code=abc",
        "",
        nil,
    ] as [String?])
    func replacesUnknownText(message: String?) {
        #expect(RobotHFFailureCaption.text(for: message) == RobotHFFailureCaption.general)
    }
}
