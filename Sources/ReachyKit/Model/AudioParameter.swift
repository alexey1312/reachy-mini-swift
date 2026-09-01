import Foundation

/// One register on the robot's audio board, as `/api/audio/config/*` names it.
///
/// The board carries an XMOS XVF3800, and every microphone control the robot has is
/// one of these registers: the input gain, the automatic gain control, the limiter,
/// and the two noise-suppression floors. The daemon's `media/audio_control_utils.py`
/// holds the full register map; XMOS documents what each name means.
///
/// **The daemon writes no values of its own.** `media/audio_base.py` says so directly:
/// the SDK ships no defaults, so an untouched robot reads back its firmware
/// configuration. A write is global, and it outlives the session that made it.
public struct AudioParameter: Sendable, Equatable {
    /// The register name, e.g. `PP_MIN_NN`. The daemon answers 404 for a name its
    /// map does not hold.
    public let name: String
    /// Most registers hold one number. Some hold several — `AUDIO_MGR_OP_L` holds
    /// two, `AEC_MIC_ARRAY_GEO` holds twelve — so this stays an array.
    public let values: [Double]

    public init(_ name: String, _ values: [Double]) {
        self.name = name
        self.values = values
    }

    /// The first value, which is the whole answer for every register this app writes.
    public var value: Double? {
        values.first
    }
}

/// A named set of microphone registers, applied together.
///
/// Raw registers never reach a person: a number like `0.0045` says nothing about how
/// far away the robot can hear. Each profile writes **the same** registers, so a
/// switch leaves nothing behind from the profile before it.
///
/// The `standard` values were read from a Wireless unit on firmware 2.1.2. The other
/// two move from there, and their numbers are starting points to tune by ear — the
/// right amount of noise suppression depends on the room.
///
/// **Every register here holds a float, and that is a constraint rather than a
/// coincidence.** The daemon types the request body as `list[float]`, so an integer
/// register reaches `ReSpeaker.write` as `1.0` and `struct.pack("i", 1.0)` throws.
/// The daemon counts that as a failure and answers `{"applied": false}`; `verify:
/// false` does not help, because the write itself is what fails. So `PP_AGCONOFF`
/// and `PP_LIMITONOFF` cannot be moved from here — measured against firmware 2.1.2,
/// and re-read unchanged on a daemon-1.10.0 robot whose board is still 2.1.2
/// (`GET /api/audio/config/parameter/VERSION`; see `docs/research/audio.md`),
/// where every integer register refused and every float register took. Both are on
/// already, and neither profile wants them off.
public enum MicrophoneProfile: String, Sendable, CaseIterable, Identifiable {
    /// What the audio board holds before anything writes to it.
    case standard
    /// Hears a quiet voice, and a voice from across the room. It raises the level the
    /// gain control aims for and gives the limiter more headroom, so the robot lifts
    /// a distant voice instead of leaving it near the noise floor.
    case sensitive
    /// Holds back a noisy room. It drops both noise-suppression floors and lowers the
    /// gain ceiling, because gain applied to a quiet voice lifts the noise with it.
    case noisy

    public var id: String {
        rawValue
    }

    /// The registers this profile writes. Every profile names all of them.
    public var parameters: [AudioParameter] {
        switch self {
        case .standard:
            [
                AudioParameter("PP_AGCDESIREDLEVEL", [0.0045]),
                AudioParameter("PP_AGCMAXGAIN", [64]),
                AudioParameter("PP_LIMITPLIMIT", [0.47]),
                AudioParameter("PP_MIN_NS", [0.15]),
                AudioParameter("PP_MIN_NN", [0.51]),
            ]
        case .sensitive:
            [
                AudioParameter("PP_AGCDESIREDLEVEL", [0.015]),
                AudioParameter("PP_AGCMAXGAIN", [64]),
                AudioParameter("PP_LIMITPLIMIT", [0.7]),
                AudioParameter("PP_MIN_NS", [0.15]),
                AudioParameter("PP_MIN_NN", [0.51]),
            ]
        case .noisy:
            [
                AudioParameter("PP_AGCDESIREDLEVEL", [0.008]),
                AudioParameter("PP_AGCMAXGAIN", [32]),
                AudioParameter("PP_LIMITPLIMIT", [0.6]),
                AudioParameter("PP_MIN_NS", [0.06]),
                AudioParameter("PP_MIN_NN", [0.18]),
            ]
        }
    }

    /// The profile whose values match `parameters`, or nil for a robot somebody tuned
    /// by hand. The comparison is loose because the board rounds a float on the way
    /// back — the daemon verifies its own writes to `1e-3` for the same reason.
    public static func matching(_ parameters: [AudioParameter]) -> MicrophoneProfile? {
        let read = Dictionary(parameters.map { ($0.name, $0.value ?? 0) }, uniquingKeysWith: { first, _ in first })
        return allCases.first { profile in
            profile.parameters.allSatisfy { expected in
                guard let actual = read[expected.name], let want = expected.value else { return false }
                return abs(actual - want) <= max(1e-3, abs(want) * 1e-2)
            }
        }
    }
}
