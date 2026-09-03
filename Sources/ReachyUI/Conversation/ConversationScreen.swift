import ReachyDesign
import ReachyKit
import SwiftUI

/// What Reachy hears and says, for as long as this app is watching.
///
/// Pushed from `AppDetailSheet`, which is the one host reachable on **both** transports:
/// over a relay the Apps tab has no store to hang a link on, but the dock still expands
/// onto that page. See `ConversationLink`.
struct ConversationScreen: View {
    let app: RobotApp
    let session: RobotSession
    /// `@Bindable` because the composer writes the draft back through it. The model
    /// itself is owned by `ReachyTabShell` — this screen adopts one, it never builds one.
    @Bindable var model: ConversationModel

    @Environment(\.reachyPreviewMode) private var isPreview
    @Environment(\.scenePhase) private var scenePhase
    @State private var isComposing = false
    @State private var isShowingVoices = false
    @State private var isConfirmingClear = false
    @FocusState private var isDraftFocused: Bool

    var body: some View {
        content
            .navigationTitle(.reachy("Conversation"))
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .sheet(isPresented: $isShowingVoices) {
                ConversationVoiceSheet(app: app, session: session)
            }
            .confirmationDialog(
                Text(model.clearConfirmation.title),
                isPresented: $isConfirmingClear,
                titleVisibility: .visible
            ) {
                Button(model.clearConfirmation.confirm, role: .destructive) { model.clear() }
            } message: {
                Text(model.clearConfirmation.message)
            }
            .task(id: primingKey) {
                guard !isPreview, primingKey != nil else { return }
                await model.prime(app: app, session: session)
            }
    }

    /// The ladder, and it departs from the log console's on one point deliberately: a
    /// failure replaces the list **only while the list is empty**. A log tail's value is
    /// the live feed, so a frozen tail with no explanation reads as "no output". A
    /// transcript's value is the record, and the explanation is not missing — it is the
    /// marker row at its tail. Discarding an unrecoverable record to show a sentence
    /// already on screen would be the worse of the two wrongs.
    @ViewBuilder
    private var content: some View {
        if model.hasTranscript {
            ConversationTranscriptList(entries: model.entries, isFrozen: !model.isLive)
        } else {
            ConversationUnavailableView(phase: model.phase, settingsURL: settingsURL)
        }
    }

    // MARK: The bar

    @ViewBuilder
    private var bottomBar: some View {
        if isComposing {
            ConversationComposer(
                draft: $model.draft,
                isFocused: $isDraftFocused,
                canSend: model.canSend,
                failure: model.lastError,
                send: { Task { await model.send(app: app, session: session) } },
                cancel: {
                    isComposing = false
                    isDraftFocused = false
                }
            )
        } else {
            ConversationControlBar(
                turn: model.turn,
                level: model.level,
                isMicrophoneMuted: model.isMicrophoneMuted,
                isEnabled: model.isLive && !model.isBusy,
                offersControls: model.offersControls,
                failure: model.lastError,
                perform: perform,
                hold: hold
            )
        }
    }

    private func perform(_ action: ConversationControlBar.Action) {
        switch action {
        case .toggleMicrophone:
            Task { await model.setMicrophoneMuted(!model.isMicrophoneMuted, app: app, session: session) }
        case .interrupt:
            Task { await model.interrupt(app: app, session: session) }
        case .compose:
            isComposing = true
            isDraftFocused = true
        }
    }

    /// Press-and-hold is momentary: unmute on press, and mute on release **whatever
    /// happened to the press**. The two failures are not symmetric — a microphone left
    /// open is the one outcome this control cannot produce.
    private func hold(_ isPressing: Bool) {
        Task {
            if isPressing {
                await model.setMicrophoneMuted(false, app: app, session: session)
            } else {
                await model.endHold(app: app, session: session)
            }
        }
    }

    // MARK: Chrome

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                isShowingVoices = true
            } label: {
                Label(.reachy("Voice & personality"), systemImage: "person.wave.2")
            }
            .disabled(!model.isLive)
        }
        ToolbarItem(placement: .secondaryAction) {
            Menu {
                Button(.reachy("Copy transcript"), systemImage: "doc.on.doc") {
                    Clipboard.copy(model.transcriptText)
                }
                .disabled(!model.hasTranscript)
                Button(.reachy("Clear"), systemImage: "trash", role: .destructive) {
                    isConfirmingClear = true
                }
                .disabled(model.entries.isEmpty)
            } label: {
                Label(.reachy("More"), systemImage: "ellipsis.circle")
            }
        }
    }

    /// The app's own settings page, where the backend key is set. Nil over a relay and
    /// for an app that is not running — the page is served by the app's own process.
    private var settingsURL: URL? {
        session.appSettingsURL(for: app)
    }

    /// Nil while there is nothing to read: backgrounded, or a transport that does not
    /// carry the app's control surface. `scenePhase` goes **into** the key rather than
    /// into a second modifier, so one identity governs the whole task.
    private var primingKey: String? {
        guard scenePhase == .active, session.canControlConversation else { return nil }
        return "\(app.id)@\(session.isRemote ? "relay" : "lan")"
    }
}

/// The composer, revealed in place of the control bar.
///
/// Revealed rather than permanent: a field always on screen misrepresents which input is
/// primary on a screen about talking, and on an iPhone the keyboard it summons covers most
/// of the transcript for something used occasionally. A sheet was the other candidate and
/// loses — it would hide the answer arriving.
struct ConversationComposer: View {
    @Binding var draft: String
    @FocusState.Binding var isFocused: Bool
    let canSend: Bool
    let failure: String?
    let send: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let failure {
                Text(failure)
                    .font(Typography.status)
                    .foregroundStyle(Tone.warning.style)
            }
            HStack(spacing: Space.sm) {
                TextField(.reachy("Type something to say"), text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1 ... 4)
                    .focused($isFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .accessibilityLabel(.reachy("Message for Reachy"))
                    .accessibilityHint(Text(Self.honesty))
                Button(.reachy("Send"), action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
                Button(.reachy("Cancel"), action: cancel)
                    .buttonStyle(.bordered)
            }
            // **The claim this control must not overstate.** The app injects the text as
            // a user message and asks the model to answer it; the robot does not read the
            // words out, and they never come back as a transcript line.
            Text(Self.honesty)
                .font(Typography.footer)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .reachySurface(.scrim, ignoringSafeArea: .bottom)
    }

    static let honesty = LocalizedStringResource.reachy(
        // swiftlint:disable:next line_length
        "Reachy answers what you type as if you had said it out loud. It does not read your words back. Sending while Reachy is talking cuts it off."
    )
}
