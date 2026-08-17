import Foundation

/// The sound-file half of `/api/media/*`: list, play, upload, delete.
///
/// A file of its own because `RobotConnection.swift` is at SwiftLint's length limit —
/// the same split `+Presence`, `+Wireless` and `+Apps` make. `stopSound()` stays over
/// there, on ``RobotAPIClient``, because a recorded move's music is the same player
/// and it needed stopping long before there was a soundboard.
///
/// Three of the four go through the generated client. The upload cannot: it is
/// `multipart/form-data`, which is why it is the one hand-written route here.
extension RobotConnection: SoundboardClient {
    /// - Returns: the names in `/tmp/reachy_mini_sounds`, in the order the daemon
    ///   sorted them. Empty is the ordinary answer for a robot nothing has been sent
    ///   to yet — the route itself returns `{"files": []}` for an absent directory.
    ///
    /// **A 404 is answered with an empty library rather than an error**, and that arm
    /// is insurance rather than the expected case: measured against a Wireless unit on
    /// 2026-08-17, daemon **1.9.0 mounts all four sound routes** and answers this one
    /// `{"files": []}` — so the spec-ahead-of-firmware trap
    /// (`.claude/rules/daemon-api.md`) does not apply to them, unlike the five routes
    /// listed there. What the arm covers is an older daemon, where a bare FastAPI 404
    /// would otherwise reach a screen as a refusal to be acted on. Reading it costs
    /// nothing, where a probe on connect would cost every session a round trip for a
    /// screen most of them never open.
    public func sounds() async throws -> [RobotSound] {
        switch try await client.listSoundsApiMediaSoundsGet() {
        case let .ok(response):
            // One key, `files`. An absent one is a daemon that changed the shape of
            // this reply, and reporting a 200 that could not be read is the same
            // answer `urdf()` and `hardwareID(reportedIn:)` give.
            // `try` again inside the case: the generated body accessor throws on a
            // content type it was not expecting, and the `try` on the switch subject
            // covers the call alone. `RobotConnection+Apps` reads its bodies the same way.
            guard let files = try response.body.json.additionalProperties["files"] else {
                throw ReachyKitError.daemonRejected(statusCode: 200)
            }
            return files.map(RobotSound.init(filename:))
        case let .undocumented(statusCode, _):
            guard statusCode == 404 else { throw ReachyKitError.fromStatusCode(statusCode) }
            return []
        }
    }

