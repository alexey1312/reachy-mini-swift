import Foundation

/// One thing a user can do on a screen.
@MainActor
public struct IntrospectionAction {
    /// The type of one input member. The client shows it; nothing validates against it.
    public enum Kind: String, Codable, Sendable {
        case string
        case number
        case bool
    }

    public let name: String
    /// The members of the JSON object this action reads. Empty for an action with no input.
    public let input: [String: Kind]
    let run: @MainActor (JSONValue) async throws -> Void

    public init(_ name: String, run: @escaping @MainActor () async throws -> Void) {
        self.name = name
        input = [:]
        self.run = { _ in try await run() }
    }

    public init(
        _ name: String,
        input: [String: Kind],
        run: @escaping @MainActor (JSONValue) async throws -> Void
    ) {
        self.name = name
        self.input = input
        self.run = run
    }
}

/// What one screen shows and offers, as an agent reads it.
///
/// Three rules keep a node honest. If a user can see it, it is in `state`. If a
/// user can do it, it is in `actions`. An action calls the method the view calls,
/// and the node holds no logic of its own.
@MainActor
public struct IntrospectionNode {
    public let name: String
    public let state: JSONValue
    /// Available while this node is the focused one.
    public let actions: [IntrospectionAction]
    /// Available while a descendant is focused: a tab bar stays in reach on every tab.
    public let lentActions: [IntrospectionAction]
    /// The node this one presents. The deepest node of the chain is the focused one.
    let child: @MainActor () -> IntrospectionNode?

    public init(
        name: String,
        state: JSONValue = .null,
        actions: [IntrospectionAction] = [],
        lentActions: [IntrospectionAction] = [],
        child: @escaping @MainActor () -> IntrospectionNode? = { nil }
    ) {
        self.name = name
        self.state = state
        self.actions = actions
        self.lentActions = lentActions
        self.child = child
    }
}

/// The focused node as a value: what `ls` prints.
public struct IntrospectionSnapshot: Codable, Equatable, Sendable {
    public struct Action: Codable, Equatable, Sendable {
        public let name: String
        public let input: [String: IntrospectionAction.Kind]?
    }

    /// Node names from the root to the focused node.
    public let path: [String]
    public let state: JSONValue
    public let actions: [Action]
}

public enum IntrospectionError: Error, Equatable, CustomStringConvertible {
    case unknownAction(String, available: [String])
    case invalidRequest(String)

    public var description: String {
        switch self {
        case let .unknownAction(name, available):
            "action '\(name)' is not on the focused node; available: \(available.joined(separator: ", "))"
        case let .invalidRequest(reason):
            "invalid request: \(reason)"
        }
    }
}
