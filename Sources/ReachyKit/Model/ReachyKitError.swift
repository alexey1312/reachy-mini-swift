import Foundation

public enum ReachyKitError: Error, Sendable, Equatable {
    /// The robot address could not be turned into a valid URL (e.g. malformed host).
    case invalidAddress(RobotAddress)
    /// An operation requiring an active daemon connection was requested while disconnected.
    case notConnected
    /// The daemon API is older than the minimum or belongs to another major version.
    case unsupportedDaemonVersion(reported: String, minimum: String)
    /// HTTP 503: the daemon answers, but the robot backend is torn down — every
    /// motion route is guarded by it.
    case backendNotRunning
    /// HTTP 409: a start/stop/restart job is already in flight daemon-side.
    case daemonBusy
    /// The route exists only on a wireless robot: `/wifi/*` and `/update/*` are
    /// mounted only under `--wireless-version`, so a Lite unit answers 404. Reported
    /// separately because "this robot cannot do that" is not "the request was wrong".
    case wirelessFeaturesUnavailable
    /// `/api/daemon/robot-name` was added after daemon 1.9.0, which mounts neither
    /// verb and answers the bare FastAPI 404. Same distinction as
    /// `wirelessFeaturesUnavailable`: the robot cannot do this, the request was fine.
    case renameUnavailable
    /// This connection cannot manage the robot's apps. Every daemon serves
    /// `/api/apps/*` over the LAN, but a remote session reaches the robot through
    /// a data channel that carries only part of that surface.
    case appsUnavailable
    /// This connection cannot reach the robot's Hugging Face account — the same
    /// distinction as `appsUnavailable`, for the routes that link a robot to an
    /// account and report its relay.
    case hfAuthUnavailable
    /// Any other status the daemon rejected the call with.
    case daemonRejected(statusCode: Int)
    /// This connection cannot tail the robot's journal. Appended rather than
    /// slotted in beside its siblings: a bare enum reaches a screenshot as
    /// `error <declaration index>`, so inserting a case renumbers every one after
    /// it and silently rewrites what a past bug report was naming.
    case daemonLogsUnavailable
    /// This connection cannot stream teleop targets.
    case teleopUnavailable
    /// The daemon refused **and said why**, in FastAPI's `detail`.
    ///
    /// Appended for the reason ``daemonLogsUnavailable`` was. It is a case of its
    /// own rather than a `detail` added to ``daemonRejected(statusCode:)`` for a
    /// second reason: that one is constructed in some sixty places, half of them
    /// test expectations matched by value, so widening it would rewrite every one
    /// and make equality depend on a sentence the daemon is free to reword.
    ///
    /// Both carry the same status code. ``statusCode`` reads it off either, and
    /// that — not a pattern match on a case — is what control flow belongs on.
    case daemonRefused(statusCode: Int, detail: String)
    /// This session is already waking the robot, putting it to sleep or tearing the
    /// backend down, and the request needs the robot to be somewhere settled.
    ///
    /// Appended for the reason ``daemonLogsUnavailable`` was. Nothing was sent: it
    /// is the client refusing itself, which is why it is not a `daemonRejected`.
    case powerTransitionInFlight
    /// This connection cannot reach the robot's sound library — the same
    /// distinction as ``appsUnavailable``: `/api/media/*` is a LAN surface, and a
    /// relayed session's data channel carries none of it.
    ///
    /// Appended, like every case since ``daemonLogsUnavailable``.
    case soundboardUnavailable
    /// The file is larger than the daemon's documented ceiling, refused here so a
    /// 25 MiB body is never put on the network to be rejected.
    ///
    /// **This is the only cap there is.** `MAX_SOUND_UPLOAD_BYTES` is declared in
    /// `routers/media.py` and named in the route's own docstring, and nothing there
    /// ever compares it against the body it streams to disk.
    case soundTooLarge(bytes: Int, limit: Int)
    /// The name is not one of the audio extensions the daemon accepts, refused
    /// before the request for the reason above. The robot also probes the content
    /// itself, which no client can do for it — so this catches the obvious half.
    case soundTypeUnsupported(name: String)
    /// The name itself cannot be sent: a path separator (which `delete_sound`
    /// answers 400 for and `play_sound` would read as an absolute location), or a
    /// quote or newline, which would break out of the multipart header the upload is
    /// carried in rather than being escaped by it.
    case soundNameRejected(name: String)
    /// The audio board's registers cannot be reached over this connection — the same
    /// distinction as ``soundboardUnavailable``: `/api/audio/config/*` is a LAN
    /// surface, and this client carries no data-channel arm for it.
    ///
    /// Appended, like every case since ``daemonLogsUnavailable``.
    case audioTuningUnavailable
    /// This connection cannot play the robot's recorded moves — the same
    /// distinction as ``appsUnavailable``: `/api/move/*` is a LAN surface, and a
    /// relayed session's data channel carries none of it.
    ///
    /// Appended, like every case since ``daemonLogsUnavailable``.
    case movesUnavailable

