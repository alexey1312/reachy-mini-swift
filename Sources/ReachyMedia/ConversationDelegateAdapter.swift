import Foundation

#if os(iOS)
    @preconcurrency import AVFAudio
    @preconcurrency import LiveCommunicationKit
#endif

#if os(iOS)
    /// Hops the manager's callbacks onto the main actor, the way
    /// `PeerConnectionDelegateAdapter` does for libwebrtc's. `NSObject` so the
    /// conformance holds whichever object protocol the delegate requires;
    /// `@unchecked Sendable` because the closures capture framework objects the
    /// SDK does not annotate.
    final class ConversationDelegateAdapter: NSObject, ConversationManagerDelegate, @unchecked Sendable {
        private weak var owner: RobotCallController?

        init(owner: RobotCallController) {
            self.owner = owner
        }

        func conversationManagerDidBegin(_ conversationManager: ConversationManager) {}

        func conversationManagerDidReset(_ conversationManager: ConversationManager) {
            Task { @MainActor [owner] in owner?.handleManagerReset() }
        }

        func conversationManager(
            _ conversationManager: ConversationManager, conversationChanged conversation: Conversation
        ) {}

        func conversationManager(
            _ conversationManager: ConversationManager, didActivate audioSession: AVAudioSession
        ) {
            Task { @MainActor [owner] in owner?.handleAudioActivated(audioSession) }
        }

        func conversationManager(
            _ conversationManager: ConversationManager, didDeactivate audioSession: AVAudioSession
        ) {
            Task { @MainActor [owner] in owner?.handleAudioDeactivated(audioSession) }
        }

        func conversationManager(
            _ conversationManager: ConversationManager, perform action: ConversationAction
        ) {
            Task { @MainActor [owner] in owner?.handle(action: action) }
        }

        func conversationManager(
            _ conversationManager: ConversationManager, timedOutPerforming action: ConversationAction
        ) {
            Task { @MainActor [owner] in owner?.handleTimeout(of: action) }
        }
    }
#endif
