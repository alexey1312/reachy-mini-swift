import ReachyDesign
import ReachySSH
import SwiftUI
import UniformTypeIdentifiers

/// The robot's own file system, over SFTP.
///
/// The one screen in this app that reaches the robot without the daemon, because
/// the daemon has no route for it: nothing in its 77 paths writes an arbitrary
/// file. That is also the whole of its remit — no motion, no media, no service
/// commands (project rule 2 and `ReachySSH/AGENTS.md`).
///
/// Editing is deliberately not here. A file goes to the device, an editor there
/// changes it, and it comes back over the same path — which is why the row menu
/// offers Replace as well as Download.
struct RobotFilesScreen: View {
    @State private var model: RobotFilesModel
    @State private var exported: RemoteFileDocument?
    @State private var exportName = ""
    @State private var isImporting = false
    /// Set when Replace was chosen on a row, so the import lands on that path
    /// instead of on a new name in the current directory.
    @State private var replacing: RemoteFile?
    @State private var newFolderName = ""
    @State private var isNamingFolder = false
    @State private var renaming: RemoteFile?
    @State private var renameDraft = ""
    @Environment(\.reachyPreviewMode) private var previewMode

    init(model: RobotFilesModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        content
            .navigationTitle(.reachy("Files"))
            .task {
                // A frozen preview must not open a socket.
                guard !previewMode else { return }
                await model.start()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .connecting:
            Color.clear
                .contentLoading(isPresented: true, title: .reachy("Connecting over SSH…"))
        case .needsPassword:
            SSHPasswordForm(
                username: $model.username,
                password: $model.password,
                error: model.lastError
            ) { Task { await model.connect() } }
        case let .confirmHostKey(fingerprint):
            HostKeyConfirmation(situation: .firstContact(fingerprint)) {
                Task { await model.trustOfferedKey() }
            }
        case let .hostKeyChanged(pinned, offered):
            HostKeyConfirmation(situation: .changed(pinned: pinned, offered: offered)) {
                Task { await model.trustOfferedKey() }
            }
        case let .failed(reason):
            ContentUnavailableView {
                Label(.reachy("Cannot reach the robot's files"), systemImage: "folder.badge.questionmark")
            } description: {
                Text(reason)
            } actions: {
                Button(.reachy("Try again")) { Task { await model.connect() } }
            }
        case .browsing:
            listing
        }
    }

    // MARK: - Browsing

    private var listing: some View {
        List {
            if let error = model.lastError {
                Section {
                    Text(error)
                        .font(Typography.detail)
                        .foregroundStyle(Tone.danger.style)
                }
            }
            placesSection
            Section {
                ForEach(model.entries) { file in
                    row(for: file)
                }
            } header: {
                Text(model.path)
                    .font(Typography.consoleLine)
                    .textCase(nil)
            }
        }
        .overlay {
            if model.hasListed, model.entries.isEmpty, model.lastError == nil {
                ContentUnavailableView {
                    Label(.reachy("Nothing here"), systemImage: "folder")
                } description: {
                    Text(.reachy("This folder is empty."))
                }
            }
        }
        .contentLoading(isPresented: !model.hasListed, title: .reachy("Reading the folder…"))
        .refreshable { await model.refresh() }
        .reachyRefreshToolbar { await model.refresh() }
        .toolbar { toolbarContent }
        .modifier(FileTransferModifier(
            model: model,
            exported: $exported,
            exportName: $exportName,
            isImporting: $isImporting,
            replacing: $replacing
        ))
        .alert(.reachy("New folder"), isPresented: $isNamingFolder) {
            TextField(.reachy("Name"), text: $newFolderName)
            Button(.reachy("Cancel"), role: .cancel) { newFolderName = "" }
            Button(.reachy("Create")) {
                let name = newFolderName
                newFolderName = ""
                Task { await model.makeDirectory(named: name) }
            }
        }
        .alert(.reachy("Rename"), isPresented: renameBinding) {
            TextField(.reachy("Name"), text: $renameDraft)
            Button(.reachy("Cancel"), role: .cancel) { renaming = nil }
            Button(.reachy("Rename")) {
                if let file = renaming {
                    let name = renameDraft
                    Task { await model.rename(file, to: name) }
                }
                renaming = nil
            }
        }
        .confirmationDialog(
            .reachy("Delete from the robot?"),
            isPresented: confirmingBinding,
            titleVisibility: .visible
        ) {
            if case let .delete(file) = model.confirming {
                Button(.reachy("Delete"), role: .destructive) {
                    model.confirming = nil
                    Task { await model.delete(file) }
                }
            }
            Button(.reachy("Cancel"), role: .cancel) { model.confirming = nil }
        } message: {
            Text(.reachy("This cannot be undone from here. Download a copy first if you might need it."))
        }
    }

