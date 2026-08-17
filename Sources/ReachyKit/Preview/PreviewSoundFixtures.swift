#if DEBUG
    import Foundation

    /// Same reason as the presence conformance beside it: `canManageSounds` asks the
    /// client whether it speaks this protocol, so without this the soundboard row is
    /// missing from every Moves reference and the gate is covered by nothing.
    ///
    /// The list is a constant rather than a stored property, because no preview reads
    /// it: `SoundboardModel.preview(…)` sets its rows directly, since a preview has to
    /// be final on its first frame and a `.task` is skipped under
    /// `reachyPreviewMode`. What it is for is the storybook, and anything that runs
    /// this double against a live `load`.
    ///
    /// Nothing throws: a preview of a soundboard is a preview of one that works.
    extension PreviewRobotClient: SoundboardClient {
        public static let previewSounds = ["airhorn.wav", "doorbell.mp3", "rimshot.ogg"]

        public func sounds() async throws -> [RobotSound] {
            Self.previewSounds.map(RobotSound.init(filename:))
        }

        public func playSound(named _: String) async throws {}

        public func uploadSound(named _: String, data _: Data) async throws {}

        public func deleteSound(named _: String) async throws {}

        /// Spelled out even though `RobotAPIClient` has a default for it: that default
        /// **throws**, and the storybook's Stop button is never disabled — so leaning on
        /// it would put a red error row under a soundboard that is otherwise working.
        public func stopSound() async throws {}
    }
#endif
