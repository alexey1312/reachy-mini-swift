import Foundation

/// The speaker and microphone levels.
///
/// A protocol of its own for the reason ``AudioTuningClient`` is one: conforming *is*
/// the capability. These used to be ``RobotAPIClient`` requirements with throwing
/// defaults, and a client with no speaker at all — the in-app simulator, which
/// declines everything a robot's own hardware would answer — then looked exactly
/// like one that has one. Settings drew the Audio section for it, the default threw
/// `URLError(.unsupportedURL)`, and the section printed
/// "NSURLErrorDomain error -1002" under two dead sliders.
public protocol AudioLevelClient: Sendable {
    func volume() async throws -> AudioLevel
    func setVolume(_ percent: Int) async throws -> AudioLevel
    func microphoneVolume() async throws -> AudioLevel
    func setMicrophoneVolume(_ percent: Int) async throws -> AudioLevel
}

/// The daemon's test sound, split from the levels because the relay has the one and
/// not the other: its data channel carries `get_volume` and `set_volume` but no test
/// sound, which is `POST /api/volume/test-sound` on the LAN alone. It too was a
/// throwing default, so over the relay the button answered with -1002.
public protocol TestSoundClient: Sendable {
    func playTestSound() async throws
}

extension RobotConnection: AudioLevelClient, TestSoundClient {}

public extension RobotSession {
    /// True over the LAN and the relay, false for the in-app simulator.
    var canAdjustAudio: Bool {
        client is any AudioLevelClient
    }

    /// True over the LAN alone.
    var canPlayTestSound: Bool {
        client is any TestSoundClient
    }
}

extension RobotSession {
    /// Through ``withClient``, so the daemon-version gate still fires first; then
    /// throws and says nothing else, the way ``withAudioTuningClient`` does — a
    /// control that failed belongs to the screen that moved it.
    func withAudioLevelClient<T>(_ call: (any AudioLevelClient) async throws -> T) async throws -> T {
        try await withClient { client in
            guard let levels = client as? any AudioLevelClient else {
                throw ReachyKitError.audioLevelsUnavailable
            }
            return try await call(levels)
        }
    }

    func withTestSoundClient<T>(_ call: (any TestSoundClient) async throws -> T) async throws -> T {
        try await withClient { client in
            guard let sound = client as? any TestSoundClient else {
                throw ReachyKitError.audioLevelsUnavailable
            }
            return try await call(sound)
        }
    }
}