    /// - Important: this answers `{"status": "ok"}` for a name that matches nothing.
    ///   The media server logs the miss and returns, so a 200 is not evidence a sound
    ///   is playing — see ``SoundboardClient``.
    public func playSound(named filename: String) async throws {
        switch try await client.playSoundApiMediaPlaySoundPost(body: .json(.init(file: filename))) {
        case .ok:
            return
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    /// Sends a file to the robot's temporary sound directory under its own name,
    /// overwriting a same-named one.
    ///
    /// The name is reduced to its last path component, which is what the daemon does
    /// with it too (`Path(file.filename).name`) — so a caller cannot decide where on
    /// the robot's filesystem this lands, and the name that comes back from
    /// ``sounds()`` is the one this sent.
    ///
    /// **Measured against a Wireless unit on 2026-08-17, with the body this assembles**
    /// rather than with `curl -F`, which would have proved the route and not the bytes:
    /// a valid WAV answers `{"status": "ok", "path": "/tmp/reachy_mini_sounds/<name>"}`
    /// and appears in the next listing. The refusals came back in two shapes, which is
    /// the daemon's validation order showing through: a wrong extension is
    /// `400 Unsupported file extension; allowed: …` before anything is read, and a
    /// correctly-named file that is not audio is `400 Unsupported or invalid audio
    /// file` from the GStreamer probe. Both carry a `detail`, so
    /// ``ReachyKitError/fromStatusCode(_:detail:)`` turns them into a sentence the
    /// screen can show — and the first of the two is what
    /// ``SoundUpload/validatedName(_:byteCount:)`` makes unreachable from here, so in
    /// practice a person only ever sees the second.
    public func uploadSound(named filename: String, data: Data) async throws {
        let name = try SoundUpload.validatedName(filename, byteCount: data.count)
        let boundary = SoundUpload.boundary()
        _ = try await hubData(
            method: "POST",
            path: "/api/media/sounds/upload",
            body: SoundUpload.body(boundary: boundary, filename: name, data: data),
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }

    /// Removes one sound from the robot. The device's own copy is untouched, and is
    /// what makes this recoverable.
    ///
    /// The generated operation percent-encodes the path component, which is the
    /// reason not to build this URL by hand: `URLComponents.path` does not escape a
    /// `/`, so a name carrying one would quietly become two path segments and miss
    /// the route entirely instead of being refused by it.
    public func deleteSound(named filename: String) async throws {
        guard RobotSound.isSafeName(filename) else {
            throw ReachyKitError.soundNameRejected(name: filename)
        }
        switch try await client.deleteSoundApiMediaSoundsFilenameDelete(path: .init(filename: filename)) {
        case .ok:
            return
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, _):
            // **A missing file really is a 404 here**, measured on 2026-08-17 —
            // `delete_sound` raises `HTTPException(404, "File '…' not found")`, which
            // makes this the one route on the surface that distinguishes a sound that
            // exists from one that does not. `GET /sounds` cannot: an empty list is the
            // answer for an empty directory and for no directory alike.
            // It stays a refusal at this layer all the same: only the caller knows
            // whether "already gone" was the outcome it wanted, and `SoundboardModel`
            // is the one that does.
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }
}

/// The upload's body and the refusals that come before it.
///
/// **This is the only `multipart/form-data` in the repository**, and it is written out
/// rather than taken from the generator deliberately. The generator does emit a
/// multipart payload for the spec's `format: binary` part, but nothing here has ever
/// exercised that path, while these bytes can be asserted exactly through
/// `StubURLProtocol.bodies(for:)` — which is what `RobotConnectionSoundsTests` does.
/// Moving to the generated form later changes this file and nothing above it.
///
/// A namespace rather than members on the actor, so nothing has to reason about
/// isolation to assemble a `Data`.
enum SoundUpload {
    /// CRLF, not `\n`: `python-multipart` parses the header block by the line ending
    /// the format specifies, and a lone newline is not it.
    private static let crlf = "\r\n"

    static func boundary() -> String {
        "ReachyMiniSound-\(UUID().uuidString)"
    }

    /// The single part the route reads, whose field name must be `file` — that is the
    /// parameter's name in `upload_sound(file: UploadFile = File(...))`.
    ///
    /// `application/octet-stream` for the part because the daemon does not read it: it
    /// checks the extension, then probes the content with GStreamer.
    static func body(boundary: String, filename: String, data: Data) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\(crlf)".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(crlf)".utf8))
        body.append(Data("Content-Type: application/octet-stream\(crlf)\(crlf)".utf8))
        body.append(data)
        body.append(Data("\(crlf)--\(boundary)--\(crlf)".utf8))
        return body
    }

    /// Every refusal the client can make on its own, so a 25 MiB body is never put on
    /// the network to be told no.
    ///
    /// The size cap is **ours**: `MAX_SOUND_UPLOAD_BYTES` is declared in
    /// `routers/media.py`, named in the route's docstring, and never compared against
    /// the body it streams to disk. Removing this check does not fall back to the
    /// daemon's, it removes the limit.
    static func validatedName(_ filename: String, byteCount: Int) throws -> String {
        let name = RobotSound.basename(filename)
        guard RobotSound.isSafeName(name) else {
            throw ReachyKitError.soundNameRejected(name: name)
        }
        guard RobotSound.isAllowedExtension(name) else {
            throw ReachyKitError.soundTypeUnsupported(name: name)
        }
        guard byteCount <= RobotSound.maxUploadBytes else {
            throw ReachyKitError.soundTooLarge(bytes: byteCount, limit: RobotSound.maxUploadBytes)
        }
        return name
    }
}