    /// Maps a daemon HTTP status onto the cases callers can act on.
    ///
    /// `detail` is defaulted so the callers that have no body in hand are
    /// unchanged.
    static func fromStatusCode(_ statusCode: Int, detail: String? = nil) -> ReachyKitError {
        switch statusCode {
        // These two stay classified even when the daemon explains itself: they are
        // the refusals callers branch on — 503 gates every motion route, 409 is
        // worth retrying — and a sentence is worth less than knowing which is which.
        case 503: .backendNotRunning
        case 409: .daemonBusy
        default:
            if let detail, !detail.isEmpty {
                .daemonRefused(statusCode: statusCode, detail: detail)
            } else {
                .daemonRejected(statusCode: statusCode)
            }
        }
    }

    /// The HTTP status behind a refusal, whichever case ended up carrying it.
    ///
    /// **Control flow must go through this rather than match a case.** Whether the
    /// daemon attached a `detail` decides which of the two cases a refusal becomes,
    /// and it attaches one to some 404s and not others — so
    /// `catch .daemonRejected(statusCode: 404)` is a branch that works against a
    /// stub with no body and silently stops working against the robot.
    public var statusCode: Int? {
        switch self {
        case let .daemonRejected(statusCode): statusCode
        case let .daemonRefused(statusCode, _): statusCode
        // Spelled out rather than `default`, so a later case carrying a status code
        // is a compile error here instead of quietly reporting nil.
        case .invalidAddress, .notConnected, .unsupportedDaemonVersion,
             .backendNotRunning, .daemonBusy, .wirelessFeaturesUnavailable,
             .renameUnavailable, .appsUnavailable, .hfAuthUnavailable,
             .daemonLogsUnavailable, .teleopUnavailable, .powerTransitionInFlight,
             .soundboardUnavailable, .soundTooLarge, .soundTypeUnsupported, .soundNameRejected,
             .audioTuningUnavailable, .movesUnavailable:
            nil
        }
    }

    /// The reason out of a refusal's body, if it carries one a person can read.
    ///
    /// FastAPI's `detail` is a string for an `HTTPException` and a *list* of field
    /// errors for a validation failure. Only the string form says anything
    /// actionable, so the list form is dropped rather than stringified into
    /// `[{"loc": …}]` and put in front of somebody.
    static func detail(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] as? String
        else { return nil }
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension ReachyKitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidAddress(address):
            "Invalid robot address: \(address.host):\(address.port)"
        case .notConnected:
            "Not connected to a robot"
        case let .unsupportedDaemonVersion(reported, minimum):
            "Unsupported daemon \(reported); this app requires daemon \(minimum)"
        case .backendNotRunning:
            "The robot backend is not running — start it before moving the robot"
        case .daemonBusy:
            "The daemon is busy with another operation; try again in a moment"
        case .wirelessFeaturesUnavailable:
            "This robot does not offer Wi-Fi setup or software updates over the network"
        case .renameUnavailable:
            "This daemon cannot rename the robot — update the robot software to change its name"
        case .appsUnavailable:
            "Apps cannot be managed over this connection"
        case .hfAuthUnavailable:
            "This robot's Hugging Face account cannot be reached over this connection"
        case let .daemonRejected(statusCode):
            "The daemon rejected the request (HTTP \(statusCode))"
        // The daemon's own sentence first, because it is the part that says what to
        // do about it; the status stays for the screenshot in a bug report.
        case let .daemonRefused(statusCode, detail):
            "\(detail) (HTTP \(statusCode))"
        case .daemonLogsUnavailable:
            "The daemon's logs cannot be read over this connection"
        case .teleopUnavailable:
            "The robot cannot be driven over this connection"
        case .powerTransitionInFlight:
            "The robot is waking up or going to sleep; try again in a moment"
        case .soundboardUnavailable:
            "The robot's sounds cannot be reached over this connection"
        case .audioTuningUnavailable:
            "The robot's audio board cannot be reached over this connection"
        case .movesUnavailable:
            "The robot's moves cannot be played over this connection"
        case let .soundTooLarge(bytes, limit):
            """
            \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) is more than the robot \
            accepts (\(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)))
            """
        case let .soundTypeUnsupported(name):
            "\(name) is not an audio file the robot can play — try WAV, MP3, OGG, Opus, FLAC, M4A or AAC"
        case let .soundNameRejected(name):
            "The robot cannot accept a file called \(name) — rename it and try again"
        }
    }
}
