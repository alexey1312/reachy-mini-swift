import Foundation
import OSLog
@preconcurrency import WebRTC

// iOS only: the audio *session* is an iOS concept. The fork is a platform fork,
// not a version gate — macOS has no AVAudioSession and never will; every body
// below is a no-op there so callers never carry an `#if` of their own
// (`MicrophonePermission` and `QuickActions.install()` set the shape).
#if os(iOS)
    import AVFAudio
#endif

/// The one owner of the audio session, and of `RTCAudioSession` with it.
///
/// It exists because two parties now want the session active: a camera session
/// playing the robot's audio (the app activates it itself, as it always did),
/// and a system call framed through LiveCommunicationKit (the *system* activates
/// it, and the app must keep its hands off `setActive` for the call's whole
/// life). `owner` says whose turn it is; `CameraSession` and
/// `RobotCallController` both talk to this type and never to
/// `AVAudioSession`/`RTCAudioSession` directly — keeping every
/// `RTCAudioSession` mention in this one file is what makes the handover
/// auditable.
///
/// WebRTC runs in manual-audio mode from the first touch (`useManualAudio` in
/// `init`, which `CameraSession.start()` reaches before any peer connection can
/// exist): libwebrtc no longer activates the session behind the app's back, and
/// `isAudioEnabled` is the explicit lever for its audio unit.
@MainActor
final class MediaAudioSession {
    static let shared = MediaAudioSession()

    enum Owner: Equatable, Sendable {
        /// No camera session is running and no call is active.
        case nobody
        /// A camera session is playing (and maybe recording); the app activated
        /// the session itself, exactly as it did before calls existed.
        case app
        /// A LiveCommunicationKit call is active; the system owns activation and
        /// reports it through the conversation manager's delegate.
        case call
    }

    private(set) var owner: Owner = .nobody

    #if os(iOS)
        /// The one audio transition in flight, if any — a deactivation retry
        /// after a stop, or a reclaim after a call ends. There is never a reason
        /// for two: each entry point cancels the previous one first, because a
        /// stop()'s retry loop left running would deactivate the session a
        /// fresh start just opened.
        private var transitionTask: Task<Void, Never>?

        private static let log = Logger(
            subsystem: "com.alexey1312.ReachyMini", category: "MediaAudioSession"
        )

        private init() {
            RTCAudioSession.sharedInstance().useManualAudio = true
        }
    #else
        private init() {}
    #endif

    // MARK: - Camera session lifecycle (from CameraSession)

    /// A camera session started: configure for two-way audio and, unless a call
    /// already owns activation, activate on the app's own authority.
    func cameraSessionStarted() {
        #if os(iOS)
            transitionTask?.cancel()
            transitionTask = nil
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker])
            if owner != .call {
                try? session.setActive(true)
                owner = .app
            }
            RTCAudioSession.sharedInstance().isAudioEnabled = true
        #endif
    }

    /// The mirror `cameraSessionStarted()` is owed: leaving the camera used to
    /// keep the app holding a record-category session — other apps' audio
    /// stayed ducked and the OS went on treating this one as a recorder.
    /// `.notifyOthersOnDeactivation` is what lets them resume.
    ///
    /// Under `.call` this is deliberately a no-op: the system owns activation
    /// for the call's whole life, and the deactivation arrives through
    /// `callDidDeactivate(_:cameraStillRunning:)` instead.
    func cameraSessionStopped() {
        #if os(iOS)
            guard owner != .call else { return }
            RTCAudioSession.sharedInstance().isAudioEnabled = false
            guard owner == .app else { return }
            owner = .nobody
            transitionTask?.cancel()
            transitionTask = Task { await Self.releaseAudioSession() }
        #endif
    }

    // MARK: - Call lifecycle (from RobotCallController)

    // The whole block is iOS-only, not just the bodies: `AVAudioSession` in a
    // *signature* is what does not compile on macOS — the camera methods above
    // fork inside because `CameraSession` calls them from cross-platform code,
    // while everything below has exactly one caller and it is `#if os(iOS)`
    // itself.
    #if os(iOS)
        /// A call is about to be reported: from here until the call ends the
        /// system owns activation, so any in-flight transition of the app's is
        /// stale.
        func callWillStart() {
            transitionTask?.cancel()
            transitionTask = nil
            owner = .call
        }

        /// The system activated the call's audio session — hand it to WebRTC.
        func callDidActivate(_ session: AVAudioSession) {
            let rtc = RTCAudioSession.sharedInstance()
            rtc.audioSessionDidActivate(session)
            rtc.isAudioEnabled = true
        }

        /// The call ended and the system deactivated its session. A camera
        /// session still running goes back to app ownership (the
        /// passive-viewing shape); otherwise audio winds down entirely.
        func callDidDeactivate(_ session: AVAudioSession, cameraStillRunning: Bool) {
            RTCAudioSession.sharedInstance().audioSessionDidDeactivate(session)
            guard owner == .call else { return }
            if cameraStillRunning {
                owner = .app
                transitionTask?.cancel()
                transitionTask = Task { await Self.reclaimForApp() }
            } else {
                RTCAudioSession.sharedInstance().isAudioEnabled = false
                owner = .nobody
            }
        }
    #endif

    #if os(iOS)
        /// `setActive(false)` races WebRTC's own audio unit, which winds down on
        /// a background thread after the caller has already returned —
        /// deactivating immediately commonly fails "session is busy", and a
        /// `try?` there made the release silently not happen. So: retry
        /// briefly, and log when the OS still refuses, because a swallowed
        /// failure looks exactly like the ducked-audio bug this method exists
        /// to end.
        private static func releaseAudioSession() async {
            for _ in 0 ..< 5 {
                do {
                    try AVAudioSession.sharedInstance().setActive(
                        false,
                        options: [.notifyOthersOnDeactivation]
                    )
                    return
                } catch {
                    guard await (try? Task.sleep(for: .milliseconds(200))) != nil else { return }
                }
            }
            log.warning("Audio session would not deactivate; other apps' audio may stay ducked")
        }

        /// The reverse race, after a call ends with the camera still up: the
        /// system has just deactivated the call's session, and re-activating the
        /// app's own can briefly refuse while that settles. Same retry shape.
        private static func reclaimForApp() async {
            for _ in 0 ..< 5 {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    return
                } catch {
                    guard await (try? Task.sleep(for: .milliseconds(200))) != nil else { return }
                }
            }
            log.warning("Audio session would not reactivate after the call; robot audio may stay silent")
        }
    #endif
}
