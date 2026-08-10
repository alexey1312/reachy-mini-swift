import Foundation
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// The Hugging Face relay: an SSE stream down, HTTP POSTs up. Every shape here is
/// the one the robot's own `central_signaling_relay.py` speaks to the same server.
@Suite("Central relay client", .timeLimit(.minutes(1)))
struct CentralRelayClientTests {
    private static let base = URL(string: "https://central.example")!

    private func client(
        _ stubs: [String: StubURLProtocol.Stub],
        token: String? = "hf_token",
        session: URLSession? = nil
    ) -> (CentralRelayClient, URLSession) {
        let session = session ?? StubURLProtocol.makeSession(stubs)
        let client = CentralRelayClient(
            configuration: .init(baseURL: Self.base, clientName: "ReachyMini Swift"),
            session: session,
            token: { token }
        )
        return (client, session)
    }

    private func collect(
        _ client: CentralRelayClient,
        until isDone: @escaping ([CentralRelayClient.Event]) -> Bool
    ) async -> [CentralRelayClient.Event] {
        var received: [CentralRelayClient.Event] = []
        for await event in await client.events() {
            received.append(event)
            if isDone(received) {
                break
            }
        }
        return received
    }

    /// The stream carries SSE framing, not bare JSON: only `data:` lines are
    /// payload, and the rest — comments, `event:`, `id:` — are noise a decoder
    /// must never see.
    @Test("only data lines are decoded")
    func readsOnlyDataLines() async {
        let (client, _) = client([
            "/events": .init(statusCode: 200, lines: [
                ": keepalive",
                "event: message",
                #"data: {"type":"welcome","peerId":"peer-1"}"#,
                "",
                #"data: {"type":"list","producers":[{"peerId":"robot-1","meta":{"name":"testbot"}}]}"#,
            ]),
            "/send": .init(statusCode: 200),
        ])

        let events = await collect(client) { events in
            events.contains {
                if case .producers = $0 {
                    true
                } else {
                    false
                }
            }
        }

        #expect(events.first == .connected(peerID: "peer-1"))
        #expect(events.contains {
            $0 == .producers([.init(peerID: "robot-1", name: "testbot", isBusy: false, activeApp: nil)])
        })
    }

    /// Central sweeps peers with no recent inbound traffic, so a listener has to
    /// announce itself — and the name it announces is what the robot's owner sees
    /// as the thing holding their robot.
    @Test("the listener announces itself as soon as it is welcomed")
    func registersOnWelcome() async {
        let (client, session) = client([
            "/events": .init(statusCode: 200, lines: [#"data: {"type":"welcome","peerId":"peer-1"}"#]),
            "/send": .init(statusCode: 200),
        ])

        _ = await collect(client) { $0.contains {
            if case .connected = $0 {
                true
            } else {
                false
            }
        } }
        /// The POST is fired from the stream's task; poll for it rather than
        /// betting a fixed pause outlasts a loaded runner (project rule 7).
        func announced() -> Bool {
            StubURLProtocol.bodies(for: session)
                .compactMap { try? JSONDecoder().decode(SignalingMessage.self, from: $0) }
                .contains { $0 == .setPeerStatus(roles: ["listener"], name: "ReachyMini Swift") }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !announced(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(announced())
    }

    /// A token that central refuses is not something to retry: every attempt with
    /// the same token gets the same answer, and the user has to sign in again.
    @Test("a rejected token ends the stream instead of retrying")
    func stopsOnUnauthorized() async {
        let (client, _) = client(["/events": .init(statusCode: 401)])

        let events = await collect(client) { _ in true }

        #expect(events == [.failed(.unauthorized)])
    }

    @Test("with no token the stream never opens")
    func requiresAToken() async {
        let (client, session) = client(["/events": .init(statusCode: 200)], token: nil)

        let events = await collect(client) { _ in true }

        #expect(events == [.failed(.noToken)])
        #expect(StubURLProtocol.requests(for: session).isEmpty)
    }

    /// WebRTC's end-of-candidates marker. `RTCIceCandidate` throws on an empty
    /// candidate string, so it is dropped here rather than at the media layer.
    @Test("the end-of-candidates marker never reaches the caller")
    func dropsEmptyCandidates() async {
        let (client, _) = client([
            "/events": .init(statusCode: 200, lines: [
                #"data: {"type":"welcome","peerId":"peer-1"}"#,
                #"data: {"type":"peer","sessionId":"s1","ice":{"candidate":"","sdpMLineIndex":0}}"#,
                #"data: {"type":"peer","sessionId":"s1","ice":{"candidate":"candidate:1","sdpMLineIndex":0}}"#,
            ]),
            "/send": .init(statusCode: 200),
        ])

        let events = await collect(client) { events in
            events.contains {
                if case .remoteCandidate = $0 {
                    true
                } else {
                    false
                }
            }
        }

        let candidates = events.compactMap { event -> String? in
            if case let .remoteCandidate(_, candidate, _, _) = event {
                candidate
            } else {
                nil
            }
        }
        #expect(candidates == ["candidate:1"])
    }

    /// A line that is not JSON at all — central sends `data: ping` as its
    /// keepalive — must not end the stream.
    @Test("a keepalive that is not JSON is ignored")
    func ignoresNonJSONData() async {
        let (client, _) = client([
            "/events": .init(statusCode: 200, lines: [
                "data: ping",
                #"data: {"type":"welcome","peerId":"peer-1"}"#,
            ]),
            "/send": .init(statusCode: 200),
        ])

        let events = await collect(client) { $0.contains {
            if case .connected = $0 {
                true
            } else {
                false
            }
        } }

        #expect(events == [.connected(peerID: "peer-1")])
    }

    // MARK: Sending

    /// Central answers the POST that asked. `startSession` is the case that
    /// matters: the session id — or the refusal — comes back in the reply body
    /// rather than over the stream.
    @Test("the reply to a send is itself a signaling message")
    func readsTheReplyToASend() async throws {
        let (client, session) = client([
            "/send": .init(
                statusCode: 200,
                json: #"{"type":"sessionStarted","peerId":"robot-1","sessionId":"s1"}"#
            ),
        ])

        let outcome = try await client.startSession(with: "robot-1")

        #expect(outcome == .started(sessionID: "s1"))
        let request = try #require(StubURLProtocol.requests(for: session).first)
        #expect(request.httpMethod == "POST")
        // The token travels in a header, never the URL: central is a Hugging Face
        // Space, and a URL reaches its access log and every proxy on the way.
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hf_token")
        #expect(request.url?.absoluteString.contains("hf_token") == false)
    }

    @Test("a refusal comes back the same way and is not an error")
    func readsARejection() async throws {
        let (client, _) = client([
            "/send": .init(
                statusCode: 200,
                json: #"{"type":"sessionRejected","reason":"robot_busy","activeApp":"Hand Tracker"}"#
            ),
        ])

        let outcome = try await client.startSession(with: "robot-1")

        #expect(outcome == .rejected(reason: "robot_busy", activeApp: "Hand Tracker"))
    }

    @Test("an acknowledgement with no message in it is not an error either")
    func acceptsAnEmptyReply() async throws {
        let (client, _) = client(["/send": .init(statusCode: 200, json: #"{"status":"ok"}"#)])

        #expect(try await client.send(.list) == nil)
    }

    /// 1200 requests a minute per token, and central answers 429 past it. Retrying
    /// immediately is how a client turns a rate limit into a ban.
    @Test("a rate limit is reported as itself")
    func reportsRateLimit() async {
        let (client, _) = client(["/send": .init(statusCode: 429)])

        await #expect(throws: CentralRelayClient.Failure.rateLimited) {
            try await client.send(.list)
        }
    }

    // MARK: The robot list

    @Test("the robot list decodes with the keys that identify a robot")
    func listsRobots() async throws {
        let (client, _) = client([
            "/api/robot-status": .init(statusCode: 200, json: #"""
            {"robots": [
              {"peerId": "peer-7", "robotName": "testbot", "busy": false,
               "meta": {"name": "testbot", "transport": "wifi", "hardware_id": "a1b2c3d4e5f60718"},
               "last_seen_age_seconds": 2.5}
            ]}
            """#),
        ])

        let robots = try await client.robots()

        #expect(robots.map(\.id) == ["a1b2c3d4e5f60718"])
        #expect(robots.first?.transport == .wifi)
    }

    /// Presence in the list *is* the online signal — central sweeps a robot whose
    /// lease lapsed — so an empty list is an answer, not a failure.
    @Test("an empty list is an answer")
    func acceptsAnEmptyRobotList() async throws {
        let (client, _) = client(["/api/robot-status": .init(statusCode: 200, json: #"{"robots": []}"#)])

        #expect(try await client.robots().isEmpty)
    }

    @Test("a token central will not accept is reported as such")
    func reportsUnauthorizedList() async {
        let (client, _) = client(["/api/robot-status": .init(statusCode: 401)])

        await #expect(throws: CentralRelayClient.Failure.unauthorized) {
            try await client.robots()
        }
    }
}