    /// Shortcuts, not a jail: the root stays reachable. The middle one is the
    /// directory a broken app's instance data lives in, which is why this screen
    /// exists at all.
    private var placesSection: some View {
        Section {
            ForEach(places) { place in
                Button {
                    Task { await model.go(to: place.path) }
                } label: {
                    Label(place.title, systemImage: place.symbol)
                }
                .disabled(model.path == place.path)
            }
        } header: {
            Text(.reachy("Places"))
        }
    }

    private var places: [Place] {
        [
            Place(title: .reachy("Root"), symbol: "externaldrive", path: "/"),
            Place(title: .reachy("Installed apps"), symbol: "shippingbox", path: RobotFilesModel.appsSitePackages),
            Place(title: .reachy("Home"), symbol: "house", path: RobotFilesModel.home),
        ]
    }

    /// A named type rather than a tuple: three members trip SwiftLint's
    /// `large_tuple`, and a shortcut is worth a name anyway.
    private struct Place: Identifiable {
        let title: LocalizedStringResource
        let symbol: String
        let path: String

        var id: String {
            path
        }
    }

    @ViewBuilder
    private func row(for file: RemoteFile) -> some View {
        if file.isDirectory {
            Button {
                Task { await model.open(file) }
            } label: {
                RemoteFileRow(file: file)
            }
            .buttonStyle(.plain)
            .contextMenu { menu(for: file) }
        } else {
            RemoteFileRow(file: file)
                .contextMenu { menu(for: file) }
        }
    }

    @ViewBuilder
    private func menu(for file: RemoteFile) -> some View {
        if !file.isDirectory {
            Button {
                Task {
                    guard let data = await model.contents(of: file) else { return }
                    exportName = file.name
                    exported = RemoteFileDocument(data: data)
                }
            } label: {
                Label(.reachy("Download"), systemImage: "arrow.down.circle")
            }
            Button {
                replacing = file
                isImporting = true
            } label: {
                Label(.reachy("Replace…"), systemImage: "arrow.up.circle")
            }
        }
        Button {
            renameDraft = file.name
            renaming = file
        } label: {
            Label(.reachy("Rename"), systemImage: "pencil")
        }
        Button(role: .destructive) {
            model.confirming = .delete(file)
        } label: {
            Label(.reachy("Delete"), systemImage: "trash")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    replacing = nil
                    isImporting = true
                } label: {
                    Label(.reachy("Upload a file…"), systemImage: "arrow.up.doc")
                }
                Button {
                    isNamingFolder = true
                } label: {
                    Label(.reachy("New folder"), systemImage: "folder.badge.plus")
                }
                Divider()
                Button {
                    Task { await model.disconnect() }
                } label: {
                    Label(.reachy("Disconnect"), systemImage: "xmark.circle")
                }
            } label: {
                Label(.reachy("Actions"), systemImage: "ellipsis.circle")
            }
            .help(Text(.reachy("Actions")))
        }
        if model.canGoUp {
            ToolbarItem(placement: .navigation) {
                Button {
                    Task { await model.goUp() }
                } label: {
                    Label(.reachy("Enclosing folder"), systemImage: "chevron.up")
                }
            }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: {
            if !$0 {
                renaming = nil
            }
        })
    }

    private var confirmingBinding: Binding<Bool> {
        Binding(get: { model.confirming != nil }, set: {
            if !$0 {
                model.confirming = nil
            }
        })
    }
}

/// The two document-picker flows, lifted out of the list so its body stays one
/// screenful.
private struct FileTransferModifier: ViewModifier {
    let model: RobotFilesModel
    @Binding var exported: RemoteFileDocument?
    @Binding var exportName: String
    @Binding var isImporting: Bool
    @Binding var replacing: RemoteFile?

    func body(content: Content) -> some View {
        content
            .fileExporter(
                isPresented: Binding(get: { exported != nil }, set: {
                    if !$0 {
                        exported = nil
                    }
                }),
                document: exported,
                contentType: .data,
                defaultFilename: exportName
            ) { _ in
                exported = nil
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data]) { result in
                guard case let .success(url) = result else {
                    replacing = nil
                    return
                }
                // The destination is the replaced file's own path, or the picked
                // name inside the current directory.
                let destination = replacing?.path ?? model.destination(forFileNamed: url.lastPathComponent)
                replacing = nil
                // The model reads the file off the main actor and reports a refusal
                // through the same slot every other failure uses.
                Task { await model.upload(from: url, to: destination) }
            }
            .contentLoading(
                isPresented: model.transferring != nil,
                title: .reachy("Transferring…")
            )
    }
}

/// Carries the bytes a download produced to the system export panel.
struct RemoteFileDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.data]
    }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
