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

    @Test("a client with no app behind the port gets a reason, not a hang")
    func reportsNoListener() async throws {
        let server = IntrospectionServer(tree: tree(over: Counter()))
        let port = try await server.start()
        server.stop()

        await #expect(throws: IntrospectionClient.Failure.self) {
            _ = try await IntrospectionClient(port: port).send(IntrospectionRequest(cmd: .list))
        }
    }
}
