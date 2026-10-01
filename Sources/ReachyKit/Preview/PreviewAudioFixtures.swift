#if DEBUG
    import Foundation

    // The two preview clients' audio, split out of `PreviewFixtures.swift`, which it
    // took past SwiftLint's file length.

    /// `SettingsScreen` tests the client for the first before drawing the Audio
    /// section, and the section tests it for the second before drawing Test sound —
    /// so without these every `Settings —` reference would lose both, as the in-app
    /// simulator does. The writes are inert: they answer the level already held.
    extension PreviewRobotClient: AudioLevelClient, TestSoundClient {
        public func setVolume(_: Int) async throws -> AudioLevel {
            speaker
        }

        public func setMicrophoneVolume(_: Int) async throws -> AudioLevel {
            microphone
        }

        public func playTestSound() async throws {}
    }

    /// The levels and the test sound, which is what `RemoteRobotConnection` speaks:
    /// `get_volume` and `set_volume` ride the data channel, and so does `play_sound`,
    /// the one call the LAN's test-sound route makes (#169). So `Presence — over the
    /// relay` draws the Audio section with its Test sound button, as a relayed robot
    /// does — it once drew none, on the belief that the relay had no way to play it.
    extension PreviewRemoteRobotClient: AudioLevelClient, TestSoundClient {
        public func playTestSound() async throws {}

        public func volume() async throws -> AudioLevel {
            AudioLevel(percent: 50)
        }

        public func setVolume(_ percent: Int) async throws -> AudioLevel {
            AudioLevel(percent: percent)
        }

        public func microphoneVolume() async throws -> AudioLevel {
            AudioLevel(percent: 50)
        }

        public func setMicrophoneVolume(_ percent: Int) async throws -> AudioLevel {
            AudioLevel(percent: percent)
        }
    }
#endif
