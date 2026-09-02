import HuggingFaceAuth
import ReachyDesign
import ReachyKit
import SwiftUI

/// The Hugging Face account this app holds, and whether this robot shares it.
///
/// Two custody points, and the card keeps them visibly apart: signing in here
/// gets the private half of the app store and the robot list; *linking* hands the
/// robot its own copy of the token, which is what puts it on the relay. Signing
/// out does not unlink — a robot left reachable with a token the user believes
/// they revoked is the one outcome worth going out of the way to prevent.
struct HFAccountSection: View {
    let session: RobotSession

    @State private var model: HFSignInModel
    @State private var robotLink: RobotHFLinkModel
    /// Which control is on screen, and nothing about either account: the disclosure
    /// and the dialog are the card's own business.
    @State private var showsTokenField = false
    @State private var confirmingUnlink = false
    @State private var confirmingSignOut = false
    @Environment(\.reachyPreviewMode) private var previewMode

    /// `@MainActor` because `RobotHFLinkModel` is: a defaulted argument whose value
    /// is main-actor-isolated compiles in the SwiftPM targets and not in the `Apps/`
    /// ones, where it is evaluated nonisolated.
    @MainActor
    init(session: RobotSession, model: HFSignInModel, robotLink: RobotHFLinkModel? = nil) {
        self.session = session
        _model = State(initialValue: model)
        _robotLink = State(initialValue: robotLink ?? RobotHFLinkModel())
    }

    var body: some View {
        Section {
            accountRow
            if model.isBusy {
                ProgressView()
            }
            if let errorText = model.errorText {
                Text(errorText)
                    .font(Typography.status)
                    .foregroundStyle(Tone.danger.style)
            }
            signInControls
        } header: {
            Text(.reachy("Hugging Face"))
        } footer: {
            Text(footerText)
        }
        .confirmationDialog(
            HFSignInModel.signOutConfirmation.title,
            isPresented: $confirmingSignOut,
            titleVisibility: .visible
        ) {
            Button(HFSignInModel.signOutConfirmation.confirm, role: .destructive) { model.signOut() }
        } message: {
            Text(HFSignInModel.signOutConfirmation.message)
        }
        // On the card's first section rather than on either robot section, so it is
        // in the hierarchy whichever of the two is shown.
        .confirmationDialog(
            .reachy("Take the robot off the relay?"),
            isPresented: $confirmingUnlink,
            titleVisibility: .visible
        ) {
            Button(.reachy("Unlink this robot"), role: .destructive) {
                Task { await robotLink.unlink(session: session) }
            }
        } message: {
            Text(
                .reachy(
                    // swiftlint:disable:next line_length
                    "The robot drops its token and leaves the relay. Nothing here can reach it again until it is set up in person."
                )
            )
        }

        if session.canLinkHuggingFace {
            robotSection
        } else if session.canUnlinkRobot {
            relayRobotSection
        }
    }

    // MARK: This robot, over the relay

    /// What a relayed session can honestly say about the robot's account: it holds
    /// a token, and that token can be taken away.
    ///
    /// "Linked" is an inference rather than a reading, and a sound one — this
    /// session arrived through central, which lists a robot only while it holds a
    /// token. Everything else on the full card needs routes the data channel does
    /// not carry, so none of it is shown rather than shown broken.
    ///
    /// Confirmed, and so is the same button on the local card now. The argument
    /// against asking there — the robot is in front of you and linking it again is
    /// the row above — held for the robot and not for the relay: one tap took a
    /// robot off every other device's list, and those readers were not in the room.
    private var relayRobotSection: some View {
        Section {
            LabeledContent(.reachy("This robot"), value: String(localized: .reachy("Linked")))
            if let linkError = robotLink.linkError {
                Text(linkError)
                    .font(Typography.status)
                    .foregroundStyle(Tone.danger.style)
            }
            Button(.reachy("Unlink this robot"), role: .destructive) {
                confirmingUnlink = true
            }
            .disabled(robotLink.isLinking)
        } header: {
            Text(.reachy("Robot account"))
        } footer: {
            Text(
                .reachy(
                    // swiftlint:disable:next line_length
                    "Unlinking takes the robot off the relay: it goes offline and comes back only once somebody sets it up again in person."
                )
            )
        }
    }

