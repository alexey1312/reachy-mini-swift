#if DEBUG
    import Foundation

    /// Same reason as the soundboard and presence conformances beside it:
    /// ``RobotSession/canControlConversation`` asks the client whether it speaks this
    /// protocol, so without this the conversation link is missing from **every**
    /// captured `App detail —` reference and the gate it is meant to prove is covered
    /// by nothing at all.
    ///
    /// The channel is inert. A preview must be final on its first frame, so no screen
    /// here waits on a stream: `ConversationModel.preview(…)` sets its transcript
    /// directly. What this double is for is the gate, the storybook, and anything that
    /// runs a live `load` against it.
    extension PreviewRobotClient: ConversationClient {
        public func makeConversation(port _: Int?) throws -> any ConversationChannel {
            PreviewConversationChannel()
        }
    }

    /// A conversation that answers plausibly and says nothing.
    ///
    /// The stream finishes immediately rather than staying open: a preview that waited
    /// would capture whatever frame it happened to reach, and there is nothing to wait
    /// for anyway. Every verb succeeds — a preview of a conversation is a preview of
    /// one that works, and the failure states are reached by injecting a model in that
    /// state, never by making this double fail.
    struct PreviewConversationChannel: ConversationChannel {
        func events() -> AsyncStream<ConversationEvent> {
            let (stream, continuation) = AsyncStream.makeStream(of: ConversationEvent.self)
            continuation.finish()
            return stream
        }

        func status() async throws -> ConversationBackendStatus {
            ConversationBackendStatus(canProceed: true, isConnected: true, connectionState: "connected")
        }

        func microphoneMuted() async throws -> Bool {
            false
        }

        @discardableResult
        func setMicrophoneMuted(_ muted: Bool) async throws -> Bool {
            muted
        }

        func interrupt() async throws {}

        func say(_: String) async throws {}

        func personalities() async throws -> ConversationPersonalities {
            ConversationPersonalities(
                choices: ["default", "noir_detective", "victorian_butler"],
                current: "default",
                startup: "default"
            )
        }

        @discardableResult
        func applyPersonality(named _: String, persist _: Bool, force _: Bool) async throws
            -> ConversationApplyResult
        {
            ConversationApplyResult(status: "Personality applied.")
        }

        func voices() async throws -> [String] {
            ["alloy", "verse", "coral"]
        }

        func currentVoice() async throws -> String? {
            "alloy"
        }

        @discardableResult
        func applyVoice(_: String) async throws -> ConversationApplyResult {
            ConversationApplyResult(status: "Voice applied.")
        }

        func close() async {}
    }
#endif
