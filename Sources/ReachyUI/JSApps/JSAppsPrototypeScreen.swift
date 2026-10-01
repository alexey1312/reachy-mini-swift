import ReachyDesign
import ReachyKit
import SwiftUI

// The #159 prototype, which ships to nobody (ADR 0006).
#if DEBUG
    /// The #159 prototype's way in: Settings → Advanced → Web apps, `DEBUG` only.
    ///
    /// It is a measuring instrument rather than a store, and it is laid out as one.
    /// Each section answers one of ADR 0006's open questions on a real robot — whether
    /// a narrow token is enough for central, whether this robot is reachable that way,
    /// and what each app asks for — before an app is opened at all. The store a user
    /// would see is designed after those answers, not before.
    ///
    /// No previews and no references, deliberately: it ships to nobody (rule 8's
    /// exception, said here as the rule asks).
    struct JSAppsPrototypeScreen: View {
        let session: RobotSession
        @State private var model = JSAppsPrototypeModel()
        @Environment(\.reachyOpenJSApp) private var openJSApp
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            Form {
                accessSection
                robotSection
                appsSection
            }
            .formStyle(.grouped)
            .navigationTitle(.reachy("Web apps"))
            .task {
                await model.loadCatalogue()
            }
        }

        private var hardwareID: String? {
            session.connectedIdentity?.hardwareID
        }

        private var accessSection: some View {
            Section {
                if model.isAuthorized {
                    LabeledContent(.reachy("Signed in as"), value: model.webAccount.username ?? "")
                } else {
                    Button(.reachy("Authorize web apps")) {
                        Task { await model.authorize(hardwareID: hardwareID) }
                    }
                    .disabled(model.isAuthorizing)
                }
                if let error = model.authorizationError {
                    Text(verbatim: error)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(.reachy("Access"))
            } footer: {
                Text(
                    .reachy(
                        // swiftlint:disable:next line_length
                        "A second Hugging Face sign-in for openid and profile only, held in memory. Web apps get this token, never the account's own."
                    )
                )
            }
        }

        private var robotSection: some View {
            Section {
                switch model.robot {
                case .unknown:
                    Text(.reachy("Authorize first."))
                        .foregroundStyle(.secondary)
                case .resolving:
                    ProgressView()
                case let .found(robot):
                    LabeledContent(.reachy("Robot"), value: robot.displayName)
                    LabeledContent(.reachy("Peer"), value: robot.peerID)
                    if robot.isBusy {
                        LabeledContent(.reachy("Held by"), value: robot.activeApp ?? "")
                    }
                case let .notListed(count):
                    Text(.reachy("Central listed \(count) robots for this account, and not this one."))
                case let .failed(reason):
                    Text(verbatim: reason)
                        .foregroundStyle(.secondary)
                }
                if model.isAuthorized {
                    Button(.reachy("Ask central again")) {
                        Task { await model.resolveRobot(hardwareID: hardwareID) }
                    }
                }
            } header: {
                Text(.reachy("Through central"))
            } footer: {
                Text(
                    .reachy(
                        // swiftlint:disable:next line_length
                        "Over the relay this app's own session is ended while a web app runs, and dialled again afterwards."
                    )
                )
            }
        }

        private var appsSection: some View {
            Section {
                if model.isLoadingCatalogue, model.apps.isEmpty {
                    ProgressView()
                }
                if let error = model.catalogueError {
                    Text(verbatim: error)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.apps) { app in
                    Button {
                        open(app)
                    } label: {
                        row(for: app)
                    }
                    .disabled(openJSApp == nil)
                }
            } header: {
                Text(.reachy("Catalogue"))
            }
        }

        private func row(for app: JSApp) -> some View {
            VStack(alignment: .leading) {
                Text(verbatim: [app.emoji, app.title].compactMap(\.self).joined(separator: " "))
                Text(verbatim: details(for: app))
                    .font(Typography.detail)
                    .foregroundStyle(.secondary)
            }
        }

        /// Runtime facts about the Space, for a developer reading the screen.
        private func details(for app: JSApp) -> String {
            let sdk = switch app.sdk {
            case .static: "static"
            case let .server(name): name
            }
            var parts = [app.id, sdk]
            if !app.declaredScopes.isEmpty {
                parts.append("scopes: " + app.declaredScopes.joined(separator: " "))
            }
            return parts.joined(separator: " · ")
        }

        private func open(_ app: JSApp) {
            Task {
                guard let url = await model.embedURL(for: app, theme: colorScheme == .dark ? .dark : .light)
                else { return }
                openJSApp?(app, url: url)
            }
        }
    }
#endif
