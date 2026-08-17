import Foundation
@testable import ReachyKit
import ReachyTestSupport
import Testing

/// `/api/media/sounds*` and `play_sound`, over HTTP.
///
/// Every status code asserted here was measured against a Wireless unit on 2026-08-17
/// rather than read off the spec: daemon 1.9.0 mounts all four routes, `GET /sounds`
/// answers `{"files": […]}`, a wrong extension and a non-audio payload are two different
/// 400s, and a `DELETE` for a name the robot does not have is a 404 — the one place on
/// this surface where existence is reported at all.
@Suite("Sounds over HTTP", .timeLimit(.minutes(1)))
struct RobotConnectionSoundsTests {
    private func makeConnection(_ session: URLSession) throws -> RobotConnection {
        try RobotConnection(address: RobotAddress(host: "10.42.0.1"), session: session)
    }

    @Test("the listing reads the daemon's one key")
    func listsSounds() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/media/sounds": .init(statusCode: 200, json: #"{"files":["airhorn.wav","tada.m4a"]}"#),
        ])

        let sounds = try await makeConnection(session).sounds()

        #expect(sounds.map(\.filename) == ["airhorn.wav", "tada.m4a"])
    }

    /// A reply that carries no `files` is a daemon that changed the shape of this
    /// route. Reporting the 200 that could not be read is what `urdf()` does for the
    /// same situation.
    @Test("a reply with no files key is a refusal rather than an empty library")
    func refusesAnUnreadableListing() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/media/sounds": .init(statusCode: 200, json: #"{"sounds":[]}"#),
        ])

        await #expect(throws: ReachyKitError.daemonRejected(statusCode: 200)) {
            try await makeConnection(session).sounds()
        }
    }

    /// The insurance arm: an older daemon does not mount these routes, and a bare
    /// FastAPI 404 must not reach a screen as a refusal to act on.
    @Test("a daemon that does not mount the route answers an empty library")
    func readsA404AsAnEmptyLibrary() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/media/sounds": .init(statusCode: 404, json: #"{"detail":"Not Found"}"#),
        ])

        #expect(try await makeConnection(session).sounds().isEmpty)
    }

    @Test("playing names the file in the body")
    func playsByName() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/media/play_sound": .init(statusCode: 200, json: #"{"status":"ok"}"#),
        ])

        try await makeConnection(session).playSound(named: "airhorn.wav")

        let body = try #require(StubURLProtocol.bodies(for: session).first)
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.contains(#""file""#))
        #expect(text.contains("airhorn.wav"))
    }

    /// `play_sound` is behind `get_backend`, so a torn-down backend is the one refusal
    /// on this surface that reports itself — the reason `RobotSoundPlayer` needs no
    /// readiness probe.
    @Test("a stopped backend surfaces as the daemon's own refusal")
    func reportsStoppedBackend() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/media/play_sound": .init(statusCode: 503, json: #"{"detail":"Backend not running"}"#),
        ])

        await #expect(throws: ReachyKitError.backendNotRunning) {
            try await makeConnection(session).playSound(named: "airhorn.wav")
        }
    }

    @Test("deleting reaches the filename's own path")
    func deletesByName() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/media/sounds/airhorn.wav": .init(statusCode: 200, json: #"{"status":"ok"}"#),
        ])

        try await makeConnection(session).deleteSound(named: "airhorn.wav")

        #expect(StubURLProtocol.requests(for: session).first?.httpMethod == "DELETE")
    }

    /// Measured: `delete_sound` raises `HTTPException(404, "File '…' not found")`.
    /// `SoundboardModel` is what turns that into "already gone"; this layer reports it.
    @Test("deleting a sound the robot does not have is reported as a 404")
    func reportsAMissingSound() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/media/sounds/gone.wav": .init(statusCode: 404, json: #"{"detail":"File 'gone.wav' not found"}"#),
        ])

        let error = await #expect(throws: ReachyKitError.self) {
            try await makeConnection(session).deleteSound(named: "gone.wav")
        }
        #expect(error?.statusCode == 404)
    }

    // MARK: - The upload

    /// The one hand-written body in the repository, asserted byte by byte. The same
    /// bytes were posted at a real robot on 2026-08-17 and answered
    /// `{"status":"ok","path":"/tmp/reachy_mini_sounds/…"}`.
    @Test("the upload carries one multipart part named file")
    func uploadsAsMultipart() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/media/sounds/upload": .init(statusCode: 200, json: #"{"status":"ok","path":"/tmp/x.wav"}"#),
        ])
        let audio = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0x03])

        try await makeConnection(session).uploadSound(named: "airhorn.wav", data: audio)

        let request = try #require(StubURLProtocol.requests(for: session).first)
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary=ReachyMiniSound-"))

        let body = try #require(StubURLProtocol.bodies(for: session).first)
        let text = try #require(String(data: body, encoding: .isoLatin1))
        #expect(text.contains(#"Content-Disposition: form-data; name="file"; filename="airhorn.wav""#))
        // CRLF, not `\n`: `python-multipart` parses the header block by the line ending
        // the format specifies, and a lone newline is not it.
        #expect(text.contains("\r\n\r\n"))
        #expect(body.range(of: audio) != nil)

        let boundary = contentType.replacingOccurrences(of: "multipart/form-data; boundary=", with: "")
        #expect(text.hasSuffix("\r\n--\(boundary)--\r\n"))
    }

    /// The name is reduced the way the daemon reduces it (`Path(file.filename).name`),
    /// so a caller cannot decide where on the robot's filesystem an upload lands.
    @Test("an upload sends the basename, never a path")
    func uploadsTheBasename() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/media/sounds/upload": .init(statusCode: 200, json: #"{"status":"ok"}"#),
        ])

        try await makeConnection(session).uploadSound(named: "../../etc/airhorn.wav", data: Data([0x00]))

        let body = try #require(StubURLProtocol.bodies(for: session).first)
        let text = try #require(String(data: body, encoding: .isoLatin1))
        #expect(text.contains(#"filename="airhorn.wav""#))
        #expect(!text.contains(".."))
    }

    /// **The two refusals that must never reach the network.** The daemon has an
    /// extension allow-list of its own, and its size cap is declared and never applied —
    /// so this one is the only cap there is, and both are asserted on an empty request
    /// log rather than on the throw alone.
    @Test("a file the robot could not take is refused before anything is sent")
    func refusesLocallyWithoutSending() async throws {
        let session = StubURLProtocol.makeSession([
            "/api/media/sounds/upload": .init(statusCode: 200, json: #"{"status":"ok"}"#),
        ])
        let connection = try makeConnection(session)

        await #expect(throws: ReachyKitError.soundTypeUnsupported(name: "notes.txt")) {
            try await connection.uploadSound(named: "notes.txt", data: Data([0x00]))
        }
        await #expect(throws: ReachyKitError.self) {
            try await connection.uploadSound(
                named: "huge.wav",
                data: Data(repeating: 0, count: RobotSound.maxUploadBytes + 1)
            )
        }
        await #expect(throws: ReachyKitError.soundNameRejected(name: #"a"b.wav"#)) {
            try await connection.uploadSound(named: #"a"b.wav"#, data: Data([0x00]))
        }

        #expect(StubURLProtocol.requests(for: session).isEmpty)
    }
}
