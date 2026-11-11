import Foundation
@testable import ReachyIntrospection
import Testing

/// The one suite that opens a socket: everything else about the tree is tested in
/// process. What only a socket can show is the framing and the order of answers.
@MainActor
@Suite("Introspection server", .timeLimit(.minutes(1)))
struct IntrospectionServerTests {
    @MainActor
    private final class Counter {
        var value = 0
    }

    private func tree(over counter: Counter) -> IntrospectionTree {
        IntrospectionTree {
            IntrospectionNode(
                name: "Counter",
                state: .object(["value": .number(Double(counter.value))]),
                actions: [IntrospectionAction("increment") { counter.value += 1 }]
            )
        }
    }

    @Test("a client reads the tree and drives it over the loopback")
    func servesAClient() async throws {
        let counter = Counter()
        let server = IntrospectionServer(tree: tree(over: counter))
        let port = try await server.start()
        defer { server.stop() }
        let client = IntrospectionClient(port: port)

        let listed = try await client.send(IntrospectionRequest(id: 1, cmd: .list))
        #expect(listed.ok)
        #expect(listed.id == 1)
        #expect(listed.path == ["Counter"])
        #expect(listed.actions?.map(\.name) == ["increment"])

        let done = try await client.send(IntrospectionRequest(id: 2, cmd: .perform, action: "increment"))
        #expect(done.state == .object(["value": .number(1)]))
        #expect(counter.value == 1)

        let refused = try await client.send(IntrospectionRequest(id: 3, cmd: .perform, action: "reset"))
        #expect(refused.ok == false)
    }

    /// A stopped listener closes a moment after `stop()` returns, and it can still
    /// answer in that moment. So the test waits for the refusal (project rule 7).
    @Test("a client with no app behind the port gets a reason, not a hang")
    func reportsNoListener() async throws {
        let server = IntrospectionServer(tree: tree(over: Counter()))
        let port = try await server.start()
        server.stop()
        let client = IntrospectionClient(port: port)

        var failure: (any Error)?
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while failure == nil, ContinuousClock.now < deadline {
            do {
                _ = try await client.send(IntrospectionRequest(cmd: .list))
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                failure = error
            }
        }

        #expect(failure is IntrospectionClient.Failure)
    }
}
