import Foundation
@testable import ReachyKit
import Testing

/// The sentences a failed connection is reported with. `URLError`'s own say
/// "Could not connect to the server", which names nothing the reader can check.
@Suite("Robot session errors")
struct RobotSessionErrorsTests {
    @Test("a refused connection names the host and what to check")
    func refusedConnectionNamesTheHost() throws {
        let url = try #require(URL(string: "http://10.0.0.7:8000/api/daemon/status"))
        let error = URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: url])
        let sentence = RobotSession.describe(error)
        #expect(sentence.contains("10.0.0.7"))
        #expect(sentence.contains("on this network"))
    }

    @Test("a lost link says so, naming the robot when there is no host")
    func lostLinkWithoutHost() {
        #expect(RobotSession.describe(URLError(.networkConnectionLost)) == "The connection to the robot dropped.")
    }

    @Test("a code without a sentence of its own falls back to the system's")
    func unknownCodeFallsBack() {
        #expect(RobotSession.sentence(for: URLError(.badServerResponse)) == nil)
        #expect(RobotSession.describe(URLError(.badServerResponse)) == URLError(.badServerResponse)
            .localizedDescription)
    }

    @Test("the generated client's wrapper is unwrapped before the sentence is chosen")
    func clientErrorIsUnwrapped() throws {
        let url = try #require(URL(string: "http://reachy-mini.local:8000/api/daemon/status"))
        let error = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url])
        #expect(RobotSession.describe(error).hasPrefix("reachy-mini.local took too long"))
    }
}
