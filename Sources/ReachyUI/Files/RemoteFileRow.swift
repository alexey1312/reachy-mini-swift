import ReachyDesign
import ReachySSH
import SwiftUI

/// One entry in the robot's file listing.
struct RemoteFileRow: View {
    let file: RemoteFile

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: symbol)
                .foregroundStyle(file.isDirectory ? Tone.brand.style : Tone.quiet.style)
                .frame(width: Space.xl)
                .accessibilityLabel(kindLabel)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(file.name)
                    .font(Typography.rowTitleCompact)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail)
                        .font(Typography.status)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if file.isDirectory {
                // The mirroring glyph, not `chevron.right`: a right-to-left
                // language needs no second pass.
                Image(systemName: "chevron.forward")
                    .font(Typography.status)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// What the glyph means, for a reader who cannot see it. The kind was otherwise
    /// only in the icon, so a listing read aloud was names and sizes with no way to
    /// tell a folder from a file.
    private var kindLabel: LocalizedStringResource {
        switch file.kind {
        case .directory: .reachy("Folder")
        case .symlink: .reachy("Symbolic link")
        case .other: .reachy("Special file")
        case .file: .reachy("File")
        }
    }

    private var symbol: String {
        switch file.kind {
        case .directory: "folder"
        case .symlink: "arrow.turn.down.right"
        case .other: "questionmark.square.dashed"
        case .file: "doc"
        }
    }

    /// Size, permissions and date on one line, in that order, and each of them
    /// optional: SFTP is free to omit every one.
    private var detail: String? {
        var parts: [String] = []
        if !file.isDirectory, let size = file.size {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let permissions = RemoteFile.permissionsText(mode: file.mode, kind: file.kind) {
            parts.append(permissions)
        }
        if let modified = file.modified {
            parts.append(modified.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}
