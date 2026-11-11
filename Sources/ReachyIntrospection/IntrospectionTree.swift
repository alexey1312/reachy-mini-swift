#if DEBUG
    import Foundation

    /// The app as a chain of nodes, read from the root each time.
    ///
    /// Nothing is cached. A node is a view of the models at the moment of the call, so
    /// a state change needs no notification to reach the next `ls`.
    @MainActor
    public final class IntrospectionTree {
        private let root: @MainActor () -> IntrospectionNode

        public init(root: @escaping @MainActor () -> IntrospectionNode) {
            self.root = root
        }

        public func snapshot() -> IntrospectionSnapshot {
            let chain = chain()
            return IntrospectionSnapshot(
                path: chain.map(\.name),
                state: chain[chain.count - 1].state,
                actions: Self.reachable(in: chain).map { action in
                    .init(name: action.name, input: action.input.isEmpty ? nil : action.input)
                }
            )
        }

        /// Runs one action and returns the tree as it is after the action returns.
        ///
        /// An action that starts work returns before that work ends. The caller polls
        /// `snapshot()` for the state it expects.
        public func perform(_ name: String, input: JSONValue = .null) async throws -> IntrospectionSnapshot {
            let actions = Self.reachable(in: chain())
            guard let action = actions.first(where: { $0.name == name }) else {
                throw IntrospectionError.unknownAction(name, available: actions.map(\.name))
            }
            try await action.run(input)
            return snapshot()
        }

        private func chain() -> [IntrospectionNode] {
            var chain = [root()]
            while let next = chain[chain.count - 1].child() {
                chain.append(next)
            }
            return chain
        }

        /// The focused node's own actions first, then what each ancestor lends, nearest
        /// ancestor first. A nearer node wins a name that two nodes share.
        private static func reachable(in chain: [IntrospectionNode]) -> [IntrospectionAction] {
            var seen = Set<String>()
            let lent = chain.dropLast().reversed().flatMap(\.lentActions)
            return (chain[chain.count - 1].actions + lent).filter { seen.insert($0.name).inserted }
        }
    }
#endif
