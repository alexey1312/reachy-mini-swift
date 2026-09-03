import Foundation

/// Turns what is on screen into a windowed excerpt the on-device model can read.
///
/// Pure, synchronous and free of any actor, so the whole windowing policy is testable
/// without a model, a device, or Apple Intelligence being switched on — which is just
/// as well, because none of those is available to `mise run test`.
enum LogExcerpt {
    /// The fence the prompt wraps the corpus in. Declared here rather than in
    /// `LogExplanationPrompt` because this is what has to neutralise them: a log line
    /// containing the closing marker could otherwise end the data region early and
    /// have whatever followed it read as instructions.
    static let beginMarker = "BEGIN LOG EXCERPT"
    static let endMarker = "END LOG EXCERPT"

    struct Budget: Equatable, Sendable {
        /// Characters rather than tokens, and deliberately conservative. Log text
        /// tokenizes far worse than prose — ISO timestamps, dotted module paths, hex —
        /// so a per-token budget guessed from an English ratio would be wrong in the
        /// dangerous direction. Measuring it properly needs `tokenCount(for:)`, which
        /// is a 26.4 symbol and therefore out of reach of the job that compiles every
        /// SwiftPM target. `.exceededContextWindowSize` has its own sentence for the
        /// case where this is still too generous.
        var characters = 8000
        /// One uvicorn traceback line can be tens of kilobytes and would eat the whole
        /// budget on its own.
        var lineLimit = 400
        /// The share held back for problems older than the tail.
        var earlierProblemsShare = 0.25
        static let `default` = Budget()
    }

    /// What was sent, so the sheet can say it rather than imply it.
    struct Coverage: Equatable, Sendable {
        var includedLines = 0
        var totalLines = 0
        var omittedLines = 0
        var clampedLines = 0
    }

    struct Excerpt: Equatable, Sendable {
        var text = ""
        var coverage = Coverage()
    }

    /// **The tail is the spine.** A journal's ending is where the failure is, so the
    /// window is grown backwards from the newest line and only what is left over goes
    /// to older problems. Those are then reversed into chronological order — a model
    /// shown time running backwards will describe a sequence that never happened.
    static func build(from entries: [LogEntry], budget: Budget = .default) -> Excerpt {
        guard !entries.isEmpty else { return Excerpt() }
        // Windowing runs over lengths alone, and only the lines that survive it are
        // clamped and neutralised. The console holds up to 20 000 entries and this is
        // called on the main actor from a tap, so transforming the whole buffer to
        // keep ~200 lines of it was real work spent on the discarded 99%.
        let costs = entries.map { min($0.text.count, budget.lineLimit) + 1 }

        let tailBudget = Int(Double(budget.characters) * (1 - budget.earlierProblemsShare))
        let tailStart = firstIndex(fitting: tailBudget, in: costs)
        let spent = costs[tailStart...].reduce(0, +)
        let earlierIndices = earlierProblems(
            in: entries,
            costs: costs,
            before: tailStart,
            budget: max(0, budget.characters - spent)
        )

        var clamped = 0
        let render = { (index: Int) -> String in
            let safe = neutralise(entries[index].text)
            guard safe.count > budget.lineLimit else { return safe }
            clamped += 1
            return String(safe.prefix(budget.lineLimit)) + "…"
        }
        let earlier = earlierIndices.map(render)
        let tail = (tailStart ..< entries.count).map(render)

        let included = earlier.count + tail.count
        return Excerpt(
            text: compose(earlier: earlier, tail: tail, omitted: entries.count - included),
            coverage: Coverage(
                includedLines: included,
                totalLines: entries.count,
                omittedLines: entries.count - included,
                clampedLines: clamped
            )
        )
    }

    /// Walks back from the newest line while the running total fits. Always keeps at
    /// least one line: an excerpt of nothing says less than a truncated last line.
    private static func firstIndex(fitting budget: Int, in costs: [Int]) -> Int {
        var used = 0
        var index = costs.count
        while index > 0 {
            let cost = costs[index - 1]
            guard used + cost <= budget || index == costs.count else { break }
            used += cost
            index -= 1
        }
        return index
    }

    /// The most recent warnings and errors from *before* the tail, newest-first while
    /// the budget lasts, then flipped back into chronological order.
    ///
    /// Returns indices rather than text: the caller renders, so nothing outside the
    /// window is ever transformed.
    private static func earlierProblems(
        in entries: [LogEntry],
        costs: [Int],
        before tailStart: Int,
        budget: Int
    ) -> [Int] {
        guard tailStart > 0, budget > 0 else { return [] }
        var used = 0
        var picked: [Int] = []
        for index in (0 ..< tailStart).reversed() where entries[index].level >= .warning {
            guard used + costs[index] <= budget else { break }
            used += costs[index]
            picked.append(index)
        }
        return picked.reversed()
    }

    /// The gap is stated rather than left implicit, so the model does not read two
    /// lines an hour apart as adjacent.
    ///
    /// The wording depends on whether the earlier block is there, because the count is
    /// a total rather than the size of this one gap: with earlier problems carried, the
    /// dropped lines are scattered *between* them as well as before the tail, and a
    /// marker saying otherwise would be the one sentence in the excerpt asserting
    /// something untrue.
    private static func compose(earlier: [String], tail: [String], omitted: Int) -> String {
        var blocks = earlier
        if omitted > 0 {
            blocks.append(
                earlier.isEmpty
                    ? "… \(omitted) earlier lines omitted …"
                    : "… \(omitted) lines omitted, not all of them at this point …"
            )
        }
        blocks.append(contentsOf: tail)
        return blocks.joined(separator: "\n")
    }

    /// Rewrites the fence markers where a log line happens to contain one, rather than
    /// dropping the line: the line stays readable, the count stays honest, and the
    /// corpus cannot close its own fence.
    ///
    /// Only the two fence markers. The gap marker is *inside* the fence, so a forged
    /// one can mislead the model about ordering but cannot make anything read as an
    /// instruction — the fence is the security boundary and this is what defends it.
    static func neutralise(_ line: String) -> String {
        line
            .replacingOccurrences(of: beginMarker, with: beginMarker.replacingOccurrences(of: " ", with: "·"))
            .replacingOccurrences(of: endMarker, with: endMarker.replacingOccurrences(of: " ", with: "·"))
    }
}
