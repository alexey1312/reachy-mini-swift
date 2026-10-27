import Foundation
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// What daemon 1.13.0 changed about a relayed session's ends.
///
/// The robot now judges a session alive on its peer link, so an `endSession` with
/// no reason no longer ends one that is live, and a quiet session is `superseded`
/// by the next request. A robot also registers again — under a new peer id — after
/// two failed heartbeats. Each test here goes red when the matching change is
/// undone in `CentralSignalingTransport` (checked by mutating it).
@Suite("Central signaling transport, daemon 1.13 session ends", .timeLimit(.minutes(1)))
struct CentralSignalingSessionTests {
    private func transport(
        _ stubs: [String: StubURLProtocol.Stub],
        robot: String = "robot-1",
        identity: String? = nil
    ) -> (CentralSignalingTransport, URLSession) {
        let session = StubURLProtocol.makeSession(stubs)
        let client = CentralRelayClient(
            configuration: .init(baseURL: URL(string: "https://central.example")!, clientName: "Test"),
            session: session,
            token: { "hf_token" }
        )
        return (CentralSignalingTransport(relay: client, robotPeerID: robot, robotIdentity: identity), session)
    }

    private func collect(
        _ transport: CentralSignalingTransport,
        until isDone: @escaping ([SignalingEvent]) -> Bool
    ) async -> [SignalingEvent] {
        var received: [SignalingEvent] = []
        for await event in await transport.events() {
            received.append(event)
            if isDone(received) {
                break
            }
        }
        return received
    }

    private func sent(on session: URLSession) -> [SignalingMessage] {
        StubURLProtocol.bodies(for: session)
            .compactMap { try? JSONDecoder().decode(SignalingMessage.self, from: $0) }
    }

    private static let started = #"{"type":"sessionStarted","peerId":"robot-1","sessionId":"s1"}"#

    /// A reason-less hang-up is central's bookkeeping to a 1.13 robot, and a live
    /// session survives it — so the re-dial after it was refused as busy.
    @Test("a hang-up names its reason", arguments: [SignalingHangUp.stop, .redial])
    func hangsUpWithAReason(hangUp: SignalingHangUp) async {
        let (transport, session) = transport([
            "/events": .init(statusCode: 200, lines: [
                #"data: {"type":"list","producers":[{"peerId":"robot-1"}]}"#,
            ]),
            "/send": .init(statusCode: 200, json: Self.started),
        ])
        _ = await collect(transport) { $0.contains(.sessionRequested) }

        await transport.disconnect(hangUp)

        #expect(sent(on: session).contains(.endSession(sessionID: "s1", reason: hangUp.rawValue)))
    }

    @Test("a plain disconnect is a stop")
    func plainDisconnectStops() async {
        let (transport, session) = transport([
            "/events": .init(statusCode: 200, lines: [
                #"data: {"type":"list","producers":[{"peerId":"robot-1"}]}"#,
            ]),
            "/send": .init(statusCode: 200, json: Self.started),
        ])
        _ = await collect(transport) { $0.contains(.sessionRequested) }

        await transport.disconnect()

        #expect(sent(on: session).contains(.endSession(sessionID: "s1", reason: "client_stop")))
    }

    /// A `superseded` for the ghost a re-dial replaced arrives on the stream the new
    /// session listens to. Taking it as this session's ending killed a healthy one.
    @Test("an end for another session leaves this one alone")
    func ignoresAnotherSessionsEnd() async {
        let (transport, _) = transport([
            "/events": .init(statusCode: 200, lines: [
                #"data: {"type":"list","producers":[{"peerId":"robot-1"}]}"#,
                #"data: {"type":"endSession","sessionId":"s0","reason":"superseded"}"#,
                #"data: {"type":"peer","sessionId":"s1","sdp":{"type":"offer","sdp":"v=0 offer"}}"#,
            ]),
            "/send": .init(statusCode: 200, json: Self.started),
        ])

        let events = await collect(transport) { events in
            events.contains(.offer(sessionID: "s1", sdp: "v=0 offer"))
        }

        #expect(!events.contains(.sessionEnded(reason: "superseded")))
    }

