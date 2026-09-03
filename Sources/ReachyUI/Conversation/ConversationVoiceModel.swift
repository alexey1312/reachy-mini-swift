import Foundation
import ReachyKit

/// The personalities and voices the conversation app offers, and what happens when one
/// of them cannot be read.
///
/// **The two picker precedents in this app are split here on purpose, per axis.**
/// Failure takes `NetworkCredentialsFields`' shape — a line *beside* the control, with
/// whatever list is already on screen kept — because here the pickers are the entire
/// reason the sheet exists, and hiding them leaves a sheet with nothing in it and no
/// explanation. The *value* takes `AudioSettingsSection`'s unselectable tag, because
/// `voices.current` is a different call from `voices.list` and a voice set through the
/// app's own web page can legitimately not be in the list.
@MainActor
@Observable
final class ConversationVoiceModel {
    typealias ReadPersonalities = @MainActor (RobotSession, RobotApp) async throws -> ConversationPersonalities
    typealias ApplyPersonality = @MainActor (RobotSession, RobotApp, String, Bool) async throws -> Void
    typealias ReadVoices = @MainActor (RobotSession, RobotApp) async throws -> [String]
    typealias ReadCurrentVoice = @MainActor (RobotSession, RobotApp) async throws -> String?
    typealias ApplyVoice = @MainActor (RobotSession, RobotApp, String) async throws -> Void

    var personalities: ConversationPersonalities?
    var voices: [String] = []
    var currentVoice: String?
    /// Whether the enumerations have ever answered. Kept apart from "the list is empty",
    /// which is a real answer — the same distinction `canTuneProfile` draws.
    var hasLoaded = false
    var isBusy = false
    /// Beside the controls, never in place of them.
    var failure: String?
    /// Persist the personality for the next start as well as this one.
    var persists = false

    let readPersonalities: ReadPersonalities
    let applyPersonality: ApplyPersonality
    let readVoices: ReadVoices
    let readCurrentVoice: ReadCurrentVoice
    let applyVoiceCommand: ApplyVoice

    init(
        readPersonalities: @escaping ReadPersonalities = { try await $0.conversationPersonalities(for: $1) },
        applyPersonality: @escaping ApplyPersonality = {
            try await $0.applyConversationPersonality(named: $2, persist: $3, for: $1)
        },
        readVoices: @escaping ReadVoices = { try await $0.conversationVoices(for: $1) },
        readCurrentVoice: @escaping ReadCurrentVoice = { try await $0.currentConversationVoice(for: $1) },
        applyVoiceCommand: @escaping ApplyVoice = { try await $0.applyConversationVoice($2, for: $1) }
    ) {
        self.readPersonalities = readPersonalities
        self.applyPersonality = applyPersonality
        self.readVoices = readVoices
        self.readCurrentVoice = readCurrentVoice
        self.applyVoiceCommand = applyVoiceCommand
    }

    /// Whether switching is refused by the app itself. A third flag rather than an empty
    /// list: a locked picker has to be *disabled and named*, because a control greyed out
    /// with no reason attached tells the reader nothing to act on.
    var isLocked: Bool {
        personalities?.isLocked == true
    }

    var lockedTo: String? {
        personalities?.lockedTo
    }

    /// A voice the robot is using that the list does not contain — set through the app's
    /// own settings page, most likely. A state to report, not a choice to offer.
    var hasUnlistedVoice: Bool {
        guard let currentVoice else { return false }
        return !voices.contains(currentVoice)
    }

    /// Safe to call from `.task` on every appearance: the guard is what makes a
    /// re-entered sheet cheap, and a refresh keeps whatever rows are already up.
    func load(app: RobotApp, session: RobotSession) async {
        guard !hasLoaded else { return }
        await refresh(app: app, session: session)
    }

    func refresh(app: RobotApp, session: RobotSession) async {
        failure = nil
        do {
            personalities = try await readPersonalities(session, app)
            persists = personalities?.current == personalities?.startup
        } catch {
            failure.recordDaemonFailure(error)
        }
        do {
            voices = try await readVoices(session, app)
            currentVoice = try await readCurrentVoice(session, app)
        } catch {
            failure.recordDaemonFailure(error)
        }
        hasLoaded = true
    }

    /// Applies a personality.
    ///
    /// `force` is never offered: the app locked the profile deliberately, so
    /// `profile_locked` is reported rather than overridden.
    func apply(personality: String, app: RobotApp, session: RobotSession) async {
        // **Only re-read when it took.** A refresh clears the failure slot before it
        // starts, so refreshing after a refusal would wipe the very sentence the refusal
        // just wrote — a `profile_locked` that reported nothing at all.
        guard await run({ try await self.applyPersonality(session, app, personality, self.persists) }) else {
            return
        }
        await refresh(app: app, session: session)
    }

    func apply(voice: String, app: RobotApp, session: RobotSession) async {
        guard await run({ try await self.applyVoiceCommand(session, app, voice) }) else { return }
        currentVoice = voice
    }

    /// - Returns: whether the work succeeded. Callers use it to decide whether to follow
    ///   up, never to decide what to report — that has already happened here.
    @discardableResult
    private func run(_ work: () async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        failure = nil
        do {
            try await work()
            return true
        } catch {
            failure.recordDaemonFailure(error)
            return false
        }
    }
}
