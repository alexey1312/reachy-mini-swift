import Foundation

/// A connection that can reach a robot app's own JSON-RPC control surface.
///
/// Both transports can, by genuinely different means — a WebSocket straight to the
/// app's port over the LAN, the daemon's `jsonrpc_relay` over the WebRTC data channel
/// — so a screen talks to a conversation without knowing which one it is on.
/// Conforming *is* the capability; nothing above this branches on the link.
public protocol ConversationClient: Sendable {
    /// - Parameter port: the app's own port, from ``RobotApp/customAppPort``.
    ///
    ///   **The LAN arm dials it and the relay arm ignores it**, and that asymmetry is
    ///   the daemon's rather than this client's: over the relay the daemon holds
    ///   `ws://127.0.0.1:<port>/rpc` itself, derived from the very same
    ///   `custom_app_url`. The two arms read one daemon field from opposite sides of
    ///   the wire. `ConversationRPCClient.Configuration.fallbackPort` is a LAN value
    ///   for the same reason — it is a guess about where an app binds, and the relay
    ///   has nothing to guess about.
    func makeConversation(port: Int?) throws -> any ConversationChannel
}

/// One open conversation: what the app says unasked, and the verbs it answers.
///
/// A channel rather than nine loose methods, and the difference is who holds what for
/// how long. `SoundboardClient`'s verbs are independent HTTP calls, so a protocol of
/// bare methods is right there. Here nine verbs and a stream share one socket over the
/// LAN, and a screen that keeps the channel for its lifetime pays for one connection
/// while a dock tapping a button pays for one per tap. ``TeleopChannel`` is the
/// precedent for exactly that.
public protocol ConversationChannel: Sendable {
    /// Everything the app pushes, merged and in arrival order.
    func events() -> AsyncStream<ConversationEvent>

    /// Whether the app has a voice backend it can talk through. Configuration rather
    /// than state — see ``ConversationBackendStatus``.
    func status() async throws -> ConversationBackendStatus

    /// Whether the **robot's** microphone is muted. Nothing on this device records.
    func microphoneMuted() async throws -> Bool
    /// - Returns: the flag the app settled on, which is what a caller should render.
    ///   A button showing a state the robot never reached is worse than one that did
    ///   nothing.
    @discardableResult
    func setMicrophoneMuted(_ muted: Bool) async throws -> Bool

    /// Stops the robot mid-sentence.
    func interrupt() async throws

    /// Gives the robot something to respond to.
    ///
    /// **Not text-to-speech, and the difference is worth carrying in every name above
    /// this one.** The app injects the text as a *user* message and asks the model to
    /// answer it — its own implementation says "Not verbatim TTS (speech-to-speech may
    /// rephrase)". The robot does not read the words out, and they never come back as
    /// a transcript line, because only audio transcription produces those. It also
    /// barges in: the app clears whatever is queued for the speaker first.
    func say(_ text: String) async throws

    func personalities() async throws -> ConversationPersonalities
    @discardableResult
    func applyPersonality(named name: String, persist: Bool, force: Bool) async throws -> ConversationApplyResult

    func voices() async throws -> [String]
    func currentVoice() async throws -> String?
    @discardableResult
    func applyVoice(_ voice: String) async throws -> ConversationApplyResult

    /// Releases whatever the channel holds.
    ///
    /// The relay's is a no-op: the data channel was open long before a conversation
    /// existed and outlives it — the same distinction ``TeleopChannel`` draws between
    /// a transport and a session on it.
    func close() async
}

