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
    @State private var robotAccount: HFAuthStatus?
    @State private var relay: RelayStatus?
    @State private var linkError: String?
    @State private var isLinking = false
    @State private var showsTokenField = false
    @State private var confirmingUnlink = false
    @Environment(\.reachyPreviewMode) private var previewMode

    init(
        session: RobotSession,
        model: HFSignInModel,
        robotAccount: HFAuthStatus? = nil,
        relay: RelayStatus? = nil,
        linkError: String? = nil
    ) {
        self.session = session
        _model = State(initialValue: model)
        _robotAccount = State(initialValue: robotAccount)
        _relay = State(initialValue: relay)
        _linkError = State(initialValue: linkError)
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
    /// Confirmed, unlike the same button on the local card. There the robot is on
    /// the network in front of you and linking it again is the row above; here the
    /// robot leaves the relay and only somebody standing next to it can undo that.
    private var relayRobotSection: some View {
        Section {
            LabeledContent(.reachy("This robot"), value: String(localized: .reachy("Linked")))
            if let linkError {
                Text(linkError)
                    .font(Typography.status)
                    .foregroundStyle(Tone.danger.style)
            }
            Button(.reachy("Unlink this robot"), role: .destructive) {
                confirmingUnlink = true
            }
            .disabled(isLinking)
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
        .confirmationDialog(
            .reachy("Take the robot off the relay?"),
            isPresented: $confirmingUnlink,
            titleVisibility: .visible
        ) {
            Button(.reachy("Unlink this robot"), role: .destructive) {
                Task { await unlink() }
            }
        } message: {
            Text(
                .reachy(
                    // swiftlint:disable:next line_length
                    "The robot drops its token and leaves the relay. Nothing here can reach it again until it is set up in person."
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
                Button(.reachy("Sign out"), role: .destructive) { model.signOut() }
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
        HStack(spacing: 10) {
            HFAvatar(username: username)
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
            LabeledContent(.reachy("This robot"), value: robotAccountText)
            if let relay {
                LabeledContent(.reachy("Remote access"), value: relayText(relay))
            }
            if let linkError {
                Text(linkError)
                    .font(Typography.status)
                    .foregroundStyle(Tone.danger.style)
            }
            if robotAccount?.isLoggedIn == true {
                Button(.reachy("Unlink this robot"), role: .destructive) {
                    Task { await unlink() }
                }
                .disabled(isLinking)
            } else if case .signedIn = model.account.state {
                Button {
                    Task { await link() }
                } label: {
                    if isLinking {
                        ProgressView()
                    } else {
                        Label(.reachy("Link this robot"), systemImage: "link")
                    }
                }
                .disabled(isLinking)
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
            await loadRobotState()
        }
    }

    private var robotAccountText: String {
        guard let robotAccount else { return "…" }
        if robotAccount.isLoggedIn {
            return robotAccount.username.map { String(localized: .reachy("Linked to \($0)")) }
                ?? String(localized: .reachy("Linked"))
        }
        return String(localized: .reachy("Not linked"))
    }

    private func relayText(_ relay: RelayStatus) -> String {
        switch relay.state {
        case .connected: String(localized: .reachy("Online"))
        case .connecting, .reconnecting: String(localized: .reachy("Connecting…"))
        case .waitingForToken: String(localized: .reachy("Waiting for a token"))
        case .stopped: String(localized: .reachy("Off"))
        case .unavailable: relay.message ?? String(localized: .reachy("Not available on this robot"))
        case .error: relay.message ?? String(localized: .reachy("Error"))
        // The daemon's own word for a state this app does not know — runtime
        // text, which is what keeps this slot a String (rule 9).
        case let .unknown(state): state
        }
    }

    private func loadRobotState() async {
        robotAccount = try? await session.robotHFAccount()
        relay = try? await session.relayStatus()
    }

    private func link() async {
        guard let token = await model.account.currentToken() else {
            linkError = String(localized: .reachy("This app has no valid token to share. Sign in again."))
            return
        }
        isLinking = true
        linkError = nil
        defer { isLinking = false }
        do {
            let refresh = try await session.linkRobot(token: token)
            robotAccount = try? await session.robotHFAccount(refresh: true)
            // `skipped` means no reconnect was started, so waiting for the relay to
            // change state would wait forever — the daemon's own docstring calls
            // that trap out by name.
            relay = refresh.didStart ? try? await session.relayStatus() : relay
        } catch {
            linkError.recordDaemonFailure(error)
        }
    }

    private func unlink() async {
        isLinking = true
        linkError = nil
        defer { isLinking = false }
        do {
            try await session.unlinkRobot()
            robotAccount = try? await session.robotHFAccount(refresh: true)
            relay = try? await session.relayStatus()
        } catch {
            linkError.recordDaemonFailure(error)
        }
    }
}
