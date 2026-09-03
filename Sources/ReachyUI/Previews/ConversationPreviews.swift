import ReachyKit
@testable import ReachyUI
import SwiftUI

// The conversation screen, one preview per state a reader can land in (project rule 8).
//
// The failure states are the point of this set rather than an afterthought: a frozen
// transcript has to read as a record that ended, never as a screen that broke, and that
// is a claim only a picture can settle.

#Preview("Conversation — speaking") {
    PreviewScene.conversation(
        .preview(
            entries: ConversationModel.previewExchange,
            turn: .speaking,
            level: ConversationLevel(role: .assistant, rms: 0.7)
        )
    )
}

#Preview("Conversation — listening") {
    PreviewScene.conversation(
        .preview(
            entries: ConversationModel.previewExchange,
            turn: .listening,
            level: ConversationLevel(role: .user, rms: 0.45)
        )
    )
}

#Preview("Conversation — thinking") {
    PreviewScene.conversation(.preview(entries: ConversationModel.previewExchange, turn: .thinking))
}

// The microphone's other state. It is carried by the fill, the slashed glyph and the
// sentence together, so this captures all three at once.
#Preview("Conversation — muted") {
    PreviewScene.conversation(
        .preview(entries: ConversationModel.previewExchange, turn: .ready, isMicrophoneMuted: true)
    )
}

// The sentence this whole screen exists to be honest about.
#Preview("Conversation — nothing said yet") {
    PreviewScene.conversation(.preview())
}

// Rows present and no turn known. The app reports its state only when it changes, so a
// client attaching mid-conversation legitimately knows nothing — and says so rather than
// showing a "Ready" nobody reported.
#Preview("Conversation — waiting for the first turn") {
    PreviewScene.conversation(.preview(entries: ConversationModel.previewExchange))
}

#Preview("Conversation — still starting") {
    PreviewScene.conversation(.preview(phase: .preparing))
}

// The transcript is kept and the tail says where the feed stopped. Losing the record to
// show a sentence already on it would be the worse of the two wrongs.
#Preview("Conversation — feed lost") {
    PreviewScene.conversation(
        .preview(
            entries: ConversationModel.previewExchange + [
                TranscriptEntry(kind: .gap, text: String(localized: .reachy("The feed stopped here."))),
            ],
            phase: .interrupted
        )
    )
}

#Preview("Conversation — app stopped") {
    PreviewScene.conversation(
        .preview(
            entries: ConversationModel.previewExchange + [
                TranscriptEntry(
                    kind: .ended(.appStopped),
                    text: String(localized: .reachy("The app stopped here."))
                ),
            ],
            phase: .unavailable(.appStopped)
        )
    )
}

// The pair above and below is what proves the ladder's top rung is conditional: with a
// record the list survives, and without one the empty state replaces it.
#Preview("Conversation — stopped with nothing recorded") {
    PreviewScene.conversation(.preview(phase: .unavailable(.appStopped)))
}

#Preview("Conversation — app not answering") {
    PreviewScene.conversation(.preview(phase: .unavailable(.appUnavailable)))
}

// The transcript still arrives; only the controls are gone. An older build of the app
// answers `-32601` for the methods behind them.
#Preview("Conversation — older app build") {
    PreviewScene.conversation(
        .preview(entries: ConversationModel.previewExchange, turn: .ready, offersControls: false)
    )
}

// The action is offered here because the app's own settings page is reachable.
#Preview("Conversation — needs a voice backend") {
    PreviewScene.conversation(.preview(phase: .backendUnconfigured))
}

// The same state over a relay, where it is **not**. A reference for the offered action
// alone cannot tell a conditional control from a permanent one.
#Preview("Conversation — needs a voice backend over the relay") {
    PreviewScene.conversation(
        .preview(phase: .backendUnconfigured),
        session: .preview(link: .remote, runningApp: RobotAppStatus(app: .previewConversation, state: .running))
    )
}

#Preview("Conversation — this connection cannot carry it") {
    PreviewScene.conversation(.preview(phase: .unavailable(.noTransport)))
}

// The composer and the sentence under it, which is the whole of what keeps `say` from
// promising something the robot does not do.
#Preview("Conversation — typing") {
    PreviewScene.conversation(
        .preview(entries: ConversationModel.previewExchange, turn: .ready, draft: "happy birthday")
    )
}

// A typed row followed by the answer it drew. The one frame that shows a sent message is
// answered rather than read out.
#Preview("Conversation — typed and answered") {
    PreviewScene.conversation(.preview(entries: ConversationModel.previewTypedExchange, turn: .ready))
}

#Preview("Conversation — a command was refused") {
    PreviewScene.conversation(
        .preview(
            entries: ConversationModel.previewExchange,
            turn: .ready,
            lastError: "The app did not answer in time"
        )
    )
}

// A future state the app grew and this build has not heard of, carried through as the
// app's own word rather than dropped.
#Preview("Conversation — an unknown turn state") {
    PreviewScene.conversation(
        .preview(entries: ConversationModel.previewExchange, turn: .unknown("summarising"))
    )
}

#Preview("Voice & personality — loaded") {
    PreviewScene.conversationVoices(.preview())
}

// A disabled picker with no reason attached tells the reader nothing to act on.
#Preview("Voice & personality — locked") {
    PreviewScene.conversationVoices(
        .preview(
            personalities: ConversationPersonalities(
                choices: ["default", "noir_detective"],
                current: "noir_detective",
                startup: "noir_detective",
                isLocked: true,
                lockedTo: "noir_detective"
            )
        )
    )
}

// `voices.current` is a different call from `voices.list`, so a voice set through the
// app's own page can legitimately not be in it — a state to report, not a choice.
#Preview("Voice & personality — a voice the list does not have") {
    PreviewScene.conversationVoices(.preview(currentVoice: "shimmer"))
}

// The failure sits beside the controls rather than replacing them: these pickers are the
// whole reason the sheet exists.
#Preview("Voice & personality — the list failed") {
    PreviewScene.conversationVoices(
        .preview(voices: [], currentVoice: nil, failure: "The app did not answer in time")
    )
}

// Never answered, which is not the same as answered empty.
#Preview("Voice & personality — loading") {
    PreviewScene.conversationVoices(
        .preview(personalities: nil, voices: [], currentVoice: nil, hasLoaded: false)
    )
}

// The link's presence on the one page that hosts it, reached on either transport.
#Preview("App detail — conversation running") {
    PreviewScene.appDetail(
        .preview(runningApp: RobotAppStatus(app: .previewConversation, state: .running)),
        app: .previewConversation
    )
}
