import ReachyDesign
import ReachyKit
import SwiftUI

/// First-run setup over Bluetooth: Welcome → Scan → PIN → Network → Joining → Handoff.
///
/// A sheet rather than a navigation route, because it owns a radio link that has to come
/// down however the user leaves — and because it is never something the app waits on.
struct OnboardingFlow: View {
    var onFinish: (OnboardingOutcome) -> Void
    var onCancel: () -> Void

    @State private var model: OnboardingModel

    @MainActor
    init(
        model: OnboardingModel? = nil,
        onFinish: @escaping (OnboardingOutcome) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onFinish = onFinish
        self.onCancel = onCancel
        _model = State(initialValue: model ?? OnboardingModel())
    }

    var body: some View {
        NavigationStack {
            step
                .navigationTitle(.reachy("Set up a robot"))
                .toolbarTitleStyle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(.reachy("Cancel")) {
                            model.cancel()
                            onCancel()
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var step: some View {
        switch model.step {
        case .welcome:
            OnboardingWelcomeStep(model: model)
        case .scan:
            OnboardingScanStep(model: model)
        case .pin:
            OnboardingPINStep(model: model)
        case .network:
            OnboardingNetworkStep(model: model)
        case .joining:
            OnboardingJoinStep(model: model)
        case .handoff:
            OnboardingHandoffStep(model: model, onFinish: onFinish)
        }
    }
}

/// The shape every step shares: one heading, one explanation, whatever the step needs in
/// the middle as form sections, and its actions pinned to the bottom where a thumb is.
///
/// A grouped `Form` rather than a `ScrollView` of loose views, which is what this was:
/// every other screen in the app is one, and the steps that take input — a code, a
/// network, a password — drew bordered text fields on a flat page that matched nothing
/// else the reader had seen. The heading section is drawn on the page rather than in a
/// row, the way the store's section picker is.
struct OnboardingStepScaffold<Content: View, Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(title)
                        .font(Typography.screenTitle.bold())
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(Color.clear)
                // Not `EdgeInsets()`: flush with the cell's edge, the bold heading's
                // first glyph was clipped by its own overhang — measured on the
                // booted simulator, where "Before you start" lost the top of its B.
                .listRowInsets(EdgeInsets(top: 0, leading: Space.xs, bottom: 0, trailing: Space.xs))
            }
            content()
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Space.sm) {
                actions()
            }
            .padding()
            .frame(maxWidth: .infinity)
            // `.page` and not `.scrim`, which is what this was. A scrim carries
            // glass, glass renders a light surface whatever is behind it, and this
            // footer sits at the bottom of a sheet where — on the steps that fit on
            // one screen, which is most of them — nothing passes under it at all.
            // So the effect backed no content and read as a grey strip stuck to the
            // bottom of the screen with a button in it. The page's own background
            // still hides what scrolls under it on the steps that do scroll, and
            // says nothing on the ones that do not.
            .reachySurface(.page, ignoringSafeArea: .bottom)
        }
        .groupedPageBackground()
    }
}

/// Renders itself only where stepping back means something: once the password is on its
/// way to the robot, there is nothing to go back to.
struct OnboardingBackButton: View {
    let model: OnboardingModel

    var body: some View {
        if model.canGoBack {
            Button(.reachy("Back")) { model.back() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }
}

private extension View {
    func toolbarTitleStyle() -> some View {
        #if os(iOS)
            navigationBarTitleDisplayMode(.inline)
        #else
            self
        #endif
    }
}
