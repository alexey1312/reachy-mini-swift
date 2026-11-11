# ADR 0007: An introspection tree for agents — one part of Reflex, and no reducers

- Status: Accepted for the connect gate and the tab shell.
  A node for a further screen is a decision for that screen, by the price measured below
- Date: 2026-11-11

## Context

On 2026-11-05 Shopify described Reflex
([Reflex: an architecture for building mobile apps with agents](https://shopify.engineering/reflex)).
It is an MVVM discipline and not a library:
"There's no library to publish because the useful part isn't our code."
Read as a specification, it has four parts:

- **A core with no UI import.**
  The core builds on macOS, and the UI module depends on it.
- **One shape for every view model.**
  `State`, an `Action` enum sent through `send(action:)`, an internal `Message`,
  and one `update(state, message)` that is the only place state changes.
- **Navigation in the core**, as a tree: the app root, navigators, one view model for each screen.
- **An introspection node on every view model**: `name`, `state` as JSON, `actions`, `child`.
  A command-line tool focuses the deepest node, prints it with `ls` and runs an action with `do`.

Shopify's results are 1,700 behavior tests in four minutes on CI
and one test in a few hundred milliseconds with no device.
Its goals are a fast loop for agents that write screens,
parity between a Swift app and a Kotlin app,
and an app that an agent can drive.

### What this repository already has

- `ReachyKit` (187 files) imports no SwiftUI.
  `ReachyWidgetUI` and `ReachyTeleop` exist because of the same rule.
- Services are closures and protocols passed to an initializer.
- 2,456 tests run under `swift test` with no simulator, and 96 test files exercise the models of `ReachyUI`.

### What a full move would cost

- `ReachyUI` has 46 `@Observable` models (9,763 lines) with 242 methods.
  Each becomes a reducer, and each of its tests is rewritten.
- 32 files declare a `NavigationStack`, a sheet or a `TabView` locally.
- The app is streams: state at 10 Hz, WebRTC, teleop, BLE, a game controller.
  The article does not describe a concurrency model,
  and a synchronous `update` for teleop frames under Swift 6 strict concurrency is a design of our own.
- The prize is parity with an Android app, and there is no Android app.

## Decisions

### 1. Take the introspection tree, and leave the reducers

The tree is the part that pays here.
The only way to walk the live app today is a Maestro flow:
13 s for the flows and about 21 s for the driver.
The tree lets an agent walk the same path through a socket,
and lets a test walk it in process.

No model becomes a reducer.
A node is an extension over a model as the model is.

### 2. The kit is a target of its own, on Foundation, Network and ReachyJSON

`Sources/ReachyIntrospection` links no ReachyKit.
`JSONValue` is a new type for that reason: `RemoteValue` is in ReachyKit and only encodes.

### 3. The server is Debug only, on the loopback only, behind a launch argument

Every file of the kit is inside `#if DEBUG`, so a Release build contains no part of it.
The server alone was not enough: a Release app that linked ReachyUI still carried 853 symbols of the kit,
because Xcode links a package target that is a dependency whether or not a file imports it.
The listener binds `127.0.0.1`.
A simulator shares the loopback of its Mac; a real device is out of reach, and that is accepted.
The app starts the server only for `--reachy-introspect <port>`.
`--reachy-smoke` does not start it, because that argument stops every `onAppear` of the app.

### 4. The wire format is newline-delimited JSON, and the client waits by polling

```
→ {"id":1,"cmd":"ls"}
← {"id":1,"ok":true,"path":["App","ConnectGate"],"state":{…},"actions":[{"name":"submit"}]}
→ {"id":2,"cmd":"do","action":"setAddress","input":{"text":"127.0.0.1"}}
← {"id":3,"ok":false,"error":"action 'selectTab' is not on the focused node; available: …"}
```

`do` answers with the tree as it is when the action returns.
An action that starts a connection returns before the connection ends,
so the client polls `ls` for the state it expects (project rule 7).

### 5. The client is an executable target, and the behavior tests are swift-testing

`ReachyIntrospect` is an executable for the reason `ReachyGeometryExport` is one:
a script cannot link a target, and the request and response types must be the app's own.
Shopify writes its behavior tests in TypeScript on Bun, so that one file runs on two platforms.
There is one platform here, so a behavior test is a swift-testing suite that drives `IntrospectionTree` in process.

### 6. Nodes are written by hand

Shopify names a macro that could write a node.
Two or three nodes do not pay for a macro target.

## What the first two screens answered

The connect gate and `ReachyRouter` came first.
The gate had no model: `ConnectionScreen` held its state in eleven `@State` properties,
and its actions were private methods of the view.
A node needs a model to read, so the gate's state moved into `ConnectGateModel` first.
All three answers were measured on 2026-11-11.

- **The path "gate → simulator → tabs" takes 1.1 s through the socket.**
  That is five commands and three polls of `ls` on an iPhone 17 Pro simulator (iOS 27.0),
  from the close of the first-launch sheet to the Settings tab.
  The Maestro flow for the gate alone took 17 s on the same simulator, and 30 s with its driver.
  The same path in process, as a swift-testing case, takes 0.18 s.
  On the Debug macOS app, started with `open -n -g … --args --reachy-introspect 8766`, the path took 2.5 s.
- **The move of one screen's state into a model cost 144 lines of model and 111 lines of tests**,
  and it took 60 lines out of the view (64 added, 124 removed across three files).
  That is the price of every later screen that keeps its state in `@State`.
- **No reference image moved.**
  535 snapshot tests passed after the move,
  and the checksums of the references were equal before and after the run.

### What the nodes do not cover

- **The screens inside the five tabs.**
  The shell is the focused node on every tab.
- **Three things on the gate**: Forget, whose confirmation is `@State` of `NetworkRobotsSection`;
  the row for a daemon on this Mac; and `DaemonUpdateScreen`.
- **The first run**, which has a name in the tree and no action.
- **A real device.** The server binds the loopback.

### The model stays with its screen

The plan was for the root to own `ConnectGateModel`.
The screen owns it, because the root lives for the whole run:
a gate that came back after a disconnect would keep the old address and an open Developer disclosure.
So the screen registers its model when it appears (`.introspected(_:)`),
through a registry in the environment that only an introspected run reads.

## Consequences

- An agent reads a screen as JSON and does not parse a screenshot.
- A node is a second description of a screen, and it can drift from the view.
  The rule that a node holds no logic limits that,
  and a test holds the gate's actions to its `AccessibilityID` cases.
- The tree does not test pixels.
  The reference images stay the check for those.
- A screen whose state is in `@State` needs that state in a model before it can have a node.
  That is a refactor for each screen, and this ADR does not commit to it beyond the first two.
- A node writes the condition of each control a second time.
  A `disabled` that changes on the screen must change in the node,
  and only the five controls with an `AccessibilityID` have a test that notices.
