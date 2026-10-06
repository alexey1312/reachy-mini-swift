import ReachyDesign
import ReachyKit
import SwiftUI

/// First-run setup over Bluetooth: Welcome → Scan → PIN → Name → Network → Joining → Handoff.
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
        case .name:
            OnboardingNameStep(model: model)
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
/// else the reader had seen. The heading is drawn on the page rather than in a row: it
/// is the header of a section with no rows.
struct OnboardingStepScaffold<Content: View, Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        Form {
            // A header, not a row with a clear background, which is what this was.
            // A row is clipped to its section's rounded corners whatever its
            // background, and the 4 pt inset that was meant to clear them does not
            // clear the radius iOS 26 draws: every step lost the top-left of its
            // heading's first glyph and the bottom-left of its explanation's last
            // line — "Did it move?" shaved at the D, "picture" read as "ɔicture".
            // No cell clips a header, and a section with no rows draws no cell.
            Section {
                EmptyView()
            } header: {
                heading
            }
            content()
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Space.sm) {
                actions()
            }
            // The size of a bottom button everywhere else on the platform. At the
            // regular size the primary action read as a small bar under a thumb,
            // and the way-outs under it as words — reported together from a device.
            .controlSize(.large)
            .padding()
            .frame(maxWidth: .infinity)
            // `.page` and not `.scrim`, which is what this was. A scrim carries
            // glass, glass renders a light surface whatever is behind it, and this
            // footer sits at the bottom of a sheet where — on the steps that fit on
            // one screen, which is most of them — nothing passes under it at all.
            // So the effect backed no content and read as a grey strip stuck to the
            // bottom of the screen with a button in it. The page's own background
            // still hides what scrolls under it on the steps that do scroll, and
            // says nothing on the ones that do not. `groupedPageBackground()` below
            // is what makes it the grouped grey rather than a white band.
            .reachySurface(.page, ignoringSafeArea: .bottom)
        }
        .groupedPageBackground()
    }

    /// The look the heading had as a row, restated for a header. A header styles its
    /// text — a smaller font, a secondary colour, and capitals on some systems — so the
    /// title names its own colour, `font(nil)` hands the explanation back the body text
    /// a row gave it, and `textCase(nil)` keeps the words as written. The insets keep
    /// it where it was: 4 pt in from the edge of the cards below.
    private var heading: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(title)
                .font(Typography.screenTitle.bold())
                .foregroundStyle(.primary)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(nil)
        .textCase(nil)
        .listRowInsets(EdgeInsets(top: 0, leading: Space.xs, bottom: 0, trailing: Space.xs))
    }
}

/// Renders itself only where stepping back means something: once the password is on its
/// way to the robot, there is nothing to go back to.
///
/// Every way-out in a step's footer is this spelling — a quiet, full-width
/// `ReachyActionButton` — so the row is one target the width of the footer and at least
/// `Metrics.minimumHitTarget` tall, where `.plain` text answered only on its words.
struct OnboardingBackButton: View {
    let model: OnboardingModel

    var body: some View {
        if model.canGoBack {
            ReachyActionButton(.reachy("Back"), emphasis: .quiet, fullWidth: true) { model.back() }
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
