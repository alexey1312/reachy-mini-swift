import Foundation
@testable import ReachyKit
import Testing

/// The conversation over the daemon's JSON-RPC relay — the half of #70 that cannot be
/// exercised against a robot without one, and the half every screen depends on being
/// indistinguishable from the LAN one.
///
/// Built on a real ``RemoteControlChannel`` over ``FakeDataChannel`` rather than on a
/// double for the channel, because the routing under test — `Envelope` deciding that a
/// frame with a `method` and no `id` is a notification — lives in the real one.
@Suite("Remote conversation", .timeLimit(.minutes(1)))
struct RemoteConversationTests {
    private func conversation(
        _ replies: [String: String] = [:]
    ) -> (RemoteConversation, FakeDataChannel) {
        let fake = FakeDataChannel(replies: replies, isOpen: true)
        let control = RemoteControlChannel(channel: fake, timeout: .seconds(5), openingTimeout: .seconds(5))
        return (RemoteConversation(control: control), fake)
    }

    // MARK: Notifications

    /// **The relay sends nothing to subscribe with, and that is the difference from
    /// `RemoteDaemonLog`.** It holds one connection to the app's `/rpc` and re-broadcasts
    /// every frame that arrives on it to all clients, unasked. Without this assertion the
    /// next reader adds a `subscribe_conversation` by analogy, and the daemon answers it
    /// with silence — a bug whose only symptom is a screen that stays empty.
    @Test("subscribing sends no command at all")
    func subscribesWithoutAsking() async {
        let (conversation, fake) = conversation()

        var events = conversation.events().makeAsyncIterator()
        #expect(await events.next() == .opened)
        await waitUntil("the channel is being read") { fake.isListening }
        fake.emit(
            #"{"jsonrpc":"2.0","method":"conversation.transcript","#
                + #""params":{"role":"user","text":"Hello","final":true}}"#
        )

        #expect(await events.next() == .transcript(ConversationLine(role: .user, text: "Hello")))
        #expect(fake.sent.isEmpty)
    }

    /// One stream carries all three, and — unlike `RemoteDaemonLog`, which ends on
    /// whichever of its two sources finishes first — none of them can end the others.
    /// Copying that shape here would take the transcript down at the first quiet moment.
    @Test("all three notification kinds arrive on one stream")
    func mergesEveryNotificationKind() async {
        let (conversation, fake) = conversation()

        var events = conversation.events().makeAsyncIterator()
        #expect(await events.next() == .opened)
        await waitUntil("the channel is being read") { fake.isListening }

        fake.emit(#"{"jsonrpc":"2.0","method":"conversation.turn","params":{"state":"speaking"}}"#)
        fake.emit(#"{"jsonrpc":"2.0","method":"conversation.level","params":{"role":"assistant","rms":0.5}}"#)
        fake.emit(
            #"{"jsonrpc":"2.0","method":"conversation.transcript","#
                + #""params":{"role":"assistant","text":"Happy birthday.","final":true}}"#
        )

        var seen: Set<String> = []
        for _ in 0 ..< 3 {
            switch await events.next() {
            case .turn: seen.insert("turn")
            case .level: seen.insert("level")
            case .transcript: seen.insert("transcript")
            default: break
            }
        }
        #expect(seen == ["turn", "level", "transcript"])
    }

    // MARK: Failures

    /// **The headline, and the whole of "prove the relay's error mapping without a
    /// robot".** Every one of these used to arrive as a single sentence with the code
    /// discarded, so the three screens they call for were one.
    @Test("an unknown method retires the control rather than reporting")
    func mapsMethodNotFound() async {
        let (conversation, fake) = conversation()

        let call = Task { try await conversation.say("hello") }
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"#)

        await #expect(throws: ConversationFailure.methodNotFound) { _ = try await call.value }
    }

    @Test("no app running is carried with its code and its reason")
    func mapsNotRunning() async throws {
        let (conversation, fake) = conversation()

        let call = Task { try await conversation.interrupt() }
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(
            #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"no app is running","#
                + #""data":{"reason":"not_running"}}}"#
        )

        await #expect(throws: ConversationFailure.rejected(
            code: -32000,
            reason: .notRunning,
            message: "no app is running"
        )) { _ = try await call.value }
    }

