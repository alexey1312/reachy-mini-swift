import ReachyKit
import Speech

/// Whether this app may turn speech into text — read without asking, and asked when the
/// user says to.
///
/// Beside `MicrophonePermission` for the same linking reason: the widget links
/// `ReachyKit`, and a process woken to draw two lines of text has no business loading
/// the Speech framework. `DeviceDictation` is the only thing that transcribes.
///
/// Unlike the microphone, Speech reports `restricted` on both platforms, so there is one
/// mapping rather than two.
public enum SpeechRecognitionPermission {
    /// Non-prompting. Safe to read on `onAppear`.
    public static var current: PermissionState {
        state(for: SFSpeechRecognizer.authorizationStatus())
    }

    /// Raises the system prompt if it has never been answered, then reports where that
    /// left things.
    ///
    /// The callback arrives on a queue of Speech's own choosing, so it is `@Sendable`
    /// and touches nothing but the continuation — built here, in a nonisolated
    /// function, so no caller's isolation is inferred onto it.
    public static func request() async -> PermissionState {
        typealias Answer = CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>
        let status = await withCheckedContinuation { (continuation: Answer) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
        return state(for: status)
    }

    static func state(for status: SFSpeechRecognizerAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .undetermined
        @unknown default: .undetermined
        }
    }
}
