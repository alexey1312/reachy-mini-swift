import Foundation
import Observation

// A platform fork, not a version gate: LiveCommunicationKit is
// `@available(macOS, unavailable)` outright — there is no macOS floor bump that
// brings it back, unlike the Control Centre widgets' `#if os(iOS)`. The public
// surface below is cross-platform so no caller carries an `#if` of its own; on
// macOS every method degrades to the direct microphone toggle this app always
// had.
#if os(iOS)
    @preconcurrency import AVFAudio
    @preconcurrency import LiveCommunicationKit
    import OSLog
    import UIKit
#endif

/// Frames the two-way WebRTC session as a system call (issue #78): Recents,
/// Lock Screen, Dynamic Island — the system call UI only, `CameraSession` keeps
/// doing the media work.
///
/// Every decision lives in `CallLifecycle`, which is tested; this class is the
/// adapter over `ConversationManager` and is untested by design — the framework
/// only stands up on a device, the same trade `WebRTCDataChannel` documents.
///
/// The `ConversationManager` is created **lazily on the first call start**,
/// never at construction: previews, the snapshot suite and the storybook all
/// build the view tree that owns this controller, and registering with the
/// system's call service from a snapshot run is exactly the class of side
/// effect `CameraSession.deinit`'s guard exists to prevent.
@MainActor
@Observable
public final class RobotCallController {
    /// The call the system is currently showing, if any.
    public struct ActiveCall: Equatable, Sendable {
        /// `RobotIdentity.deduplicationKey` — rule 4, identity never an address.
        public let robotID: String
        public let robotName: String?
    }

    public private(set) var activeCall: ActiveCall?

    /// Bumped once per started call, after the system accepted it — the moment
    /// the start-call intent should be donated. The UI layer watches this and
    /// reads `activeCall` for the who.
    public private(set) var donationCount = 0

    public var hasActiveCall: Bool {
        activeCall != nil
    }

    /// True from the tap that asks for the microphone until the call is over —
    /// the window `hasActiveCall` misses, because `activeCall` fills only once the
    /// system has handed the start back. Suspending the viewport in that window
    /// destroys the `CameraSession` the call is placed over; the reasoning is in
    /// `ReachyMedia/AGENTS.md`. `activeCall` stays the answer to *who* is called.
    public private(set) var keepsSessionAlive = false

    @ObservationIgnored private var currentRobotID: String?
    @ObservationIgnored private var currentRobotName: String?

    public init() {}

    #if DEBUG
        /// A controller that reports an active call without touching the system's
        /// call service. `activeCall` is otherwise only written from a
        /// `ConversationManager` callback, which needs a device — so this is the
        /// only way a preview can capture the End button at all.
        public static func preview(robotName: String? = nil) -> RobotCallController {
            let controller = RobotCallController()
            controller.activeCall = ActiveCall(robotID: "preview-robot", robotName: robotName)
            return controller
        }
    #endif

    /// Keeps the controller pointed at the connected robot; a robot change under
    /// an active call ends the call — the far side of it is gone.
    public func robotChanged(id: String?, name: String?) {
        currentRobotID = id
        currentRobotName = name
        #if os(iOS)
            if let activeCall, activeCall.robotID != id {
                run(lifecycle.handle(.sessionBecameIneligible(.remoteEnded)))
            }
            // Warm the manager the moment a real robot connects, not at the
            // first tap: Apple's guidance is to create it early in the app's
            // life, and creating it inside the tap's own start raced the
            // system's registration on a device. This path never runs from
            // previews or the storybook — `RootCallLifecycle` only calls
            // `robotChanged` outside preview mode — so the snapshot-safety
            // argument for laziness survives intact.
            if id != nil, manager == nil {
                _ = ensureManager()
            }
        #endif
    }

    /// The mic button's one entry point. On iOS an unmute with no call *is*
    /// placing the call; a toggle during one routes through the system so the
    /// Lock Screen's mute state stays in step. On macOS there is no system call
    /// UI and this is the direct toggle it always was.
    public func toggleMic(for session: CameraSession) {
        #if os(iOS)
            self.session = session
            run(lifecycle.handle(session.isMicEnabled ? .muteTapped : .unmuteTapped))
        #else
            session.setMicEnabled(!session.isMicEnabled)
        #endif
    }

    /// The redial path: a Recents tap or the Siri phrase landed, the stream is
    /// up, unmute as if the button had been tapped.
    public func startCall(for session: CameraSession) {
        #if os(iOS)
            guard !session.isMicEnabled else { return }
            self.session = session
            run(lifecycle.handle(.unmuteTapped))
        #else
            session.setMicEnabled(true)
        #endif
    }

    /// Ends the call from inside the app — the red button beside the microphone.
    /// It exists because ending used to belong to the system UI alone, which iOS
    /// does not draw over the app owning the call; `ReachyMedia/AGENTS.md` has it.
    public func endCall() {
        #if os(iOS)
            run(lifecycle.handle(.endTapped))
        #endif
        // No macOS branch: no call ever becomes active there, so nothing draws.
    }

