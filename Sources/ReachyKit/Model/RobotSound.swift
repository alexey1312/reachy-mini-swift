import Foundation

/// One sound file on the robot, named by the only thing that identifies it.
///
/// **The filename is the whole identity.** `GET /api/media/sounds` answers a list of
/// names and nothing else — no id, no size, no duration — and `POST
/// /api/media/play_sound` takes a bare name back. That is what lets ``SoundEntity``
/// resolve a saved shortcut with no cache at all, the property `MoveEntity` has and
/// `RobotAppEntity` cannot.
///
/// It is also the whole of what the robot remembers: uploads land in
/// `/tmp/reachy_mini_sounds`, so the robot's copy is the volatile one and the
/// device's library is what survives a reboot (``SoundLibraryStore``).
public struct RobotSound: Sendable, Hashable, Codable, Identifiable {
    public var id: String {
        filename
    }

    /// As the daemon spells it, extension included — this is what goes back to
    /// `play_sound` and into `DELETE /sounds/{filename}`.
    public let filename: String

    public init(filename: String) {
        self.filename = filename
    }

    /// The name to put in front of a person: no extension, and the separators a
    /// file name uses read as spaces.
    ///
    /// One copy of it, because the screen, the entity's `displayRepresentation`, the
    /// control's label and a spoken match must not spell the same sound four ways.
    public var displayName: String {
        Self.displayName(filename)
    }

    public static func displayName(_ filename: String) -> String {
        let components = filename.split(separator: ".", omittingEmptySubsequences: false)
        let stem = components.count > 1 ? components.dropLast().joined(separator: ".") : filename
        let named = stem.isEmpty ? filename : stem
        return named
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
}

/// What the daemon will accept from an upload, restated here so a refusal costs no
/// round trip and can name the reason.
///
/// Both numbers are the daemon's own (`routers/media.py`), and the second one is
/// **not enforced there**: `MAX_SOUND_UPLOAD_BYTES = 25 * 1024 * 1024` is declared,
/// named in the route's docstring, and never compared against anything as the body
/// is streamed to disk. So this cap is the only one there is — dropping it does not
/// fall back to the daemon's, it removes the limit.
public extension RobotSound {
    /// `ALLOWED_SOUND_EXTENSIONS`, which the daemon checks before touching the disk
    /// and answers 400 for. It then probes the *content* with GStreamer as well, so
    /// passing this check is necessary and not sufficient — a renamed text file is
    /// refused by the robot, and only there.
    static let allowedExtensions: Set<String> = [
        "wav", "mp3", "ogg", "oga", "opus", "flac", "m4a", "aac",
    ]

    static let maxUploadBytes = 25 * 1024 * 1024

    /// Whether the daemon's extension allow-list would accept this name.
    static func isAllowedExtension(_ filename: String) -> Bool {
        let suffix = (filename as NSString).pathExtension.lowercased()
        return allowedExtensions.contains(suffix)
    }

    /// Whether a name can be kept in the device's library and sent to the robot as it
    /// stands.
    ///
    /// Four refusals, each for a place the name ends up rather than for taste: a path
    /// separator would leave ``SoundLibraryStore``'s directory on write and is what
    /// `delete_sound` answers 400 for; `.` and `..` are the daemon's own two special
    /// cases; a quote or a control character would break out of the
    /// `Content-Disposition` header the upload carries it in; and an empty name has
    /// nothing to identify.
    ///
    /// Sanitising instead of refusing was the alternative and is worse: the name *is*
    /// the identity here, so a silently rewritten one would make the device's copy and
    /// the robot's two different sounds, and a saved shortcut point at neither.
    static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard !name.contains("/"), !name.contains("\\") else { return false }
        guard !name.contains("\"") else { return false }
        return name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    /// The last path component, which is all the daemon accepts: `delete_sound`
    /// answers 400 for a name that is not already its own basename, and `play_sound`
    /// would read a path as an absolute location on the robot's filesystem.
    static func basename(_ filename: String) -> String {
        (filename as NSString).lastPathComponent
    }
}
