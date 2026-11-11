# ReachyIntrospection

The app as a tree that an agent can read and drive, with no pixel and no simulator tool:
`IntrospectionNode` (one screen: its name, its state as JSON, its actions, its child),
`IntrospectionTree` (finds the focused node and runs an action on it),
`IntrospectionServer` (serves the tree on the loopback, Debug builds only),
`IntrospectionClient` and the `ReachyIntrospect` executable (`mise run introspect`).

It is the one part of Shopify's Reflex architecture that this repository takes.
`docs/adr/0007-introspection-tree.md` gives the reasons, and the parts that were left out.
The target links Foundation, Network and ReachyJSON, and nothing else,
so a target with no ReachyKit can link it.

- **A node holds no logic.**
  If a user can see a value, the value is in `state`.
  If a user can do a thing, the thing is in `actions`.
  An action calls the method that the view calls.
  A node that decides something is a second implementation of the screen, and the two can drift.
- **The focused node is the deepest node of the `child` chain.**
  The tree refuses an action that is not on the focused node, with the list of the actions that are.
  That refusal is the reason a run means something: an agent cannot press a button that is under a sheet.
  An ancestor puts an action in `lentActions` to keep the action in reach,
  as a tab bar stays in reach on every tab.
- **Nothing is cached.**
  The tree reads the root again for each request.
  A state change needs no notification to reach the next `ls`.
- **An action returns before the work it starts ends.**
  `do` answers with the tree as it is when the action returns.
  The client polls `ls` for the state it expects (project rule 7), and does not sleep.
- **The server is `#if DEBUG`, and it binds `127.0.0.1`.**
  A Release build does not contain the type.
  A simulator shares the loopback of its Mac, so a client on the Mac reaches an iOS build.
  A real device is out of reach, and that is accepted.
- **The wire format is one JSON object for each line**, in both directions.
  `LineBuffer` finds the lines, because one TCP read can hold half a line or three lines.
  The server answers the lines of one read in order before it reads again.
- **JSON goes through `JSONCodec.web`** (project rule 11).
  The protocol carries no date, so the date rule of `.daemon` does not apply,
  and the format is not a stored record, so `.stored` does not apply.
- **`JSONValue` is not `RemoteValue`.**
  `RemoteValue` is in ReachyKit and only encodes.
- **Listener readiness comes through `AsyncStream.makeStream()`, not the closure builder.**
  The closure builder with a captured continuation is the shape that hangs the compiler
  (`Tests/ReachyKitTests/RemoteControlChannelTests.swift`).