    // MARK: This app's account

    @ViewBuilder
    private var accountRow: some View {
        switch model.account.state {
        case .signedOut, .signingIn:
            Label(.reachy("Not signed in"), systemImage: "person.crop.circle")
        case let .signedIn(username):
            LabeledContent {
                Button(.reachy("Sign out"), role: .destructive) { confirmingSignOut = true }
                    .buttonStyle(.borderless)
            } label: {
                accountLabel(username: username, caption: String(localized: .reachy("Signed in")))
            }
        case let .needsReauth(username):
            accountLabel(
                username: username ?? String(localized: .reachy("Your account")),
                caption: String(localized: .reachy("Session expired"))
            )
        case let .failed(reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(Tone.warning.style)
        }
    }

    private func accountLabel(username: String, caption: String) -> some View {
        // Optical: the avatar sits closer to the name than a Space token allows.
        // swiftlint:disable:next raw_spacing
        HStack(spacing: 10) {
            HFAvatar(username: username)
            // Optical: 1 pt, the caption belongs to the name above it rather than reading as a second line.
            // swiftlint:disable:next raw_spacing
            VStack(alignment: .leading, spacing: 1) {
                Text(username)
                Text(caption)
                    .font(Typography.status)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var signInControls: some View {
        switch model.account.state {
        case .signedIn:
            EmptyView()
        default:
            if model.offersBrowserSignIn {
                Button {
                    Task { await model.signInWithBrowser() }
                } label: {
                    Label(.reachy("Sign in with Hugging Face"), systemImage: "person.badge.key")
                }
                .disabled(model.isBusy)
            }

            DisclosureGroup(String(localized: .reachy("Use an access token")), isExpanded: $showsTokenField) {
                SecureField(.reachy("hf_xxx…"), text: $model.pastedToken)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                Button(.reachy("Sign in with this token")) {
                    Task { await model.signInWithPastedToken() }
                }
                .disabled(model.pastedToken.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy)
            }
        }
    }

    private var footerText: String {
        if model.offersBrowserSignIn {
            String(
                localized: .reachy(
                    "Signing in shows your private Spaces in the app store and lists your robots for remote access."
                )
            )
        } else {
            // Honest about the state of the build rather than showing a button
            // that would open an error page on the Hub.
            String(
                localized: .reachy(
                    // swiftlint:disable:next line_length
                    "One-tap sign-in is not available in this build. Create an access token at huggingface.co/settings/tokens and paste it here."
                )
            )
        }
    }

    // MARK: This robot

    private var robotSection: some View {
        Section {
            LabeledContent(.reachy("This robot"), value: robotLink.accountText)
            if let relayCaption = robotLink.relayCaption {
                LabeledContent(.reachy("Remote access"), value: relayCaption)
            }
            if let linkError = robotLink.linkError {
                Text(linkError)
                    .font(Typography.status)
                    .foregroundStyle(Tone.danger.style)
            }
            if robotLink.isLinked {
                Button(.reachy("Unlink this robot"), role: .destructive) {
                    confirmingUnlink = true
                }
                .disabled(robotLink.isLinking)
            } else if case .signedIn = model.account.state {
                Button {
                    Task { await robotLink.link(session: session, token: model.account.currentToken()) }
                } label: {
                    if robotLink.isLinking {
                        ProgressView()
                    } else {
                        Label(.reachy("Link this robot"), systemImage: "link")
                    }
                }
                .disabled(robotLink.isLinking)
            }
        } header: {
            Text(.reachy("Robot account"))
        } footer: {
            // The LAN hop is plain HTTP and unauthenticated (ADR 0001). Saying so
            // is the honest alternative to implying a security this transport does
            // not have.
            Text(
                .reachy(
                    // swiftlint:disable:next line_length
                    "Linking copies your token to the robot over the local network, which is not encrypted. Do it on a network you trust."
                )
            )
        }
        .task {
            guard !previewMode else { return }
            await robotLink.load(session: session)
        }
    }
}
