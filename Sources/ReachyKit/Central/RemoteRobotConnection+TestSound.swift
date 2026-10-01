import Foundation

/// The daemon's test sound, over the relay.
///
/// **There is no test-sound command on the data channel, and none is needed.**
/// `POST /api/volume/test-sound` is one line on the daemon's side —
/// `backend.play_sound("impatient1.wav")` (`routers/volume.py`) — and the data
/// channel has carried `play_sound {file}` into that same method since 1.9.0, the
/// oldest daemon this app supports (`process_command` in `daemon/backend/abstract.py`,
/// checked at the `v1.9.0`, `v1.10.0`, `v1.11.0` tags and `main`). So the relay plays
/// the identical file through the identical call; only the route in front differs.
///
/// The reply is `{"status": "ok", "command": "play_sound"}` and says nothing about
/// whether anything was heard — `play_sound` is a no-op without a media server, the
/// same silence the LAN route has. That is why every caller asks a person.
extension RemoteRobotConnection: TestSoundClient {
    /// The asset the LAN route plays, named once so the two cannot drift.
    static let testSoundFile = "impatient1.wav"

    public func playTestSound() async throws {
        try await control.perform("play_sound", payload: ["file": .string(Self.testSoundFile)])
    }
}
