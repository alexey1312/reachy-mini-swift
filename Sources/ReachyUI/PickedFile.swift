import Foundation

/// Reading a file the user picked out of a `fileImporter`, once.
///
/// Two screens do this — the robot's file browser and the soundboard — and each of the
/// three things that make it correct was learned rather than assumed:
///
/// - **`Task.detached`, not `Task`.** Created inside a `@MainActor` context a plain task
///   *inherits* that isolation, so `Data(contentsOf:)` would read the whole file on the
///   main thread.
/// - **The security scope, balanced by `defer` whichever way it leaves.** A picked URL is
///   security-scoped on iOS, and reading it outside the scope silently yields nothing —
///   no error, no bytes.
/// - **The size check before the read**, so a file too large to send is refused rather
///   than pulled into a phone's memory to find that out.
///
/// The limit's *meaning* belongs to the caller, which is why the error is one too:
/// `RobotFilesModel` is bounded by what SFTP will carry, the soundboard by what the
/// daemon accepts, and neither number nor sentence is the other's.
enum PickedFile {
    static func read(
        at url: URL,
        limit: Int,
        tooLarge: @escaping @Sendable (Int) -> any Error
    ) async throws -> Data {
        try await Task.detached {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= limit else {
                throw tooLarge(size)
            }
            return try Data(contentsOf: url)
        }.value
    }
}
