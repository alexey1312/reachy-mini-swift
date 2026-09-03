import ReachyDesign
import ReachyKit
import SwiftUI

/// Who Reachy is and what it sounds like.
///
/// Behind a toolbar item rather than in the control bar: these are configuration rather
/// than conversation, `personalities.apply` carries a persist decision that needs a row
/// and a footer of its own, and two pickers in the bar would push the transcript off an
/// iPhone.
struct ConversationVoiceSheet: View {
    let app: RobotApp
    let session: RobotSession

    @Environment(\.dismiss) private var dismiss
    @Environment(\.reachyPreviewMode) private var isPreview
    @State private var model: ConversationVoiceModel

    init(app: RobotApp, session: RobotSession, model: ConversationVoiceModel? = nil) {
        self.app = app
        self.session = session
        // Resolved here rather than in a defaulted argument: a default whose value is
        // `@MainActor` compiles in the SwiftPM targets and not in the `Apps/` ones.
        _model = State(initialValue: model ?? ConversationVoiceModel())
    }

    var body: some View {
        NavigationStack {
            Form {
                personalitySection
                voiceSection
            }
            .formStyle(.grouped)
            .navigationTitle(.reachy("Voice & personality"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(.reachy("Done")) { dismiss() }
                }
            }
            .task {
                guard !isPreview else { return }
                await model.load(app: app, session: session)
            }
        }
        .reachySheet()
    }

    // MARK: Personality

    private var personalitySection: some View {
        Section {
            Picker(.reachy("Personality"), selection: personality) {
                ForEach(model.personalities?.choices ?? [], id: \.self) { choice in
                    Text(Self.prettified(choice)).tag(choice as String?)
                }
            }
            .disabled(model.isLocked || model.isBusy)
            Toggle(.reachy("Use it next time too"), isOn: $model.persists)
                .disabled(model.isLocked)
        } header: {
            Text(.reachy("Personality"))
        } footer: {
            // A disabled control with no reason attached tells the reader nothing to act
            // on, so the lock names what it is locked to.
            if model.isLocked {
                Text(.reachy("The app has locked this to \(Self.prettified(model.lockedTo ?? ""))."))
            } else {
                Text(.reachy("Also makes it the personality Reachy starts with."))
            }
        }
    }

    private var personality: Binding<String?> {
        Binding(
            get: { model.personalities?.current },
            set: { selected in
                guard let selected, selected != model.personalities?.current else { return }
                Task { await model.apply(personality: selected, app: app, session: session) }
            }
        )
    }

    // MARK: Voice

    private var voiceSection: some View {
        Section {
            Picker(.reachy("Voice"), selection: voice) {
                // Added only when the robot is using something the list does not have —
                // set through the app's own page, most likely. It cannot be *chosen*: it
                // is a state to report, and picking it would have nothing to write.
                if model.hasUnlistedVoice {
                    Text(.reachy("Set on the robot")).tag(String?.none)
                }
                ForEach(model.voices, id: \.self) { choice in
                    Text(choice).tag(choice as String?)
                }
            }
            .disabled(model.isBusy)
        } header: {
            Text(.reachy("Voice"))
        } footer: {
            // The failure sits beside the controls and never replaces them: these pickers
            // are the whole reason this sheet exists, so hiding them would leave a sheet
            // with nothing in it and nothing said.
            if let failure = model.failure {
                Text(failure).foregroundStyle(Tone.warning.style)
            } else if model.hasUnlistedVoice {
                Text(.reachy("Reachy is using a voice that is not in this list."))
            }
        }
    }

    private var voice: Binding<String?> {
        Binding(
            get: { model.hasUnlistedVoice ? nil : model.currentVoice },
            set: { selected in
                guard let selected, selected != model.currentVoice else { return }
                Task { await model.apply(voice: selected, app: app, session: session) }
            }
        )
    }

    /// `noir_detective` is a directory name, not a title. The app's own web client does
    /// the same thing, and there is no route that answers a display name.
    static func prettified(_ name: String) -> String {
        name
            .replacingOccurrences(of: "user_personalities/", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
