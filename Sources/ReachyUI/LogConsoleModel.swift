import Foundation
import Observation
import ReachyDesign

@MainActor
@Observable
final class LogConsoleModel {
    static let capacities = [1000, 5000, 20000]

    private(set) var entries: [LogEntry] = []
    private(set) var visible: [LogEntry] = []
    private(set) var pending: [LogEntry] = []

    /// Pause freezes the display, never the stream — dropping lines here would punch a
    /// hole in the exported log exactly when the user is watching a failure.
    var paused = false {
        didSet {
            if !paused {
                flush()
            }
        }
    }

    var capacity = 5000 {
        didSet {
            trim()
            recompute()
        }
    }

    var query = "" {
        didSet { recompute() }
    }

    var minimumLevel = LogLevel.debug {
        didSet { recompute() }
    }

    private var nextID = 0

    var isFiltered: Bool {
        !query.isEmpty || minimumLevel != .debug
    }

    var copyText: String {
        visible.map(\.text).joined(separator: "\n")
    }

    var filterSummary: String? {
        guard isFiltered else { return nil }
        var parts = ["level: \(minimumLevel)"]
        if !query.isEmpty {
            parts.append("search: \"\(query)\"")
        }
        return parts.joined(separator: ", ")
    }

    func ingest(_ chunk: String) {
        let appended = chunk.split(separator: "\n", omittingEmptySubsequences: true).map { raw in
            defer { nextID += 1 }
            return LogEntry(id: nextID, raw: String(raw))
        }
        guard !appended.isEmpty else { return }
        if paused {
            pending.append(contentsOf: appended)
            return
        }
        entries.append(contentsOf: appended)
        trim()
        visible.append(contentsOf: appended.filter(matches))
        trimVisible()
    }

    /// Clearing empties a buffer nothing refills: the journal stays on the robot,
    /// but the lines this console has already scrolled past do not come back.
    var clearConfirmation: Confirmation {
        Confirmation(
            title: .reachy("Clear the log?"),
            message: .reachy("\(entries.count) lines go. The robot keeps its own journal."),
            confirm: .reachy("Clear")
        )
    }

    func clear() {
        entries = []
        visible = []
        pending = []
    }

    func export(address: String) -> LogExport {
        LogExport(entries: visible, address: address, totalCount: entries.count, filterSummary: filterSummary)
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        entries.append(contentsOf: pending)
        visible.append(contentsOf: pending.filter(matches))
        pending = []
        trim()
        trimVisible()
    }

    private func trim() {
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// `visible` is a maintained cache, so it must drop the same head `entries` dropped.
    private func trimVisible() {
        guard let oldest = entries.first?.id else {
            visible = []
            return
        }
        let drop = visible.prefix { $0.id < oldest }.count
        if drop > 0 {
            visible.removeFirst(drop)
        }
    }

    private func matches(_ entry: LogEntry) -> Bool {
        entry.level >= minimumLevel && (query.isEmpty || entry.text.localizedCaseInsensitiveContains(query))
    }

    private func recompute() {
        visible = entries.filter(matches)
    }
}

#if DEBUG
    extension LogConsoleModel {
        /// Pre-filled console. Lives here rather than in `Previews/` because `ingest` is the only
        /// public way in and `nextID` is private to this file.
        static func preview(
            lines: [String] = LogConsoleModel.previewLines,
            paused: Bool = false,
            pendingLines: [String] = [],
            query: String = "",
            minimumLevel: LogLevel = .debug
        ) -> LogConsoleModel {
            let model = LogConsoleModel()
            model.ingest(lines.joined(separator: "\n"))
            model.minimumLevel = minimumLevel
            model.query = query
            if paused {
                model.paused = true
                if !pendingLines.isEmpty {
                    model.ingest(pendingLines.joined(separator: "\n"))
                }
            }
            return model
        }

        static let previewLines = [
            "2026-08-04T09:12:01 DEBUG reachy_mini.daemon: state stream client connected",
            "2026-08-04T09:12:01 INFO reachy_mini.daemon: backend ready in 2.41 s",
            "2026-08-04T09:12:03 INFO reachy_mini.motors: motor mode set to enabled",
            "2026-08-04T09:12:04 INFO reachy_mini.moves: playing dance 'hello'",
            "2026-08-04T09:12:07 WARNING reachy_mini.audio: speaker level clamped to 100",
            "2026-08-04T09:12:09 ERROR reachy_mini.camera: webrtcsink lost its producer",
            "2026-08-04T09:12:10 INFO reachy_mini.camera: renegotiating",
        ]
    }
#endif