public extension ConversationChannel {
    /// The turn states alone, for a caller that only wants a caption.
    ///
    /// Filtering is what the single merged stream buys: this cannot fall out of step
    /// with the transcript, because both are the same sequence read twice.
    func turns() -> AsyncStream<ConversationTurn> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: ConversationTurn.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let task = Task {
            for await event in events() where !Task.isCancelled {
                guard case let .turn(turn) = event else { continue }
                continuation.yield(turn)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

extension RobotConnection: ConversationClient {
    public nonisolated func makeConversation(port: Int?) throws -> any ConversationChannel {
        try ConversationRPCClient(address: address, port: port)
    }
}

extension RemoteRobotConnection: ConversationClient {
    public nonisolated func makeConversation(port _: Int?) throws -> any ConversationChannel {
        RemoteConversation(control: control)
    }
}

public extension RobotSession {
    /// Whether this transport carries a robot app's `/rpc` surface.
    ///
    /// Composed the way ``canControlRunningApp`` is, and for the same reason: daemon
    /// 1.9.0 mounts no `jsonrpc_relay`, so a relayed robot on it answers none of these
    /// verbs and each one would spend a whole reply budget finding that out.
    ///
    /// It answers a question about the *transport*, never about whether a conversation
    /// is available — that depends on an app running, on a key being configured, and on
    /// a backend that may be ninety seconds from ready, none of which a transport knows.
    /// The app-identity half (``RobotApp/exposesConversationRPC``) belongs at the call
    /// site, where an app is in hand.
    var canControlConversation: Bool {
        client is any ConversationClient && !predatesRelayCommands
    }

    /// A channel to the app's control surface, for a caller that will hold it.
    func makeConversation(for app: RobotApp) throws -> any ConversationChannel {
        guard let client else { throw ReachyKitError.notConnected }
        guard let conversation = client as? any ConversationClient else {
            throw ReachyKitError.conversationUnavailable
        }
        return try conversation.makeConversation(port: app.customAppPort)
    }

    /// One call on a channel of its own, for a caller that will not.
    ///
    /// Throws and files nothing: a conversation failure belongs to the screen that
    /// asked for it, and ``robotError`` is connection and power alone.
    func withConversation<T>(
        for app: RobotApp,
        _ call: (any ConversationChannel) async throws -> T
    ) async throws -> T {
        let channel = try makeConversation(for: app)
        defer { Task { await channel.close() } }
        return try await call(channel)
    }
}

/// The one-shot verbs, for callers that will not hold a channel — the dock's two
/// buttons, and an App Intent.
///
/// Each opens a channel, calls, and closes it. Over the LAN that is one socket per
/// call, which is the right shape for a button somebody presses now and then; a screen
/// that wants one socket for its lifetime takes ``RobotSession/makeConversation(for:)``
/// instead. Over the relay it costs nothing either way — the data channel is already
/// there.
public extension RobotSession {
    /// Everything the app pushes.
    func conversationEvents(for app: RobotApp) throws -> AsyncStream<ConversationEvent> {
        try makeConversation(for: app).events()
    }

    /// The turn states alone. Signature unchanged from when this was the only thing
    /// this client read off the app's surface, so the dock needed no edit.
    func conversationTurns(for app: RobotApp) throws -> AsyncStream<ConversationTurn> {
        try makeConversation(for: app).turns()
    }

    func conversationStatus(for app: RobotApp) async throws -> ConversationBackendStatus {
        try await withConversation(for: app) { try await $0.status() }
    }

    func conversationMicrophoneMuted(for app: RobotApp) async throws -> Bool {
        try await withConversation(for: app) { try await $0.microphoneMuted() }
    }

    /// Mutes the **robot's** microphone.
    ///
    /// - Returns: the flag the app settled on. A caller should render this rather than
    ///   what it asked for — a button showing a state the robot never reached is worse
    ///   than one that did nothing.
    @discardableResult
    func setConversationMicrophoneMuted(_ muted: Bool, for app: RobotApp) async throws -> Bool {
        try await withConversation(for: app) { try await $0.setMicrophoneMuted(muted) }
    }

    /// Stops the robot mid-sentence.
    func interruptConversation(for app: RobotApp) async throws {
        try await withConversation(for: app) { try await $0.interrupt() }
    }

    /// Gives the robot something to respond to. Not text to read out — see
    /// ``ConversationChannel/say(_:)``.
    func sayInConversation(_ text: String, for app: RobotApp) async throws {
        try await withConversation(for: app) { try await $0.say(text) }
    }

    func conversationPersonalities(for app: RobotApp) async throws -> ConversationPersonalities {
        try await withConversation(for: app) { try await $0.personalities() }
    }

    @discardableResult
    func applyConversationPersonality(
        named name: String,
        persist: Bool,
        force: Bool = false,
        for app: RobotApp
    ) async throws -> ConversationApplyResult {
        try await withConversation(for: app) {
            try await $0.applyPersonality(named: name, persist: persist, force: force)
        }
    }

    func conversationVoices(for app: RobotApp) async throws -> [String] {
        try await withConversation(for: app) { try await $0.voices() }
    }

    func currentConversationVoice(for app: RobotApp) async throws -> String? {
        try await withConversation(for: app) { try await $0.currentVoice() }
    }

    @discardableResult
    func applyConversationVoice(_ voice: String, for app: RobotApp) async throws -> ConversationApplyResult {
        try await withConversation(for: app) { try await $0.applyVoice(voice) }
    }
}
