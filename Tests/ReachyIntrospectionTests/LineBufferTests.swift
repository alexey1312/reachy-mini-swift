import Foundation
@testable import ReachyIntrospection
import Testing

@Suite("Line buffer")
struct LineBufferTests {
    private func strings(_ lines: [Data]) -> [String] {
        lines.compactMap { String(bytes: $0, encoding: .utf8) }
    }

    @Test("a line cut across two reads arrives once, whole")
    func splitLine() {
        var buffer = LineBuffer()

        #expect(buffer.append(Data(#"{"cmd":"#.utf8)).isEmpty)
        #expect(strings(buffer.append(Data("\"ls\"}\n".utf8))) == [#"{"cmd":"ls"}"#])
    }

    @Test("two lines in one read arrive as two, and the tail waits for its newline")
    func mergedLines() {
        var buffer = LineBuffer()

        #expect(strings(buffer.append(Data("one\ntwo\nthr".utf8))) == ["one", "two"])
        #expect(strings(buffer.append(Data("ee\n".utf8))) == ["three"])
    }

    @Test("an empty line is skipped")
    func emptyLines() {
        var buffer = LineBuffer()

        #expect(strings(buffer.append(Data("\n\none\n\n".utf8))) == ["one"])
    }
}
