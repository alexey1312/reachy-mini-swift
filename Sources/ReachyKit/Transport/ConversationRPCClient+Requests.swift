import Foundation

/// The ten verbs the conversation app answers, over the multiplexed socket in
/// ``ConversationRPCClient``.
///
/// Each is one line because the whole of the work — correlation, the deadline, the
/// failure vocabulary — belongs to the socket rather than to the verb.
public extension ConversationRPCClient {
    /// Kept as a name so the two shipped call sites and their tests still read
    /// `ConversationRPCClient.Failure.methodNotFound`. There is one failure type in
    /// this app and both transports throw it; this is the older spelling of it.
    typealias Failure = ConversationFailure

    func status() async throws -> ConversationBackendStatus {
        try await call("conversation.status", expecting: ConversationBackendStatus.self)
    }

    /// Reads the flag. **The parameters have to be empty**: the app writes the
    /// microphone whenever `muted` is present, so sending `{"muted": false}` to find
    /// out the state would unmute the robot on the way past.
    func microphoneMuted() async throws -> Bool {
        try await call("conversation.mic", expecting: ConversationMicrophoneReply.self).muted
    }

    /// Mutes or unmutes the **robot's** microphone — nothing on this device is
    /// recording, so this switches somebody else's input off.
    @discardableResult
    func setMicrophoneMuted(_ muted: Bool) async throws -> Bool {
        try await call(
            "conversation.mic",
            params: ["muted": .bool(muted)],
            expecting: ConversationMicrophoneReply.self
        ).muted
    }

    /// Stops the robot mid-sentence. The reason the dock has a button at all: a
    /// robot talking over you is answered faster from a phone than by shouting.
    func interrupt() async throws {
        try await call("conversation.interrupt")
    }

    /// Gives the robot something to respond to — not something to read out. See
    /// ``ConversationChannel/say(_:)`` for why that distinction has to survive into
    /// every name above this one.
    func say(_ text: String) async throws {
        try await call("conversation.say", params: ["text": .string(text)])
    }

    func personalities() async throws -> ConversationPersonalities {
        try await call("personalities.list", expecting: ConversationPersonalities.self)
    }

    @discardableResult
    func applyPersonality(named name: String, persist: Bool, force: Bool) async throws -> ConversationApplyResult {
        try await call(
            "personalities.apply",
            params: ["name": .string(name), "persist": .bool(persist), "force": .bool(force)],
            expecting: ConversationApplyResult.self
        )
    }

    func voices() async throws -> [String] {
        try await call("voices.list", expecting: [String].self)
    }

    func currentVoice() async throws -> String? {
        try await call("voices.current", expecting: ConversationVoiceReply.self).voice
    }

    @discardableResult
    func applyVoice(_ voice: String) async throws -> ConversationApplyResult {
        try await call("voices.apply", params: ["voice": .string(voice)], expecting: ConversationApplyResult.self)
    }
}
