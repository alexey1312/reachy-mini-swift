#if DEBUG
    import Foundation
    import Synchronization

    /// A file system double for previews, snapshots and the model's tests.
    ///
    /// In this module rather than in `ReachyTestSupport` for the reason
    /// `PreviewRobotClient` is in `ReachyKit`: a stub that answers a module's own
    /// protocol belongs beside it, and putting it in the shared test target would
    /// make every other test target link SwiftNIO.
    ///
    /// A `final class` with a `Mutex` rather than an actor: a preview needs its
    /// answers to be readable without an `await`, and the tests assert on what was
    /// asked as well as on what came back.
    public final class PreviewFileSystem: RobotFileSystem, Sendable {
        private struct State {
            var tree: [String: [RemoteFile]]
            var contents: [String: Data]
            var calls: [String] = []
            var isConnected = false
        }

        private let state: Mutex<State>
        /// Thrown by whichever call names it, so a preview can sit in a failure
        /// without a robot refusing anything.
        private let failure: ReachySSHError?

        public init(
            tree: [String: [RemoteFile]] = [:],
            contents: [String: Data] = [:],
            failure: ReachySSHError? = nil
        ) {
            state = Mutex(State(tree: tree, contents: contents))
            self.failure = failure
        }

        /// What was called, in order — the assertion a "did it even ask?" test needs.
        public var calls: [String] {
            state.withLock { $0.calls }
        }

        public var isConnected: Bool {
            state.withLock { $0.isConnected }
        }

        /// The same listing ``list(_:)`` would return, without the `await`.
        ///
        /// A preview has to be final on its first frame — Prefire captures
        /// synchronously and never lets a `.task` complete — so a frozen model needs
        /// its rows at construction time, not one suspension later.
        public func entries(at path: String) -> [RemoteFile] {
            state.withLock { $0.tree[path] } ?? []
        }

        public func connect(_: SSHCredentials) async throws {
            try record("connect")
            state.withLock { $0.isConnected = true }
        }

        public func disconnect() async {
            state.withLock { $0.calls.append("disconnect"); $0.isConnected = false }
        }

        public func list(_ path: String) async throws -> [RemoteFile] {
            try record("list(\(path))")
            return state.withLock { $0.tree[path] } ?? []
        }

        public func read(_ path: String, limit: Int) async throws -> Data {
            try record("read(\(path))")
            let data = state.withLock { $0.contents[path] } ?? Data()
            guard data.count <= limit else {
                throw ReachySSHError.fileTooLarge(bytes: UInt64(data.count), limit: limit)
            }
            return data
        }

        /// Answers out of the same `contents` map as ``read(_:limit:)``, so a
        /// fixture spells a `/proc` entry exactly the way it spells any other file.
        /// A path with nothing behind it throws rather than returning an empty
        /// string: that is what a robot without the file does, and the reader's
        /// tolerance of a missing thermal zone has to be exercised somehow.
        public func readPseudoFile(_ path: String) async throws -> String {
            try record("readPseudoFile(\(path))")
            guard let data = state.withLock({ $0.contents[path] }) else {
                throw ReachySSHError.pathNotFound(path)
            }
            // Failable rather than `String(decoding:as:)`, which would turn a binary
            // fixture into replacement characters and let a test assert on them.
            guard let text = String(bytes: data, encoding: .utf8) else {
                throw ReachySSHError.transport("\(path) is not text")
            }
            return text
        }

        public func write(_ data: Data, to path: String) async throws {
            try record("write(\(path))")
            state.withLock { $0.contents[path] = data }
        }

        public func makeDirectory(at path: String) async throws {
            try record("makeDirectory(\(path))")
            state.withLock {
                $0.tree[path] = []
                if let parent = RemoteFile.parent(of: path) {
                    let name = String(path.split(separator: "/").last ?? "")
                    $0.tree[parent, default: []].append(
                        RemoteFile(name: name, path: path, kind: .directory, mode: 0o040755)
                    )
                }
            }
        }

        public func remove(_ file: RemoteFile) async throws {
            try record("remove(\(file.path))")
            state.withLock {
                $0.contents[file.path] = nil
                if let parent = RemoteFile.parent(of: file.path) {
                    $0.tree[parent]?.removeAll { $0.path == file.path }
                }
            }
        }

        public func rename(_ path: String, to newPath: String) async throws {
            try record("rename(\(path),\(newPath))")
        }

        private func record(_ call: String) throws {
            state.withLock { $0.calls.append(call) }
            if let failure {
                throw failure
            }
        }
    }

    public extension PreviewFileSystem {
        /// The directory the incident happened in, which is the one worth having a
        /// fixture for.
        static var appPackage: String {
            "/venvs/apps_venv/lib/python3.12/site-packages/reachy_mini_conversation_app"
        }

        /// A fixed instant, so a reference image never moves because a day passed.
        static var previewStamp: Date {
            Date(timeIntervalSince1970: 1_770_000_000)
        }

        static func previewFile(_ name: String, in directory: String, size: UInt64, mode: UInt32 = 0o100644)
            -> RemoteFile
        {
            RemoteFile(
                name: name,
                path: RemoteFile.joining(directory, name),
                kind: .file,
                size: size,
                modified: previewStamp,
                mode: mode
            )
        }

        static func previewDirectory(_ name: String, in directory: String) -> RemoteFile {
            RemoteFile(
                name: name,
                path: RemoteFile.joining(directory, name),
                kind: .directory,
                modified: previewStamp,
                mode: 0o040755
            )
        }

        /// A settled tree: the package directory with a broken personality in it —
        /// `Test_Ru` in the old four-file format, with no `profile.md`. That is the
        /// state the whole feature exists for; keep it broken.
        static func brokenPersonality() -> PreviewFileSystem {
            let personalities = RemoteFile.joining(appPackage, "user_personalities")
            let profile = RemoteFile.joining(personalities, "Test_Ru")
            let settings = RemoteFile.joining(appPackage, "startup_settings.json")
            return PreviewFileSystem(
                tree: [
                    appPackage: [
                        previewDirectory("user_personalities", in: appPackage),
                        previewFile(".env", in: appPackage, size: 148, mode: 0o100600),
                        previewFile("main.py", in: appPackage, size: 9421),
                        previewFile("startup_settings.json", in: appPackage, size: 64),
                    ],
                    personalities: [previewDirectory("Test_Ru", in: personalities)],
                    profile: [
                        previewFile("greeting.txt", in: profile, size: 82),
                        previewFile("instructions.txt", in: profile, size: 1204),
                        previewFile("tools.txt", in: profile, size: 37),
                        previewFile("voice.txt", in: profile, size: 12),
                    ],
                ],
                contents: [settings: Data(#"{"profile": "user_personalities/Test_Ru"}"#.utf8)]
            )
        }
    }
#endif
