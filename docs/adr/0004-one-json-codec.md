# ADR 0004: One JSON codec, and why its engine stays Foundation

- Status: Accepted
- Date: 2026-08-12

## Context

JSON is how this app talks to everything: the daemon over REST and four WebSockets, an app's own JSON-RPC surface, the
Hugging Face relay, and its own records on disk, in `UserDefaults`, in the Keychain and in the App Group the widget
reads. Fifty-two call sites across thirty-one files, in five of the eight targets.

Thirty of those files call a bare `JSONDecoder()` or `JSONEncoder()`. **Exactly one place configures anything**:
`JSONDecoder.reachyDaemon`, which teaches the decoder that FastAPI emits ISO 8601 with fractional seconds and that the
same field sometimes arrives without them. Four sites use it — `StateStreamClient`, `JobLogStreamClient`,
`RobotConnection+Apps` and `RobotConnection+Wireless` — and every other site takes the defaults, whether it is reading
a robot's answer or its own file.

So there is already a rule, and it is already only half-applied. Nothing stops the next hand-written transport from
taking the defaults and failing on a fractional timestamp, and nothing says out loud that the records on disk were
written with the defaults and cannot survive a change of them. The two halves of that — _which rules apply where_, and
_which of them are frozen because data already exists in that shape_ — are what this ADR settles.

