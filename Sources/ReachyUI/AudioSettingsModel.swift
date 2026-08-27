import Foundation
import Observation
import ReachyKit

/// Speaker and microphone levels.
///
/// The sliders track a local value and only reach the daemon when a gesture ends:
/// `POST /api/volume/set` plays a test sound on every accepted call, so a slider
/// that sent on change would make the robot beep continuously.
@MainActor
@Observable
final class AudioSettingsModel {
    var speakerPercent: Double = 0
    var microphonePercent: Double = 0

    private(set) var speaker: AudioLevel?
    private(set) var microphone: AudioLevel?
    /// Nil while unread, and nil again for a board somebody tuned by hand — the two
    /// are told apart by ``canTuneProfile``, which is false until the read succeeds.
    private(set) var profile: MicrophoneProfile?
    private(set) var canTuneProfile = false
    private(set) var isLoading = false
    private(set) var isBusy = false
    private(set) var errorMessage: String?

    private var hasLoaded = false

    var isReady: Bool {
        speaker != nil || microphone != nil
    }

    /// Safe to call from `.task` on every appearance — it fetches once and then
    /// leaves the sliders alone, so a redraw can never yank a value the user is
    /// in the middle of dragging.
    func load(session: RobotSession) async {
        guard !hasLoaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            // Sequential rather than concurrent: two calls against a robot that
            // has no audio device would report the same failure twice.
            try await adoptSpeaker(session.volume())
            try await adoptMicrophone(session.microphoneVolume())
            errorMessage = nil
            hasLoaded = true
            await loadProfile(session: session)
        } catch {
            errorMessage.recordDaemonFailure(error)
        }
    }

    func commitSpeaker(session: RobotSession) async {
        let percent = Int(speakerPercent.rounded())
        // Touching the slider without moving it must not trigger the test sound.
        guard percent != speaker?.percent else { return }
        await perform { try await adoptSpeaker(session.setVolume(percent)) }
    }

    func commitMicrophone(session: RobotSession) async {
        let percent = Int(microphonePercent.rounded())
        guard percent != microphone?.percent else { return }
        await perform { try await adoptMicrophone(session.setMicrophoneVolume(percent)) }
    }

    /// Reads the audio board back, after the levels and never with them.
    ///
    /// It costs one USB round trip per register — the daemon opens and closes a
    /// handle for each — and it is the one part of this screen a robot can lack, so a
    /// failure here leaves the levels working and hides the profile row instead of
    /// reporting an error over them.
    private func loadProfile(session: RobotSession) async {
        guard session.canTuneAudio else { return }
        do {
            profile = try await session.microphoneProfile()
            canTuneProfile = true
        } catch {
            canTuneProfile = false
        }
    }

    /// - Important: this writes the robot's audio board, not a per-session setting.
    ///   Every app on the robot hears through the registers it moves.
    func applyProfile(_ profile: MicrophoneProfile, session: RobotSession) async {
        await perform {
            try await session.applyMicrophoneProfile(profile)
            self.profile = profile
        }
    }

    func playTestSound(session: RobotSession) async {
        await perform { try await session.playTestSound() }
    }

    private func perform(_ call: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await call()
            errorMessage = nil
        } catch {
            errorMessage.recordDaemonFailure(error)
        }
    }

    /// The daemon answers with what it actually applied, which may be clamped, so
    /// the slider follows the robot rather than the other way round.
    private func adoptSpeaker(_ level: AudioLevel) {
        speaker = level
        speakerPercent = Double(level.percent)
    }

    private func adoptMicrophone(_ level: AudioLevel) {
        microphone = level
        microphonePercent = Double(level.percent)
    }
}

#if DEBUG
    extension AudioSettingsModel {
        /// Already loaded, so the view's `.task` returns immediately and the first rendered frame
        /// is the final one. Lives here rather than in `Previews/` because it writes members that
        /// are private to this file.
        static func preview(
            speaker: AudioLevel? = .previewSpeaker,
            microphone: AudioLevel? = .previewMicrophone,
            isLoading: Bool = false,
            isBusy: Bool = false,
            errorMessage: String? = nil,
            profile: MicrophoneProfile? = .standard,
            canTuneProfile: Bool = true
        ) -> AudioSettingsModel {
            let model = AudioSettingsModel()
            model.speaker = speaker
            model.microphone = microphone
            model.speakerPercent = Double(speaker?.percent ?? 0)
            model.microphonePercent = Double(microphone?.percent ?? 0)
            model.isLoading = isLoading
            model.isBusy = isBusy
            model.errorMessage = errorMessage
            model.profile = profile
            model.canTuneProfile = canTuneProfile
            model.hasLoaded = true
            return model
        }
    }
#endif