    /// The session under the call went away — robot asleep or disconnected,
    /// stream failed, viewport target gone. `failed` picks the reason the
    /// system shows; a sleeping robot ended the call, it did not fail it.
    public func sessionBecameIneligible(failed: Bool) {
        #if os(iOS)
            run(lifecycle.handle(.sessionBecameIneligible(failed ? .failed : .remoteEnded)))
        #endif
    }

    #if os(iOS)
        /// The whole start chain logs here, because it shipped once with every
        /// failure swallowed: the system refused the start, nothing was
        /// written anywhere, and the mic button read as dead. Read it in
        /// Console with subsystem `com.alexey1312.ReachyMini`.
        private static let log = Logger(subsystem: "com.alexey1312.ReachyMini", category: "RobotCall")

        @ObservationIgnored private var lifecycle = CallLifecycle()
        @ObservationIgnored private var manager: ConversationManager?
        @ObservationIgnored private var delegateAdapter: ConversationDelegateAdapter?
        @ObservationIgnored private weak var session: CameraSession?
        /// The system action currently being performed; consumed by the
        /// `fulfillPendingAction` / `failPendingAction` effects.
        @ObservationIgnored private var pendingSystemAction: ConversationAction?
        @ObservationIgnored private var conversationUUID: UUID?
        /// Who the in-flight start is calling; promoted to `activeCall` when the
        /// system hands the start back to perform.
        @ObservationIgnored private var pendingRobot: ActiveCall?

        // MARK: - Reducer effects

        private func run(_ effects: [CallLifecycle.Effect]) {
            for effect in effects {
                perform(effect)
            }
            // Postcondition, not an effect: `activeCall` mirrors the reducer's
            // state so the keep-alive and the donation watcher read one truth.
            if lifecycle.state != .active {
                activeCall = nil
                if lifecycle.state == .idle {
                    conversationUUID = nil
                    pendingRobot = nil
                }
            }
            keepsSessionAlive = lifecycle.state != .idle
        }

        private func perform(_ effect: CallLifecycle.Effect) {
            switch effect {
            case .requestMicPermissionThenStart:
                requestMicPermissionThenStart()
            case let .performMuteAction(isMuted):
                performMuteAction(isMuted: isMuted)
            case .performEndAction:
                performEndAction()
            case let .applyMic(enabled):
                session?.setMicEnabled(enabled)
            case .fulfillPendingAction:
                pendingSystemAction?.fulfill()
                pendingSystemAction = nil
            case .failPendingAction:
                pendingSystemAction?.fail()
                pendingSystemAction = nil
            case .takeAudioOwnership:
                MediaAudioSession.shared.callWillStart()
            case .donate:
                donationCount += 1
            // One branch for the three reporting effects: a one-case-per-effect
            // funnel walks into SwiftLint's cyclomatic ceiling as the reducer grows.
            case .reportStartedConnecting, .reportConnected, .reportEnded:
                performReport(effect)
            }
        }

        private func performReport(_ effect: CallLifecycle.Effect) {
            switch effect {
            case .reportStartedConnecting:
                report(.conversationStartedConnecting(Date()))
            case .reportConnected:
                report(.conversationConnected(Date()))
            case let .reportEnded(cause):
                Self.log.notice("Ending the call: \(String(describing: cause), privacy: .public)")
                report(.conversationEnded(Date(), cause == .failed ? .failed : .remoteEnded))
            default:
                break
            }
        }

        private func requestMicPermissionThenStart() {
            Task { @MainActor in
                let permission = await MicrophonePermission.request()
                guard permission == .granted else {
                    Self.log.notice("Start abandoned: microphone permission refused")
                    // Surfaces the existing blocked-button state on the viewport.
                    session?.refreshMicPermission()
                    run(lifecycle.handle(.micPermissionDenied))
                    return
                }
                await performStart()
            }
        }

        private func performStart() async {
            guard let robotID = currentRobotID else {
                Self.log.error("Start failed: no connected robot identity to call")
                run(lifecycle.handle(.startFailed))
                return
            }
            let uuid = UUID()
            conversationUUID = uuid
            pendingRobot = ActiveCall(robotID: robotID, robotName: currentRobotName)
            let handle = Handle(type: .generic, value: robotID, displayName: currentRobotName)
            let action = StartConversationAction(conversationUUID: uuid, handles: [handle], isVideo: true)
            // `.notice`, not `.debug`: the log store drops debug by default, so
            // the one line saying a start was attempted was unreadable in the
            // field report this logging exists for.
            Self.log.notice("Performing StartConversationAction \(uuid, privacy: .public)")
            do {
                try await ensureManager().perform([action])
            } catch {
                Self.log.error("""
                The system refused the start: \(String(describing: error), privacy: .public) — \
                falling back to the bare microphone
                """)
                run(lifecycle.handle(.startFailed))
            }
        }

