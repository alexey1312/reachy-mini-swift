import ReachyKit

#if os(iOS) || os(visionOS)
    import AVFAudio
#else
    import AVFoundation
#endif

/// Whether this app may record — read without asking, and asked when the user says to.
///
/// It lives here rather than in `ReachyKit` for a linking reason, not a tidiness one:
/// `ReachyKit` is linked by the widget extension, and a process woken for a moment to
/// draw two lines of text has no business loading AVFoundation. `CameraSession` is the
/// only thing that records, so the permission belongs beside it.
///
/// The platform fork is the one `CameraSession` already carried: iOS and visionOS answer
/// through `AVAudioApplication`, everything else through `AVCaptureDevice`. They do not offer the
/// same states — `AVAudioApplication.recordPermission` has no `restricted` — so the
/// mapping is written twice rather than unified into a lie.
public enum MicrophonePermission {
    /// Non-prompting. Safe to read on `onAppear`.
    public static var current: PermissionState {
        #if os(iOS) || os(visionOS)
            switch AVAudioApplication.shared.recordPermission {
            case .granted: .granted
            case .denied: .denied
            case .undetermined: .undetermined
            @unknown default: .undetermined
            }
        #else
            state(for: AVCaptureDevice.authorizationStatus(for: .audio))
        #endif
    }

    /// Raises the system prompt if it has never been answered, then reports where that
    /// left things.
    ///
    /// It re-reads `current` instead of mapping the returned `Bool`, and that is the
    /// whole point of the function. A **restricted** device returns `false` too, and
    /// calling that "denied" would send someone to a Settings toggle they are not
    /// allowed to move — the one outcome worse than saying nothing.
    public static func request() async -> PermissionState {
        #if os(iOS) || os(visionOS)
            _ = await AVAudioApplication.requestRecordPermission()
        #else
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        #endif
        return current
    }

    #if !os(iOS) && !os(visionOS)
        static func state(for status: AVAuthorizationStatus) -> PermissionState {
            switch status {
            case .authorized: .granted
            case .denied: .denied
            case .restricted: .restricted
            case .notDetermined: .undetermined
            @unknown default: .undetermined
            }
        }
    #endif
}
