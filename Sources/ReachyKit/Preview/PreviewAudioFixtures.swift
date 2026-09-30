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

    /// The levels and not the test sound, which is what `RemoteRobotConnection`
    /// speaks: `get_volume` and `set_volume` ride the data channel, the test sound is
    /// a LAN route. So `Presence — over the relay` keeps its Audio section and draws
    /// no Test sound button — the button it used to draw could only ever fail.
    extension PreviewRemoteRobotClient: AudioLevelClient {
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
