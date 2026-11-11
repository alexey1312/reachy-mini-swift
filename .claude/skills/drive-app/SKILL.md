---
name: drive-app
description: Read and drive a running Debug build through its introspection tree, with no screenshot and no simulator tool. Use when you must confirm that a change works in the live app, walk the connect gate or the tabs, start the in-process simulator, or add a node for a screen (mise run introspect, --reachy-introspect, ReachyIntrospection, +Introspection.swift).
---

# Drive the app through its introspection tree

A Debug build started with `--reachy-introspect <port>` serves its screens as a tree.
Each node has a name, a state as JSON and a list of actions.
`mise run introspect` is the client.
`docs/adr/0007-introspection-tree.md` has the design,
and `Sources/ReachyIntrospection/AGENTS.md` has the rules for a node.

Prefer this to a Maestro flow when you need to know what a screen shows or to reach a state.
Use a snapshot test when the question is how a screen looks: the tree does not test pixels.

## Start the app

On a simulator, which shares the loopback of the Mac:

```bash
UDID="$(./bin/mise x -- Scripts/maestro-sim.sh)"            # build and install; --no-build to skip the build
xcrun simctl launch "$UDID" com.alexey1312.ReachyMini --reachy-introspect 8765
```

On the Mac, after `./bin/mise run build:app`:

```bash
open -n Apps/DerivedData/Build/Products/Debug/ReachyMini.app --args --reachy-introspect 8765
```

Do not add `--reachy-smoke`.
That argument stops every `onAppear` of the app, so the gate starts no discovery and the tree shows a frozen screen.
The user tests on the simulator named `iPhone 17 Pro`; set `REACHY_SNAPSHOT_SIM` to another simulator.

## Read and act

```bash
./bin/mise run introspect -- ls
./bin/mise run introspect -- do toggleDeveloper
./bin/mise run introspect -- do startSimulator
./bin/mise run introspect -- do selectTab '{"tab":"settings"}'
```

- The answer is one line of JSON on stdout: `path`, `state` and `actions`, or `error`.
- The exit status is 0 for an answer, 1 for a refusal, and 2 when nothing listens on the port.
- `path` names the nodes from the root to the focused node, for example `["App","ConnectGate"]`.
- The tree refuses an action that is not on the focused node, and the refusal lists the actions that are.
  A sheet takes the focus, so close the sheet first.
- The port is 8765, or `--port <port>`, or `REACHY_INTROSPECT_PORT`.

## Wait for a state

An action returns before the work it starts ends.
`do startSimulator` answers with the gate, and the shell arrives a moment later.
Poll `ls` for the state you expect (project rule 7), and do not sleep a fixed time:

```bash
until ./bin/mise run introspect -- ls | grep -q '"path":\["App","Shell"\]'; do sleep 0.2; done
```

## The nodes that exist

| Node             | When it is focused                                  | Actions                                                                                                                                                                                                                      |
| ---------------- | --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ConnectGate`    | No robot is connected                               | `openBluetoothSetup`, `selectRoute`, `setAddress`, `submit`, `connectKnown`, `connectDiscovered`, `showRemoteRobots`, `toggleDeveloper`, `startSimulator`, `showPermissions`, `showAccount`, `startBackend`, `continueAnyway`, `tryAgain`, `cancel` |
| `BluetoothSetup` | The Bluetooth sheet is over the gate                | `close`                                                                                                                                                                                                                      |
| `Shell`          | A robot is connected                                | `selectTab`                                                                                                                                                                                                                  |
| `Account`, `RemoteRobots`, `Permissions` | The root presents that sheet | `close`                                                                                                                                                                                                                      |
| `FirstRun`       | The first run replaces the shell                    | none                                                                                                                                                                                                                         |

An action is in the list only while its control is enabled on the screen.
`submit` needs an address that parses, and `startSimulator` needs the Developer disclosure open.
The screens inside the tabs have no nodes yet.

## Add a node for a screen

1. The screen needs a model.
   State in `@State` is out of reach of a node, so move it into an `@Observable` model first,
   as `ConnectGateModel` did for `ConnectionScreen`.
   Check that no reference image moves.
2. Write `Sources/ReachyUI/Introspection/<Model>+Introspection.swift` inside `#if DEBUG`.
   The state is a private `Encodable` struct in that file.
   Do not make a domain type `Codable` for this: it then looks fit for `JSONCodec.stored`.
3. Offer each action under the condition that enables its control, and call what the control calls.
4. Link the node into its parent's `child`, or register the model with `.introspected(_:)` when a screen owns it.
5. Add a test that drives `IntrospectionTree` in process, as `IntrospectionGateTests` does.
