import Foundation

/// Every hand-written JSON call in this app, and the rule each kind of payload is
/// read under.
///
/// Three profiles rather than one configured coder, because the profiles differ in
/// what they are *allowed* to become: `.daemon` and `.web` describe somebody else's
/// format and may follow it, while `.stored` describes ours and may not move —
/// records written by shipped builds are on disk right now. `docs/adr/0004-one-json-codec.md`
/// carries the reasoning, including why the engine is Foundation.
///
/// A value that builds its coder per call. Not because sharing one would be unsafe —
/// under this toolchain (Apple Swift 6.3, `-strict-concurrency=complete`)
/// `JSONDecoder`/`JSONEncoder` satisfy `Sendable` and `static let decoder =
/// JSONDecoder()` compiles clean — but because building one was measured and found
/// free: configuring `.daemon`'s decoder (its custom date closure) costs 0.098 µs
/// against 12.1 µs to decode a 240-byte state frame, a `-O` benchmark, under 1% at
/// the hot call site. Per-call construction keeps these profiles immutable values
/// at no measurable cost.
public struct JSONCodec: Sendable {
    /// The robot said it — REST, the four WebSockets, BLE replies, the WebRTC data
    /// channel. FastAPI emits ISO 8601 with fractional seconds and other routes
    /// omit them, so both read.
    public static let daemon = JSONCodec(.daemon)
    /// A third-party service said it — Hugging Face central and its OAuth. Foundation's
    /// defaults today, and free to follow the service tomorrow.
    public static let web = JSONCodec(.web)
    /// We wrote it: `Caches`, `UserDefaults`, the App Group, the Keychain.
    ///
    /// **Frozen.** These settings are what shipped builds encoded with, so changing
    /// one does not reformat the records — it makes them undecodable, which every
    /// store here reports as an empty cache rather than as an error. Change it only
    /// together with the schema version of whatever writes it
    /// (`RobotCatalogueCache.schema` is the precedent).
    public static let stored = JSONCodec(.stored)

    private enum Profile: Sendable {
        case daemon
        case web
        case stored
    }

    private let profile: Profile

    private init(_ profile: Profile) {
        self.profile = profile
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }

    public func encode(_ value: some Encodable) throws -> Data {
        try encoder().encode(value)
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        if case .daemon = profile {
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let string = try container.decode(String.self)
                let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
                if let date = (try? Date(string, strategy: fractional)) ?? (try? Date(string, strategy: .iso8601)) {
                    return date
                }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unrecognized ISO 8601 date: \(string)"
                )
            }
        }
        return decoder
    }

    private func encoder() -> JSONEncoder {
        // No branch yet: nothing in this app sends a `Date` to the robot or to
        // Hugging Face, and `.stored` is frozen on the defaults. The first payload
        // that needs one adds its case here rather than at the call site.
        //
        // That leaves `.daemon` asymmetric: its decoder reads ISO 8601 and this
        // encoder writes Foundation's numeric default. Two sites round-trip a
        // `.daemon` value through both in one process — `RobotApps.Card.init(extra:)`
        // and `RobotConnection.kinematicsInfo()` — so the first `Date` to appear in
        // `AppInfo.extra` or `KinematicsInfo` would fail that decode rather than
        // silently reformat it: the encoder writes a number and the decoder demands
        // a string.
        JSONEncoder()
    }
}
