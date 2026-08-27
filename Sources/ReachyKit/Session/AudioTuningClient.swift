import Foundation

/// The robot's audio-board registers: read one, write a batch.
///
/// A protocol of its own rather than two more methods on ``RobotAPIClient``, for the
/// reason ``SoundboardClient`` is one: conforming *is* the capability. A session over
/// the Hugging Face relay reports it unavailable instead of failing a control somebody
/// just moved.
///
/// The daemon opens a short-lived USB handle for every call and closes it again
/// (`routers/audio_config.py`), so a batch of six registers costs one round trip and
/// six reads cost six. Write a profile, do not write a register at a time.
public protocol AudioTuningClient: Sendable {
    /// Reads one register by name. The daemon answers 404 for a name its map does not
    /// hold, and 503 when no audio board answers on USB.
    func readAudioParameter(named name: String) async throws -> AudioParameter

    /// Writes a batch of registers.
    ///
    /// - Parameter verify: the daemon reads each register back and compares it to
    ///   `1e-3` after the write settles. Leave it on: a refused write is otherwise
    ///   indistinguishable from an accepted one.
    func applyAudioConfig(_ parameters: [AudioParameter], verify: Bool) async throws
}

public extension RobotSession {
    /// False over the relay, whose data channel carries no audio-config commands in
    /// this client. The daemon's own protocol does define them, so this can grow a
    /// remote arm later without the screens above changing.
    var canTuneAudio: Bool {
        client is any AudioTuningClient
    }

    /// Reads back the registers a profile writes, and names the profile they match.
    ///
    /// - Returns: nil for a robot somebody tuned by hand, which is a state to show
    ///   rather than to overwrite.
    func microphoneProfile() async throws -> MicrophoneProfile? {
        let names = MicrophoneProfile.standard.parameters.map(\.name)
        var read: [AudioParameter] = []
        for name in names {
            try await read.append(withAudioTuningClient { try await $0.readAudioParameter(named: name) })
        }
        return MicrophoneProfile.matching(read)
    }

    /// Writes a profile to the audio board.
    ///
    /// - Important: the write is global and it outlives this session — every app on
    ///   the robot hears through the registers this moves. Whether it also outlives a
    ///   reboot is a property of the board, not of this call: the register map holds a
    ///   `SAVE_CONFIGURATION` command that nothing here sends.
    func applyMicrophoneProfile(_ profile: MicrophoneProfile) async throws {
        try await withAudioTuningClient {
            try await $0.applyAudioConfig(profile.parameters, verify: true)
        }
    }
}

extension RobotSession {
    /// Throws and says nothing else, the way ``withSoundboardClient`` does: a control
    /// that failed belongs to the screen that moved it, and `robotError` is the
    /// robot's connection and power alone.
    func withAudioTuningClient<T>(_ call: (any AudioTuningClient) async throws -> T) async throws -> T {
        guard let client else { throw ReachyKitError.notConnected }
        guard let tuning = client as? any AudioTuningClient else {
            throw ReachyKitError.audioTuningUnavailable
        }
        return try await call(tuning)
    }
}