        private func performMuteAction(isMuted: Bool) {
            guard let uuid = conversationUUID else { return }
            let action = MuteConversationAction(conversationUUID: uuid, isMuted: isMuted)
            Self.log.notice("Requesting mute isMuted=\(isMuted, privacy: .public) on \(uuid, privacy: .public)")
            Task { @MainActor in
                do {
                    try await ensureManager().perform([action])
                } catch {
                    Self.log.warning(
                        "Mute action refused: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }

        /// The mirror of `performMuteAction`, and it owes the lesson #112 left
        /// behind: a refusal that goes nowhere is a button that does nothing.
        /// If the system will not take the end, close the call here rather than
        /// leave somebody tapping a dead control.
        private func performEndAction() {
            guard let uuid = conversationUUID else { return }
            let action = EndConversationAction(conversationUUID: uuid)
            Self.log.notice("Requesting end on \(uuid, privacy: .public)")
            Task { @MainActor in
                do {
                    try await ensureManager().perform([action])
                } catch {
                    let reason = String(describing: error)
                    Self.log.error("The system refused the end: \(reason, privacy: .public); closing locally")
                    run(lifecycle.handle(.sessionBecameIneligible(.remoteEnded)))
                }
            }
        }

        private func report(_ event: Conversation.Event) {
            guard let manager, let uuid = conversationUUID,
                  let conversation = manager.conversations.first(where: { $0.uuid == uuid })
            else { return }
            manager.reportConversationEvent(event, for: conversation)
        }

        // MARK: - Delegate arrivals (hopped to the main actor by the adapter)

        // Package-internal, not `fileprivate`: the adapter is a file of its own now.

        func handle(action: ConversationAction) {
            pendingSystemAction = action
            let effects: [CallLifecycle.Effect] = switch action {
            case is StartConversationAction:
                lifecycle.handle(.performedStart)
            case let mute as MuteConversationAction:
                lifecycle.handle(.performedMute(isMuted: mute.isMuted))
            case is EndConversationAction:
                lifecycle.handle(.performedEnd)
            default:
                refuseUnexpected(action)
            }
            run(effects)
            // The success path wrote nothing at all, so a call that started and
            // died seconds later left no trace anywhere.
            let performed = Self.describe(action)
            let state = String(describing: lifecycle.state)
            Self.log.notice("Performed \(performed, privacy: .public); the call is now \(state, privacy: .public)")
            if lifecycle.state == .active, activeCall == nil {
                activeCall = pendingRobot
            }
            // An action the reducer neither fulfilled nor failed would hang the
            // system UI until its timeout; there is no such path, but the slot
            // must not leak an action into the next arrival either way.
            pendingSystemAction = nil
        }

        /// Join/merge/pause never arrive for an outgoing-only app; refuse
        /// anything unrecognised rather than leave it to time out.
        private func refuseUnexpected(_ action: ConversationAction) -> [CallLifecycle.Effect] {
            Self.log.warning(
                "Refusing unexpected action \(String(describing: type(of: action)), privacy: .public)"
            )
            return [.failPendingAction]
        }

        /// A mute arrives twice per tap; without `isMuted` a duplicate delivery
        /// and an echo of the app's own request read identically in the log.
        private static func describe(_ action: ConversationAction) -> String {
            guard let mute = action as? MuteConversationAction else {
                return String(describing: type(of: action))
            }
            return "MuteConversationAction(isMuted: \(mute.isMuted))"
        }

        func handleTimeout(of action: ConversationAction) {
            Self.log.error("Action timed out: \(Self.describe(action), privacy: .public)")
            if action is StartConversationAction {
                run(lifecycle.handle(.startFailed))
            }
            action.fail()
        }

        func handleManagerReset() {
            Self.log.warning("Conversation manager reset")
            run(lifecycle.handle(.managerReset))
        }

        func handleAudioActivated(_ audioSession: AVAudioSession) {
            MediaAudioSession.shared.callDidActivate(audioSession)
        }

        func handleAudioDeactivated(_ audioSession: AVAudioSession) {
            MediaAudioSession.shared.callDidDeactivate(
                audioSession,
                cameraStillRunning: session?.isRunning ?? false
            )
        }

        // MARK: - The manager

        private func ensureManager() -> ConversationManager {
            if let manager {
                return manager
            }
            let configuration = ConversationManager.Configuration(
                // Outgoing only: `reportNewIncomingConversation` is never called,
                // so nothing ever rings.
                ringtoneName: nil,
                iconTemplateImageData: UIImage(systemName: "video.fill")?.pngData(),
                maximumConversationGroups: 1,
                maximumConversationsPerConversationGroup: 1,
                includesConversationInRecents: true,
                supportsVideo: true,
                supportedHandleTypes: [.generic]
            )
            let manager = ConversationManager(configuration: configuration)
            let adapter = ConversationDelegateAdapter(owner: self)
            manager.delegate = adapter
            delegateAdapter = adapter
            self.manager = manager
            return manager
        }
    #endif
}