    /// With no session and nothing asked for, an `endSession` has nothing to end.
    @Test("an end with no session behind it is not reported")
    func ignoresAnEndWithNoSession() async {
        let (transport, _) = transport([
            "/events": .init(statusCode: 200, lines: [
                #"data: {"type":"list","producers":[{"peerId":"someone-else"}]}"#,
                #"data: {"type":"endSession","sessionId":"s9","reason":"superseded"}"#,
            ]),
            "/send": .init(statusCode: 200),
        ])

        // The stream ending is reported as an end with no reason; that is the stop.
        let events = await collect(transport) { $0.contains(.sessionEnded(reason: nil)) }

        #expect(!events.contains(.sessionEnded(reason: "superseded")))
    }

    /// The session's own end still arrives — the filter must not swallow it.
    @Test("this session's own end is still reported")
    func reportsItsOwnEnd() async {
        let (transport, _) = transport([
            "/events": .init(statusCode: 200, lines: [
                #"data: {"type":"list","producers":[{"peerId":"robot-1"}]}"#,
                #"data: {"type":"endSession","sessionId":"s1","reason":"robot_stopping"}"#,
            ]),
            "/send": .init(statusCode: 200, json: Self.started),
        ])

        let events = await collect(transport) { $0.contains(.sessionEnded(reason: "robot_stopping")) }

        #expect(events.contains(.sessionEnded(reason: "robot_stopping")))
    }

    /// The robot registered again, so its old peer id is gone from the list. Asking
    /// for it waited for a producer for ever; the stable id finds it.
    @Test("a robot listed under a new peer id is found by its stable id")
    func followsANewPeerID() async {
        let (transport, session) = transport([
            "/events": .init(statusCode: 200, lines: [
                #"data: {"type":"list","producers":[{"peerId":"robot-2","meta":{"hardware_id":"hw-1"}}]}"#,
            ]),
            "/send": .init(statusCode: 200, json: #"{"type":"sessionStarted","peerId":"robot-2","sessionId":"s1"}"#),
        ], robot: "robot-1", identity: "hw-1")

        _ = await collect(transport) { $0.contains(.sessionRequested) }

        #expect(sent(on: session).contains(.startSession(peerID: "robot-2")))
    }

    /// Central sweeps the old entry only once its lease lapses, so for a while the
    /// robot is listed twice. The entry it registered last is the live one.
    @Test("the moved entry wins over a stale one")
    func prefersTheMovedEntry() async {
        let (transport, session) = transport([
            "/events": .init(statusCode: 200, lines: [
                #"data: {"type":"list","producers":[{"peerId":"robot-1","meta":{"hardware_id":"hw-1"}},"#
                    + #"{"peerId":"robot-2","meta":{"hardware_id":"hw-1"}}]}"#,
            ]),
            "/send": .init(statusCode: 200, json: #"{"type":"sessionStarted","peerId":"robot-2","sessionId":"s1"}"#),
        ], robot: "robot-1", identity: "hw-1")

        _ = await collect(transport) { $0.contains(.sessionRequested) }

        #expect(sent(on: session).contains(.startSession(peerID: "robot-2")))
        #expect(!sent(on: session).contains(.startSession(peerID: "robot-1")))
    }

    /// Another robot that happens to be listed is never taken for this one.
    @Test("a different robot's stable id does not match")
    func doesNotTakeAnotherRobot() async {
        let (transport, _) = transport([
            "/events": .init(statusCode: 200, lines: [
                #"data: {"type":"list","producers":[{"peerId":"robot-9","meta":{"hardware_id":"hw-9"}}]}"#,
            ]),
            "/send": .init(statusCode: 200),
        ], robot: "robot-1", identity: "hw-1")

        let events = await collect(transport) { $0.contains(.waitingForProducer) }

        #expect(events.contains(.waitingForProducer))
    }
}
