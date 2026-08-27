import Foundation

/// The audio-board half of the daemon's audio surface: `/api/audio/config/*`.
///
/// A file of its own because `RobotConnection.swift` is at SwiftLint's length limit —
/// the same split `+Sounds`, `+Presence` and `+Apps` make.
extension RobotConnection: AudioTuningClient {
    public func readAudioParameter(named name: String) async throws -> AudioParameter {
        switch try await client.readAudioParameterApiAudioConfigParameterNameGet(path: .init(name: name)) {
        case let .ok(response):
            // The register map holds both floats and integers, and the spec says so
            // with an `anyOf`. The generator answers that with one payload per value
            // that fills `value1` for a float and `value2` for an integer, so a
            // caller that reads only `value1` gets nil for `PP_AGCONOFF`.
            let values = try response.body.json.values.compactMap { number in
                number.value1 ?? number.value2.map(Double.init)
            }
            return try AudioParameter(response.body.json.name, values)
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }

    /// - Note: a 503 here is an audio board that did not answer on USB, not a daemon
    ///   that is down. It is the daemon's own wording for `init_respeaker_usb`
    ///   returning nothing.
    public func applyAudioConfig(_ parameters: [AudioParameter], verify: Bool) async throws {
        let config = parameters.map { Components.Schemas.AudioParamPair(name: $0.name, values: $0.values) }
        let body = Components.Schemas.ApplyAudioConfigRequest(config: config, verify: verify)
        switch try await client.applyAudioConfigApiAudioConfigApplyPost(body: .json(body)) {
        case let .ok(response):
            // `verify: true` makes the daemon read every register back. A false here
            // is a board that took the write and did not keep it, which no status
            // code reports.
            guard try response.body.json.applied else {
                throw ReachyKitError.daemonRejected(statusCode: 200)
            }
        case .unprocessableContent:
            throw ReachyKitError.daemonRejected(statusCode: 422)
        case let .undocumented(statusCode, _):
            throw ReachyKitError.fromStatusCode(statusCode)
        }
    }
}
