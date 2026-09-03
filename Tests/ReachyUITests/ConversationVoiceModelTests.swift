import Foundation
import ReachyKit
@testable import ReachyUI
import Testing

/// The two pickers, and the three states each of them can be in that a reference image
/// cannot tell apart: never answered, answered empty, and answered with something the
/// other call does not list.
@MainActor
@Suite("Conversation voice model")
struct ConversationVoiceModelTests {
    private static let app = RobotApp.preview(name: "reachy_mini_conversation_app", installed: true)

    private func session() -> RobotSession {
        .preview(runningApp: RobotAppStatus(app: Self.app, state: .running))
    }

    private func model(
        personalities: @escaping ConversationVoiceModel.ReadPersonalities = { _, _ in
            ConversationPersonalities(choices: ["default", "noir_detective"], current: "default", startup: "default")
        },
        apply: @escaping ConversationVoiceModel.ApplyPersonality = { _, _, _, _ in },
        voices: @escaping ConversationVoiceModel.ReadVoices = { _, _ in ["alloy", "verse"] },
        currentVoice: @escaping ConversationVoiceModel.ReadCurrentVoice = { _, _ in "alloy" },
        applyVoice: @escaping ConversationVoiceModel.ApplyVoice = { _, _, _ in }
    ) -> ConversationVoiceModel {
        ConversationVoiceModel(
            readPersonalities: personalities,
            applyPersonality: apply,
            readVoices: voices,
            readCurrentVoice: currentVoice,
            applyVoiceCommand: applyVoice
        )
    }

    @Test("a loaded sheet carries both lists and both current values")
    func loadsBothLists() async {
        let model = model()

        await model.load(app: Self.app, session: session())

        #expect(model.personalities?.choices == ["default", "noir_detective"])
        #expect(model.voices == ["alloy", "verse"])
        #expect(model.currentVoice == "alloy")
        #expect(model.hasLoaded)
        #expect(model.failure == nil)
    }

    /// **The failure goes beside the controls, never in place of them.**
    /// `AudioSettingsSection` hides its picker on a failed enumeration and is right to:
    /// it is one optional row among four that still work. Here the pickers are the whole
    /// reason the sheet exists, so hiding them leaves a sheet with nothing in it and no
    /// explanation of why.
    @Test("a failed voice list keeps the personality list and reports beside it")
    func keepsWhatLoadedWhenHalfFails() async {
        let model = model(voices: { _, _ in throw ConversationFailure.timedOut })

        await model.load(app: Self.app, session: session())

        #expect(model.personalities?.choices.isEmpty == false)
        #expect(model.failure != nil)
        #expect(model.hasLoaded)
    }

    /// `voices.current` is a different call from `voices.list`, so a voice set through the
    /// app's own web page can legitimately not be in the list. That is a state to report,
    /// not a choice to offer — the `canTuneProfile` distinction.
    @Test("a voice the list does not have is reported rather than silently changed")
    func reportsAnUnlistedVoice() async {
        let model = model(currentVoice: { _, _ in "shimmer" })

        await model.load(app: Self.app, session: session())

        #expect(model.hasUnlistedVoice)
        #expect(model.currentVoice == "shimmer")
        #expect(!model.voices.contains("shimmer"))
    }

    @Test("a voice that is in the list is not reported as unlisted")
    func acceptsAListedVoice() async {
        let model = model()

        await model.load(app: Self.app, session: session())

        #expect(!model.hasUnlistedVoice)
    }

    /// A disabled control with no reason attached tells the reader nothing to act on, so
    /// the lock has to name what it is locked to.
    @Test("a locked personality is disabled and names what it is locked to")
    func namesTheLock() async {
        let model = model(personalities: { _, _ in
            ConversationPersonalities(
                choices: ["default"],
                current: "noir_detective",
                isLocked: true,
                lockedTo: "noir_detective"
            )
        })

        await model.load(app: Self.app, session: session())

        #expect(model.isLocked)
        #expect(model.lockedTo == "noir_detective")
    }

    /// Cheap to call from `.task` on every appearance, which is what lets the sheet be
    /// re-entered without a second round of calls.
    @Test("loading twice reads once")
    func loadsOnce() async {
        let reads = Counter()
        let model = model(personalities: { _, _ in
            reads.increment()
            return ConversationPersonalities(choices: ["default"], current: "default")
        })
        let session = session()

        await model.load(app: Self.app, session: session)
        await model.load(app: Self.app, session: session)

        #expect(reads.value == 1)
    }

    /// A refresh keeps whatever is already up, so a re-read never blanks the sheet.
    @Test("an explicit refresh reads again")
    func refreshesOnDemand() async {
        let reads = Counter()
        let model = model(personalities: { _, _ in
            reads.increment()
            return ConversationPersonalities(choices: ["default"], current: "default")
        })
        let session = session()

        await model.load(app: Self.app, session: session)
        await model.refresh(app: Self.app, session: session)

        #expect(reads.value == 2)
        #expect(model.personalities != nil)
    }

    /// The app locked the profile deliberately, so `force` is not offered and the refusal
    /// is reported.
    @Test("a refused personality is reported rather than forced")
    func reportsARefusedPersonality() async {
        let model = model(apply: { _, _, _, _ in
            throw ConversationFailure.rejected(code: -32000, reason: .profileLocked, message: "Profile locked")
        })
        await model.load(app: Self.app, session: session())

        await model.apply(personality: "noir_detective", app: Self.app, session: session())

        #expect(model.failure != nil)
    }

    /// A directory name is not a title, and there is no route that answers one — so the
    /// app's own web client prettifies too.
    @Test("a profile directory name reads as a title")
    func prettifiesNames() {
        #expect(ConversationVoiceSheet.prettified("noir_detective") == "Noir Detective")
        #expect(ConversationVoiceSheet.prettified("user_personalities/my_bot") == "My Bot")
    }
}

/// The reason-to-sentence table. A reference image certifies the layout and never the
/// wording, which is why these are asserted here — the `WedgedAppNotice` precedent.
@MainActor
@Suite("Conversation unavailable copy")
struct ConversationUnavailableViewTests {
    @Test("every phase names its own reason")
    func namesEveryReason() {
        let phases: [ConversationModel.Phase] = [
            .preparing,
            .live,
            .interrupted,
            .backendUnconfigured,
            .unavailable(.appStopped),
            .unavailable(.appUnavailable),
            .unavailable(.methodMissing),
            .unavailable(.noTransport),
        ]
        let titles = phases.map(ConversationUnavailableView.title(for:))
        let messages = phases.map(ConversationUnavailableView.message(for:))

        #expect(Set(titles).count == phases.count)
        #expect(Set(messages).count == phases.count)
        #expect(titles.map(\.isEmpty).contains(true) == false)
    }

    /// The sentence the whole screen exists to be honest about.
    @Test("the empty state says the robot keeps no transcript")
    func admitsThereIsNoHistory() {
        #expect(ConversationUnavailableView.message(for: .live).contains("keeps no transcript"))
    }

    /// A stopped app is told from an unreachable one, because the actions differ: one is
    /// started again, the other is already running and needs restarting.
    @Test("a stopped app and an unanswering one read differently")
    func distinguishesStoppedFromUnreachable() {
        #expect(
            ConversationUnavailableView.title(for: .unavailable(.appStopped))
                != ConversationUnavailableView.title(for: .unavailable(.appUnavailable))
        )
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
