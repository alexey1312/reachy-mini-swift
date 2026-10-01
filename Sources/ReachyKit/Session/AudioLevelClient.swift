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

/// The daemon's test sound, split from the levels because a client can have the one
/// and not the other: the in-app simulator has neither, and the relay used to be
/// read as having only the levels. It carries no route named after the test sound,
/// but it does carry `play_sound`, which is all that route calls — see
/// `RemoteRobotConnection+TestSound.swift` (#169). It too was a throwing default, so
/// over the relay the button once answered with -1002.
public protocol TestSoundClient: Sendable {
    func playTestSound() async throws
}

extension RobotConnection: AudioLevelClient, TestSoundClient {}

public extension RobotSession {
    /// True over the LAN and the relay, false for the in-app simulator.
    var canAdjustAudio: Bool {
        client is any AudioLevelClient
    }

    /// True over the LAN and the relay, false for the in-app simulator.
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
