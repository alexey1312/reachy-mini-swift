import Foundation
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// The relay dressed as signaling: pick the robot out of central's producer list,
/// ask for a session, and hand the media layer the same offer it would have got
/// from the robot's own socket.
@Suite("Central signaling transport", .timeLimit(.minutes(1)))
struct CentralSignalingTransportTests {
    private func transport(
        _ stubs: [String: StubURLProtocol.Stub],
        robot: String = "robot-1"
    ) -> (CentralSignalingTransport, URLSession) {
        let session = StubURLProtocol.makeSession(stubs)
        let client = CentralRelayClient(
            configuration: .init(baseURL: URL(string: "https://central.example")!, clientName: "Test"),
            session: session,
            token: { "hf_token" }
        )
        return (CentralSignalingTransport(relay: client, robotPeerID: robot), session)
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

    /// The robot is the offerer here too, so the session has to be asked for
    /// before anything arrives — and central answers that ask in the POST body.
    @Test("asks for a session as soon as the robot is listed, then relays the offer")
    func startsASessionAndRelaysTheOffer() async {
        let (transport, session) = transport([
            "/events": .init(statusCode: 200, lines: [
                #"data: {"type":"welcome","peerId":"me"}"#,
                #"data: {"type":"list","producers":[{"peerId":"robot-1","meta":{"name":"testbot"}}]}"#,
                #"data: {"type":"peer","sessionId":"s1","sdp":{"type":"offer","sdp":"v=0 offer"}}"#,
            ]),
            "/send": .init(statusCode: 200, json: #"{"type":"sessionStarted","peerId":"robot-1","sessionId":"s1"}"#),
        ])

        let events = await collect(transport) { events in
            events.contains {
                if case .offer = $0 {
                    true
                } else {
                    false
                }
            }
        }

        #expect(events.contains(.offer(sessionID: "s1", sdp: "v=0 offer")))
        // Said as well as done, so a session waiting for the robot starts its clock.
        #expect(events.contains(.sessionRequested))
        let asked = StubURLProtocol.bodies(for: session)
            .compactMap { try? JSONDecoder().decode(SignalingMessage.self, from: $0) }
        #expect(asked.contains(.startSession(peerID: "robot-1")))
    }

    /// A robot that is not in the list is not online. Saying so beats waiting for
    /// an offer that is never coming.
    @Test("a robot missing from the list reads as nothing producing yet")
    func reportsMissingRobot() async {
        let (transport, _) = transport([
            "/events": .init(statusCode: 200, lines: [
                #"data: {"type":"welcome","peerId":"me"}"#,
                #"data: {"type":"list","producers":[{"peerId":"someone-else"}]}"#,
            ]),
            "/send": .init(statusCode: 200),
        ])

        let events = await collect(transport) { $0.contains(.waitingForProducer) }

        #expect(events.contains(.waitingForProducer))
    }

    /// Being turned away is the common case — the robot is in use — and it is the
    /// end of this attempt, with central's own reason carried through.
    @Test("a refusal ends the attempt and names the app holding the robot")
    func reportsRefusal() async {
        let (transport, _) = transport([
            "/events": .init(statusCode: 200, lines: [
                #"data: {"type":"welcome","peerId":"me"}"#,
                #"data: {"type":"list","producers":[{"peerId":"robot-1","busy":true,"activeApp":"Hand Tracker"}]}"#,
            ]),
            "/send": .init(
                statusCode: 200,
                json: #"{"type":"sessionRejected","reason":"robot_busy","activeApp":"Hand Tracker"}"#
            ),
        ])

        let events = await collect(transport) { events in
            events.contains {
                if case .failed = $0 {
                    true
                } else {
                    false
                }
            }
        }

        #expect(events.contains { event in
            if case let .failed(reason) = event {
                reason.contains("Hand Tracker")
            } else {
                false
            }
        })
    }

    /// Eviction. Central says which kind, and the difference matters: a local app
    /// started on the robot is not the same as another device taking over.
    @Test("an eviction carries the reason central gave")
    func relaysEndSessionReason() async {
        let (transport, _) = transport([
            "/events": .init(statusCode: 200, lines: [
                #"data: {"type":"welcome","peerId":"me"}"#,
                #"data: {"type":"list","producers":[{"peerId":"robot-1"}]}"#,
                #"data: {"type":"endSession","sessionId":"s1","reason":"local_app_started"}"#,
            ]),
            "/send": .init(statusCode: 200, json: #"{"type":"sessionStarted","peerId":"robot-1","sessionId":"s1"}"#),
        ])

        let events = await collect(transport) { events in
            events.contains {
                if case .sessionEnded = $0 {
                    true
                } else {
                    false
                }
            }
        }

        #expect(events.contains(.sessionEnded(reason: "local_app_started")))
    }

    @Test("a token central refuses is terminal")
    func reportsUnauthorized() async {
        let (transport, _) = transport(["/events": .init(statusCode: 401)])

        let events = await collect(transport) { _ in true }

        #expect(events.count == 1)
        #expect(events.first.map {
            if case .failed = $0 {
                true
            } else {
                false
            }
        } == true)
    }

    /// The answer and every local candidate go back up the same POST route, tagged
    /// with the session central handed out.
    @Test("the answer and the candidates carry the session central gave")
    func sendsAnswerAndCandidates() async {
        let (transport, session) = transport([
            "/events": .init(statusCode: 200, lines: [
                #"data: {"type":"welcome","peerId":"me"}"#,
                #"data: {"type":"list","producers":[{"peerId":"robot-1"}]}"#,
                #"data: {"type":"peer","sessionId":"s1","sdp":{"type":"offer","sdp":"v=0 offer"}}"#,
            ]),
            "/send": .init(statusCode: 200, json: #"{"type":"sessionStarted","peerId":"robot-1","sessionId":"s1"}"#),
        ])
        _ = await collect(transport) { events in
            events.contains {
                if case .offer = $0 {
                    true
                } else {
                    false
                }
            }
        }

        await transport.send(answerSDP: "v=0 answer")
        await transport.send(candidate: "candidate:1", sdpMLineIndex: 0, sdpMid: "0")

        let sent = StubURLProtocol.bodies(for: session)
            .compactMap { try? JSONDecoder().decode(SignalingMessage.self, from: $0) }
        #expect(sent.contains(.sdp(sessionID: "s1", type: "answer", sdp: "v=0 answer")))
        #expect(sent.contains(.ice(sessionID: "s1", candidate: "candidate:1", sdpMLineIndex: 0, sdpMid: "0")))
    }
}
