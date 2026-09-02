import ReachyDesign
import ReachyKit
import SwiftUI

/// The robots this Hugging Face account can reach, wherever they are.
///
/// The other way into a robot, beside discovery on the local network — and the
/// only one that works from somewhere else. A robot that is off is absent rather
/// than listed as offline: central sweeps a peer whose lease lapsed, so presence
/// in the list *is* the online signal.
struct YourReachiesScreen<SignIn: View>: View {
    /// `@State`, not a `let`, for the same reason `HFAccountSection` holds its own:
    /// this screen is presented from a `.sheet`, and SwiftUI re-runs a sheet's
    /// content closure on every update of the view it hangs off. Adopting the first
    /// model and ignoring later ones is what stops a rebuilt, empty one from
    /// blanking a list the user is reading. The root hands in a stable model as
    /// well — belt and braces, because replacing the model does not restart the
    /// task that fills it. Account changes use a generation on the stable model to
    /// restart that task separately.
    @State private var model: YourReachiesModel
    @Environment(\.reachyPreviewMode) private var previewMode
    /// Called with the robot the user picked. The session is built by whoever
    /// presented this screen — it owns the WebRTC half.
    private let connect: (CentralRobot) -> Void
    /// Pushed rather than presented, so signing in never costs the user the sheet
    /// they opened to find a robot. A view rather than an action because the
    /// account belongs to whoever presented this — this screen lists robots and
    /// has no business knowing what a session or a token is.
    private let signIn: () -> SignIn

    init(
        model: YourReachiesModel,
        connect: @escaping (CentralRobot) -> Void,
        @ViewBuilder signIn: @escaping () -> SignIn
    ) {
        _model = State(initialValue: model)
        self.connect = connect
        self.signIn = signIn
    }

    var body: some View {
        List {
            if let lastRefreshError = model.lastRefreshError {
                Section {
                    Text(lastRefreshError)
                        .font(Typography.status)
                        .foregroundStyle(.secondary)
                }
            }

            switch model.state {
            case let .listed(robots):
                Section {
                    ForEach(robots) { robot in
                        Button {
                            connect(robot)
                        } label: {
                            RemoteRobotRow(robot: robot)
                        }
                        .buttonStyle(.plain)
                        .disabled(robot.isBusy)
                    }
                } footer: {
                    Text(.reachy("Reached through Hugging Face, so these work from anywhere."))
                }
            case .loading, .signedOut, .empty, .needsSignIn, .failed:
                EmptyView()
            }
        }
        .overlay { placeholder }
        .contentLoading(isPresented: model.isContentLoading, title: .reachy("Calling your Reachies home…"))
        .navigationTitle(.reachy("Your Reachies"))
        .refreshable { await model.refresh() }
        .task(id: model.accountGeneration) {
            guard !previewMode else { return }
            await model.load()
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch model.state {
        case .loading:
            EmptyView()
        case .signedOut:
            if !model.isContentLoading {
                ContentUnavailableView {
                    Label(.reachy("Not signed in"), systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text(.reachy("Sign in to Hugging Face to reach robots linked to your account."))
                } actions: {
                    NavigationLink(.reachy("Sign in"), destination: signIn)
                }
            }
        case .needsSignIn:
            // Deliberately not a Retry: the same token will be refused again.
            ContentUnavailableView {
                Label(.reachy("Session expired"), systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text(.reachy("Hugging Face refused this session. Signing in again fixes it."))
            } actions: {
                NavigationLink(.reachy("Sign in again"), destination: signIn)
            }
        case .empty:
            ContentUnavailableView {
                Label(.reachy("No Reachy online"), systemImage: "wifi.slash")
            } description: {
                Text(.reachy("None linked to your Hugging Face account are online."))
            } actions: {
                Button(.reachy("Refresh")) {
                    Task { await model.refresh() }
                }
            }
        case let .failed(reason):
            ContentUnavailableView {
                Label(.reachy("Could not reach Hugging Face"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(reason)
            } actions: {
                Button(.reachy("Try again")) {
                    Task { await model.refresh() }
                }
            }
        case .listed:
            EmptyView()
        }
    }
}

/// One robot as central sees it. Deliberately does not show an address: over the
/// relay there isn't one, and the robot is identified by who owns it.
struct RemoteRobotRow: View {
    let robot: CentralRobot
    /// Scaled with the text beside it — the column was the one thing in the row
    /// that ignored the reader's size setting.
    @ScaledMetric(relativeTo: .title2) private var artworkWidth: CGFloat = 32

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "app.connected.to.app.below.fill")
                // Optical: row artwork, sized against the column it sits in.
                // swiftlint:disable:next raw_font
                .font(.title2)
                // Erased because the two branches are different `ShapeStyle`
                // types, and a ternary needs one.
                .foregroundStyle(robot.isBusy ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: artworkWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(robot.displayName)
                    .font(Typography.rowTitle)
                    .foregroundStyle(robot.isBusy ? .secondary : .primary)
                if let subtitle {
                    Text(subtitle)
                        .font(Typography.status)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !robot.isBusy {
                Image(systemName: "chevron.forward")
                    // Optical: a disclosure chevron, weighted to match the system's own.
                    // swiftlint:disable:next raw_font
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .combine)
    }
}

private extension RemoteRobotRow {
    /// Naming what holds the robot is the difference between "busy" and
    /// "broken" — the user can go and close that app.
    var subtitle: String? {
        if robot.isBusy {
            return robot.activeApp
                .map { String(localized: .reachy("In use by \($0)")) } ?? String(localized: .reachy("In use"))
        }
        return switch robot.transport {
        case .usb: String(localized: .reachy("Online · wired"))
        case .wifi, .unknown, .none: String(localized: .reachy("Online"))
        }
    }
}
