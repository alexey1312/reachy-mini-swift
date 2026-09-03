import Foundation

/// A robot app's `/rpc` surface over the data channel.
///
/// Daemon 1.10.0 routes JSON-RPC by namespace: it answers `apps.*` itself and relays
/// **everything else** to the running app's own `/rpc`, holding one connection to it
/// and re-broadcasting that app's notifications to every client. So this arm sends no
/// subscribe command of any kind — unlike ``RemoteDaemonLog``, whose `subscribe_logs`
/// is what starts the journal. Adding one here would be a frame the daemon answers
/// with silence.
///
/// No port is involved either: the daemon derives `ws://127.0.0.1:<port>/rpc` from the
/// same `custom_app_url` the LAN arm reads, from the other side of the wire.
struct RemoteConversation: ConversationChannel {
    /// The three the client consumes. `conversation.activity` and `conversation.phase`
    /// are deliberately absent — see ``ConversationEvent/decoded(from:)``.
    static let notificationMethods = [
        "conversation.turn",
        "conversation.transcript",
        "conversation.level",
    ]

    let control: RemoteControlChannel

    func events() -> AsyncStream<ConversationEvent> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: ConversationEvent.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        let pump = Task {
            let sources = await withTaskGroup(of: (Int, AsyncStream<Data>).self) { group in
                for (index, method) in Self.notificationMethods.enumerated() {
                    group.addTask { await (index, control.broadcasts(ofType: method)) }
                }
                var streams = [AsyncStream<Data>?](repeating: nil, count: Self.notificationMethods.count)
                for await (index, source) in group {
                    streams[index] = source
                }
                return streams.compactMap(\.self)
            }
            // The channel was open before this existed, so there is nothing to wait
            // for — but a consumer still needs the seam marked, and marking it in one
            // place on both arms is what lets a transcript treat them alike.
            continuation.yield(.opened)

            await withTaskGroup(of: Void.self) { group in
                for source in sources {
                    group.addTask {
                        for await data in source {
                            guard let event = ConversationEvent.decoded(from: data) else { continue }
                            continuation.yield(event)
                        }
                    }
                }
                // Every source is drained, unlike `RemoteDaemonLog`, which ends on the
                // first one because its two are a feed and that feed's own failure.
                // These three are one conversation: ending on whichever runs dry first
                // would take the transcript down at the first quiet moment.
                await group.waitForAll()
            }
            continuation.yield(.closed)
            continuation.finish()
        }
        continuation.onTermination = { _ in pump.cancel() }
        return stream
    }

    // MARK: Requests

    func status() async throws -> ConversationBackendStatus {
        try await call("conversation.status", expecting: ConversationBackendStatus.self)
    }

    func microphoneMuted() async throws -> Bool {
        // An empty object, and it has to be: `{"muted": false}` would *unmute* the
        // robot on what a caller asked for as a read.
        try await call("conversation.mic", expecting: ConversationMicrophoneReply.self).muted
    }

    @discardableResult
    func setMicrophoneMuted(_ muted: Bool) async throws -> Bool {
        try await call(
            "conversation.mic",
            params: ["muted": .bool(muted)],
            expecting: ConversationMicrophoneReply.self
        ).muted
    }

    func interrupt() async throws {
        try await call("conversation.interrupt")
    }

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
        try await call(
            "voices.apply",
            params: ["voice": .string(voice)],
            expecting: ConversationApplyResult.self
        )
    }

    /// The relay's data channel outlives every conversation on it, so there is
    /// nothing here to release — the distinction ``TeleopChannel`` draws.
    func close() async {}

    // MARK: -

    /// Both wrappers exist to turn the channel's vocabulary into the conversation's in
    /// one place. Without them every verb above would have to catch
    /// ``RemoteControlChannel/Failure`` itself, and a missed one would reach a screen
    /// as a sentence where it expected a code to branch on.
    private func call(_ method: String, params: [String: RemoteValue] = [:]) async throws {
        do {
            try await control.call(method, params: params)
        } catch let failure as RemoteControlChannel.Failure {
            throw ConversationFailure(relay: failure)
        }
    }

    private func call<Reply: Decodable & Sendable>(
        _ method: String,
        params: [String: RemoteValue] = [:],
        expecting: Reply.Type
    ) async throws -> Reply {
        do {
            return try await control.call(method, params: params, expecting: expecting)
        } catch let failure as RemoteControlChannel.Failure {
            throw ConversationFailure(relay: failure)
        } catch is DecodingError {
            // The app answered something this build cannot read. `.unreachable` is
            // the honest report: the call did not do what was asked and no reason
            // came back that a screen could show.
            throw ConversationFailure.unreachable
        }
    }
}