    /// The app is there and not answering — a different screen from the app being gone.
    @Test("an unreachable app is told apart from a missing one")
    func mapsAppUnavailable() async {
        let (conversation, fake) = conversation()

        let call = Task { try await conversation.interrupt() }
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(
            #"{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"app connection lost","#
                + #""data":{"reason":"app_unavailable"}}}"#
        )

        let failure = await #expect(throws: ConversationFailure.self) { _ = try await call.value }
        #expect(failure?.reason == .appUnavailable)
    }

    /// A dead data channel and a silent app are the same fact to a caller — the app
    /// cannot be reached — and neither is a timeout.
    @Test("a closed channel is unreachable rather than timed out")
    func mapsClosedChannel() async {
        let (conversation, fake) = conversation()

        let call = Task { try await conversation.interrupt() }
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.close()

        await #expect(throws: ConversationFailure.unreachable) { _ = try await call.value }
    }

    // MARK: Requests

    /// `bool(params["muted"])` on the app's side would accept a `1` just as happily, so
    /// the encoded type is asserted rather than the value: a number here would work
    /// against the real robot and be wrong on the wire.
    @Test("booleans reach the wire as booleans")
    func encodesBooleansAsBooleans() async throws {
        let (conversation, fake) = conversation()

        let call = Task { try await conversation.setMicrophoneMuted(true) }
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(#"{"jsonrpc":"2.0","id":1,"result":{"muted":true}}"#)
        #expect(try await call.value)

        let frame = try #require(fake.sent.first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        #expect(object["method"] as? String == "conversation.mic")
        let params = try #require(object["params"] as? [String: Any])
        #expect(params["muted"] is Bool)
        #expect(params["muted"] as? Bool == true)
    }

    /// Reading the flag must not write it — the app treats a present `muted` as a write,
    /// so a read spelled `{"muted": false}` unmutes the robot on its way past.
    @Test("reading the microphone sends no muted key")
    func readsTheMicrophoneWithoutWritingIt() async throws {
        let (conversation, fake) = conversation()

        let call = Task { try await conversation.microphoneMuted() }
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(#"{"jsonrpc":"2.0","id":1,"result":{"muted":false}}"#)
        #expect(try await call.value == false)

        let frame = try #require(fake.sent.first)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])
        #expect(params.isEmpty)
    }

    /// `locked_to` is the one snake_case key on this surface, and `JSONCodec.daemon`
    /// sets no key strategy — a missing `CodingKeys` entry decodes to nil in silence and
    /// reads as "the app did not send it".
    @Test("the personality listing maps its snake_case key")
    func decodesPersonalities() async throws {
        let (conversation, fake) = conversation()

        let call = Task { try await conversation.personalities() }
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(
            #"{"jsonrpc":"2.0","id":1,"result":{"choices":["default","noir_detective"],"#
                + #""current":"noir_detective","startup":"default","locked":true,"locked_to":"noir_detective"}}"#
        )

        let listing = try await call.value
        #expect(listing.choices == ["default", "noir_detective"])
        #expect(listing.current == "noir_detective")
        #expect(listing.startup == "default")
        #expect(listing.isLocked)
        #expect(listing.lockedTo == "noir_detective")
    }

    /// `voices.list` answers a bare array, unlike every other verb here.
    @Test("the voice list decodes from a bare array")
    func decodesVoices() async throws {
        let (conversation, fake) = conversation()

        let call = Task { try await conversation.voices() }
        await waitUntil("the call is on the wire") { !fake.sent.isEmpty }
        fake.emit(#"{"jsonrpc":"2.0","id":1,"result":["alloy","verse"]}"#)

        #expect(try await call.value == ["alloy", "verse"])
    }
}

private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(10),
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting until \(description)", sourceLocation: sourceLocation)
}
