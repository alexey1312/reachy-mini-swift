import Foundation
@testable import ReachyIntrospection
import Testing

/// A two-level app: a shell that lends `selectTab`, over a gate or a detail screen.
@MainActor
private final class Fixture {
    var tab = "robot"
    var showsDetail = false
    var address = ""

    var tree: IntrospectionTree {
        IntrospectionTree { [self] in
            IntrospectionNode(
                name: "Shell",
                state: .object(["tab": .string(tab)]),
                actions: [IntrospectionAction("onlyOnShell") {}],
                lentActions: [
                    IntrospectionAction("selectTab", input: ["tab": .string]) { [self] input in
                        struct Input: Decodable {
                            let tab: String
                        }
                        tab = try input.decode(Input.self).tab
                    },
                ],
                child: { [self] in showsDetail ? detail : nil }
            )
        }
    }

    private var detail: IntrospectionNode {
        IntrospectionNode(
            name: "Detail",
            state: .object(["address": .string(address)]),
            actions: [
                IntrospectionAction("close") { [self] in showsDetail = false },
                IntrospectionAction("setAddress", input: ["text": .string]) { [self] input in
                    address = input["text"].flatMap {
                        if case let .string(text) = $0 {
                            text
                        } else {
                            nil
                        }
                    } ?? ""
                },
            ]
        )
    }
}

@MainActor
@Suite("Introspection tree")
struct IntrospectionTreeTests {
    @Test("the focused node is the deepest one, and the path names every node above it")
    func focusesTheLeaf() {
        let fixture = Fixture()
        #expect(fixture.tree.snapshot().path == ["Shell"])

        fixture.showsDetail = true
        fixture.address = "10.0.0.2"
        let snapshot = fixture.tree.snapshot()

        #expect(snapshot.path == ["Shell", "Detail"])
        #expect(snapshot.state == .object(["address": .string("10.0.0.2")]))
    }

    @Test("an action runs against the models, and the answer is the tree after it")
    func performs() async throws {
        let fixture = Fixture()
        fixture.showsDetail = true

        let after = try await fixture.tree.perform("setAddress", input: .object(["text": .string("127.0.0.1")]))
        #expect(fixture.address == "127.0.0.1")
        #expect(after.state == .object(["address": .string("127.0.0.1")]))

        let closed = try await fixture.tree.perform("close")
        #expect(closed.path == ["Shell"])
    }

    /// The rule that makes a run mean something: an agent cannot press a button
    /// that is under a sheet.
    @Test("an ancestor's own action is refused while a descendant is focused")
    func refusesWhatIsCovered() async {
        let fixture = Fixture()
        fixture.showsDetail = true

        await #expect(throws: IntrospectionError.unknownAction(
            "onlyOnShell",
            available: ["close", "setAddress", "selectTab"]
        )) {
            try await fixture.tree.perform("onlyOnShell")
        }
    }

    @Test("an ancestor lends an action to the focused node")
    func lends() async throws {
        let fixture = Fixture()
        fixture.showsDetail = true
        #expect(fixture.tree.snapshot().actions.map(\.name) == ["close", "setAddress", "selectTab"])

        _ = try await fixture.tree.perform("selectTab", input: .object(["tab": .string("apps")]))

        #expect(fixture.tab == "apps")
    }

    @Test("the snapshot names the input of an action that takes one, and omits it otherwise")
    func describesInput() {
        let fixture = Fixture()
        fixture.showsDetail = true

        let actions = fixture.tree.snapshot().actions

        #expect(actions.first { $0.name == "setAddress" }?.input == ["text": .string])
        #expect(actions.first { $0.name == "close" }?.input == nil)
    }

    @Test("a refusal is an answer with the reason, and a broken line is one too")
    func answersRefusals() async {
        let tree = Fixture().tree

        let unknown = await tree.respond(to: IntrospectionRequest(id: 7, cmd: .perform, action: "nope"))
        #expect(unknown.ok == false)
        #expect(unknown.id == 7)
        #expect(unknown.error?.contains("'nope' is not on the focused node") == true)

        let missing = await tree.respond(to: IntrospectionRequest(cmd: .perform))
        #expect(missing.error == "invalid request: 'do' needs an 'action'")

        let broken = await tree.respond(toLine: Data("not json".utf8))
        #expect(String(bytes: broken, encoding: .utf8)?.contains(#""ok":false"#) == true)
    }
}