The occasion was a proposal to adopt [mattt/swift-yyjson](https://github.com/mattt/swift-yyjson), a Swift wrapper over
the yyjson C library, whose README reports ~16× against Foundation. That question is answered here too, because the
answer turned out to be a property of our payloads rather than of the library.

## Decision: one facade, in a leaf target of its own

`ReachyJSON` is a target that depends on Foundation and nothing else, and is linked by `ReachyKit`, `ReachyWidgetUI`,
`ReachySSH`, `HuggingFaceAuth` and `ReachyUI`.

A leaf target rather than a corner of `ReachyKit`, for the reason `Package.swift` already gives twice: `ReachySSH` and
`HuggingFaceAuth` deliberately do not depend on `ReachyKit`, because the widget extension links `ReachyWidgetUI` →
`ReachyKit`, and a process woken for a moment to draw two lines of text must not load SwiftNIO to do it. A shared
codec that lived in `ReachyKit` would be shared by everything except the two targets that were pushed out of it.

```swift
public struct JSONCodec: Sendable {
    public static let daemon = JSONCodec(.daemon)
    public static let web = JSONCodec(.web)
    public static let stored = JSONCodec(.stored)

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T
    public func encode(_ value: some Encodable) throws -> Data
}
```

A value type that builds its coder per call, which is what all fifty-two sites already do. Not because a shared
instance would be unsafe — under this toolchain (Apple Swift 6.3, `-strict-concurrency=complete`) `JSONDecoder` and
`JSONEncoder` satisfy `Sendable` and a `static let decoder = JSONDecoder()` compiles clean — but because a per-call
coder was measured and found free: configuring the `.daemon` decoder (building it with its custom date closure)
costs 0.098 µs against 12.1 µs to decode a 240-byte state frame, a `-O` benchmark, under 1% at the hot call site.
Per-call construction keeps the profiles immutable values at no measurable cost, so there was nothing here worth
trading away.

**There is no default profile.** Every call site names `.daemon` or `.stored`, because a default is how the rule
became invisible the first time: thirty files took the defaults without ever deciding to.

## Decision: three profiles, and one of them is a wire format

**`.daemon`** is today's `reachyDaemon` — ISO 8601 accepted with or without fractional seconds. It belongs to anything
the robot said: the hand-written WebSocket clients, the wireless routes, an app's JSON-RPC frames, BLE replies, and
what reaches us through the relay's data channel.

**`.web`** is a third party's format — Hugging Face central (`CentralRelayClient`) and its OAuth
(`HFTokenExchanger`), six call sites. It carries Foundation's defaults, which is what those sites use today, and it
exists as a separate name rather than as a reuse of `.stored` for one reason: the two differ in what they are allowed
to become. Hugging Face may start sending a date tomorrow and `.web` may follow it; `.stored` may not follow anything.
Reusing `.stored` there would make a change made for a Hugging Face payload look safe while it silently re-formats the
Keychain.

**`.stored`** is Foundation's defaults, and it is frozen. Records written by shipped builds are sitting on disk right
now — the catalogue and move index in `Caches`, the widget's snapshot and app list in the App Group, the SSH and
Hugging Face credentials in the Keychain, the geometry cache — and every `Date` in them is a
`timeIntervalSinceReferenceDate` double because that is what `JSONEncoder` does when nobody says otherwise. Changing a
strategy on `.stored` does not reformat those files; it makes them undecodable, which each store reports as an empty
cache rather than as an error. **`.stored` may only change together with the schema version of what it writes**, and
`RobotCatalogueCache.schema` is the existing precedent for how.

That asymmetry is the point of having named profiles rather than one configured coder: two of them describe somebody
else's format and may follow it, the third describes ours and may not move.

## Decision: the engine stays Foundation, and here is what that cost

swift-yyjson was measured against this app's own payloads rather than against its README, in Release, on a real
robot's answers (2026-08-12, 406 apps, 3.74 MB).

| Payload                                       | Foundation | swift-yyjson  |
| --------------------------------------------- | ---------- | ------------- |
| Free-form (`OpenAPIObjectContainer`), 3.74 MB | 420 ms     | 321 ms (1.3×) |
| Concrete fields, four per app                 | 9.0 ms     | 2.1 ms (4.3×) |

It is genuinely faster, and most so on concrete types. It was rejected anyway, for three reasons in descending order
of weight.

**It changes values inside free-form JSON.** `1.5` decodes as `1`. `OpenAPIValueContainer` — Apple's, and what every
`extra` in this app arrives as — identifies a value by trying `Bool`, then `Int`, then `Double`, and relies on `Int`
_refusing_ a fractional number. `Decoder.swift` converts through `T(exactly: d.rounded(.towardZero))`, which the
author's own comment explains as a range check against bounds that `Double` cannot represent exactly; the side effect
is that an in-range fraction converts instead of failing. On real data that turns `mean_control_loop_frequency:
49.58` into `49` and `max_control_loop_interval: 0.0207` into `0` — the robot's health screen, reporting a zero. The
catalogue record encoded through it came out 106 KB shorter than through Foundation, silently. A six-line patch
(reject `d` where `d.rounded(.towardZero) != d`) fixes it with no measurable cost and passes the library's own 555
tests, so this is a defect rather than a design; it is simply not fixed today.

**Where it is fastest, we have no data.** The 4.3× is on concrete types, and our concrete payloads are hundreds of
bytes, read rarely. The one payload that is megabytes is the catalogue, which is almost entirely free-form `extra` —
where the gain is 1.3× and the correctness is wrong.

**The one hot path cannot use it regardless.** `OpenAPIRuntime.Converter` holds `internal var decoder: JSONDecoder`,
constructed inside its own `init`; there is no injection point, and the library's author says the same in
[issue #8](https://github.com/mattt/swift-yyjson/issues/8) — a fork is the only route. So the 3.74 MB the app decodes
off the network stays Foundation's work whatever we choose here.

Two further notes for whoever revisits this. Debug measurements are worthless in both directions: yyjson's C core is
compiled `-O0` there while Foundation arrives prebuilt, and yyjson additionally carries a large first-decode penalty
from Swift metadata initialisation ([issue #9](https://github.com/mattt/swift-yyjson/issues/9), PR #10 unmerged) —
which lands exactly on a cold start, the case the catalogue cache exists for. And `swift test -c release` cannot run
in this repository at all: the preview fixtures every test builds on are `#if DEBUG`. The numbers above come from a
standalone package outside the repository.

The facade is what makes this revisitable: the engine is one line inside `ReachyJSON`, and
`JSONCodecFreeFormTests` — `1.5`, `1e3`, `2^53 + 1`, and a real `control_loop_stats` — is the gate any replacement
has to pass first.

## What this does not cover

The generated client, for the reason above. Two hand-written exceptions stay as they are, each with its reason beside
it: `SetTargetClient` writes teleop targets through `JSONSerialization` because the `anyOf` shape has no generated
type, and `ReachyKitError` reads a daemon error body loosely because it is parsing somebody's failure, not a model.

A SwiftLint `custom_rules` entry refuses `JSONDecoder(` and `JSONEncoder(` under `Sources/` outside `ReachyJSON`, so
the next site cannot quietly become the thirty-first that takes the defaults. It is scoped to `Sources/` on purpose,
and deliberately does not reach `Tests/` — a fixture there may still call a bare coder, and a test that decodes a
daemon payload that way never exercises the date rule and proves nothing about the production path.

## Consequences

- One place states the daemon's date rule, and a new transport gets it by naming `.daemon` instead of remembering it.
- `.stored` is documented as a format with data behind it, which it always was and nowhere said.
- Adopting a different engine — yyjson once its number handling is fixed, or anything else — becomes a one-line change
  behind a test that already knows what to check, instead of a survey of fifty-two call sites.
- One more target in the graph, and a line in four dependency lists.
