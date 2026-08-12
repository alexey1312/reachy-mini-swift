# JSONCodec Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put every hand-written JSON call in this repository behind one facade that names the rules it applies, so a
new call site inherits the daemon's date handling instead of rediscovering it, and so the format of records already on
disk cannot change by accident.

**Architecture:** A leaf target `ReachyJSON` (Foundation only) exposes `JSONCodec`, a `Sendable` value type with three
named profiles — `.daemon`, `.web`, `.stored` — each building a Foundation coder per call. The five targets that touch
JSON link it. A SwiftLint `custom_rules` entry then refuses `JSONDecoder(`/`JSONEncoder(` anywhere else, so the rule
holds without anyone remembering it.

**Tech Stack:** Swift 6 strict concurrency, SwiftPM (`Package.swift`), swift-testing, SwiftLint, mise task runner.

**Design source:** `docs/adr/0004-one-json-codec.md`. Read it first — it carries the measurements behind the
Foundation decision and the reason `.stored` is frozen.

## Global Constraints

- Every tool runs through `./bin/mise run <task>` or `./bin/mise x -- <tool>`. Never call `swift`, `swiftlint` or
  `dprint` bare.
- Swift 6 strict concurrency. `JSONCodec` must be `Sendable`; it may not hold a shared `JSONDecoder`/`JSONEncoder`
  instance, because those are classes and are not documented as safe to share.
- `.stored` is a wire format with shipped data behind it. Its encoded bytes may not change in this work — a `Date`
  stays a `timeIntervalSinceReferenceDate` number, keys stay verbatim, nothing gets sorted or pretty-printed.
- Conventional commits (`feat:`, `refactor:`, `test:`, `chore:`), enforced by the commit-msg hook.
- **The pre-commit hook stages every modified `*.swift` and `*.md` in the tree, not only what you `git add`.** Before
  the first commit, check `git status`; anything unrelated must be moved aside with `git stash push <paths>` or it
  lands in your commit.
- `./bin/mise run lint` must pass with zero violations (`--strict`). Line length: 120 warning, 200 error.
- `Package.resolved` legitimately oscillates between 20 and 25 pins (`swift test` strips the Xcode workspace pins).
  Commit the 25-pin version — run `./bin/mise run project` last, or `git checkout -- Package.resolved`.
- Comments carry the non-obvious _why_ and nothing else. Do not restate what the code says.

## File Structure

**Created:**

- `Sources/ReachyJSON/JSONCodec.swift` — the facade: the `JSONCodec` value, its three profiles, and the rules each
  one carries. The only file in the repository allowed to name `JSONDecoder`/`JSONEncoder`.
- `Sources/ReachyJSON/AGENTS.md` + `CLAUDE.md` symlink — the per-target note, matching every other target.
- `Tests/ReachyJSONTests/JSONCodecTests.swift` — profile behaviour and the `.stored` byte freeze.
- `Tests/ReachyKitTests/JSONCodecFreeFormTests.swift` — the engine gate. It lives here rather than in
  `ReachyJSONTests` because it needs `OpenAPIObjectContainer`, which comes from `OpenAPIRuntime` through `ReachyKit`,
  and `ReachyJSON` must stay Foundation-only.

**Deleted:**

- `Sources/ReachyKit/Model/JSONDecoder+Daemon.swift` — becomes `JSONCodec.daemon`.

**Modified:** `Package.swift`, `.swiftlint.yml`, `Sources/ReachyKit/AGENTS.md`, and the 31 call-site files listed per
task.

## Profile assignment

Every migrated site takes exactly one profile. This table is the classification; it was made by reading each call
site, and a task's step list repeats the lines it owns.

| Profile   | What it means                                    | Date handling                                   |
| --------- | ------------------------------------------------ | ----------------------------------------------- |
| `.daemon` | The robot said it (REST, WebSocket, BLE, WebRTC) | ISO 8601, with or without fractional seconds    |
| `.web`    | A third-party service said it (Hugging Face)     | Foundation defaults, free to follow the service |
| `.stored` | We wrote it (disk, UserDefaults, Keychain)       | Foundation defaults, **frozen** — see ADR 0004  |

`.web` is not decoration. It is identical to `.stored` today and must not be merged with it: `.stored` is frozen
because data exists in that shape, while `.web` may follow whatever Hugging Face does next. Merging them would make
the next person's change to a Hugging Face payload look safe when it silently re-formats the Keychain.

---

### Task 1: The `ReachyJSON` target and the facade

**Files:**

- Create: `Sources/ReachyJSON/JSONCodec.swift`
- Create: `Tests/ReachyJSONTests/JSONCodecTests.swift`
- Modify: `Package.swift` (targets list, after `.target(name: "HuggingFaceAuth")` and in the test targets)

**Interfaces:**

- Produces: `JSONCodec.daemon`, `JSONCodec.web`, `JSONCodec.stored`, each a `JSONCodec`; and on each,
  `decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T` and
  `encode(_ value: some Encodable) throws -> Data`. Every later task consumes these three values and two methods.

- [ ] **Step 1: Add the target to `Package.swift`**

In `targets:`, directly after `.target(name: "HuggingFaceAuth"),`:

```swift
// Every hand-written JSON call in this repository, and the rules each kind
// of payload is read under. A leaf on Foundation alone because `ReachySSH`
// and `HuggingFaceAuth` deliberately do not depend on `ReachyKit` — see
// docs/adr/0004-one-json-codec.md.
.target(name: "ReachyJSON", exclude: ["AGENTS.md", "CLAUDE.md"]),
```

In the test targets, directly after the `ReachyDesignTests` entry:

```swift
.testTarget(
    name: "ReachyJSONTests",
    dependencies: ["ReachyJSON"]
),
```

No `products:` entry: nothing in `Apps/` names this target, and `ReachyTestSupport` is the existing precedent for a
target that is not a product.

- [ ] **Step 2: Write the failing tests**

Create `Tests/ReachyJSONTests/JSONCodecTests.swift`:

```swift
import Foundation
@testable import ReachyJSON
import Testing

@Suite("JSON codec")
struct JSONCodecTests {
    private struct Stamped: Codable, Equatable {
        let takenAt: Date
    }

    /// FastAPI emits fractional seconds; the same field arrives without them from
    /// other daemon routes. Both have to read.
    @Test("the daemon profile reads ISO 8601 with and without fractional seconds")
    func daemonDates() throws {
        let fractional = try JSONCodec.daemon.decode(
            Stamped.self,
            from: Data(#"{"takenAt":"2026-08-12T10:14:03.472Z"}"#.utf8)
        )
        let whole = try JSONCodec.daemon.decode(
            Stamped.self,
            from: Data(#"{"takenAt":"2026-08-12T10:14:03Z"}"#.utf8)
        )

        #expect(whole.takenAt.timeIntervalSince1970 == 1_786_659_243)
        #expect(abs(fractional.takenAt.timeIntervalSince1970 - 1_786_659_243.472) < 0.001)
    }

    @Test("the daemon profile refuses a date it cannot read, rather than inventing one")
    func daemonRejectsNonsense() {
        #expect(throws: DecodingError.self) {
            try JSONCodec.daemon.decode(Stamped.self, from: Data(#"{"takenAt":"yesterday"}"#.utf8))
        }
    }

    /// The freeze, at the level it matters: bytes. Records written by shipped
    /// builds carry `Date` as a `timeIntervalSinceReferenceDate` number, and a
    /// strategy change here does not reformat them — it makes them unreadable,
    /// which every store reports as an empty cache. See ADR 0004.
    @Test("a stored date is a number, and stays one")
    func storedDatesAreNumbers() throws {
        let data = try JSONCodec.stored.encode(Stamped(takenAt: Date(timeIntervalSinceReferenceDate: 1000)))

        #expect(String(decoding: data, as: UTF8.self) == #"{"takenAt":1000}"#)
    }

    @Test("a stored value round-trips")
    func storedRoundTrip() throws {
        let value = Stamped(takenAt: Date(timeIntervalSinceReferenceDate: 12345.75))
        let data = try JSONCodec.stored.encode(value)

        #expect(try JSONCodec.stored.decode(Stamped.self, from: data) == value)
    }

    /// `.web` is `.stored`'s settings with none of its obligations, and the test
    /// exists to say so: if someone gives Hugging Face a date rule tomorrow, this
    /// is what tells them they have not touched the Keychain's format.
    @Test("the web profile is separate from the stored one")
    func webIsItsOwnProfile() throws {
        let value = Stamped(takenAt: Date(timeIntervalSinceReferenceDate: 1000))

        #expect(try JSONCodec.web.encode(value) == JSONCodec.stored.encode(value))
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
./bin/mise x -- swift test --filter JSONCodecTests
```

Expected: build failure, `no such module 'ReachyJSON'` or `cannot find 'JSONCodec' in scope`.

- [ ] **Step 4: Write the facade**

Create `Sources/ReachyJSON/JSONCodec.swift`:

```swift
import Foundation

/// Every hand-written JSON call in this app, and the rule each kind of payload is
/// read under.
///
/// Three profiles rather than one configured coder, because the profiles differ in
/// what they are *allowed* to become: `.daemon` and `.web` describe somebody else's
/// format and may follow it, while `.stored` describes ours and may not move —
/// records written by shipped builds are on disk right now. `docs/adr/0004-one-json-codec.md`
/// carries the reasoning, including why the engine is Foundation.
///
/// A value that builds its coder per call: `JSONDecoder` is a class and is not
/// documented as safe to share, so one configured instance would have to be
/// `nonisolated(unsafe)` to cross a concurrency domain.
public struct JSONCodec: Sendable {
    /// The robot said it — REST, the four WebSockets, BLE replies, the WebRTC data
    /// channel. FastAPI emits ISO 8601 with fractional seconds and other routes
    /// omit them, so both read.
    public static let daemon = JSONCodec(.daemon)
    /// A third-party service said it — Hugging Face central and its OAuth. Foundation's
    /// defaults today, and free to follow the service tomorrow.
    public static let web = JSONCodec(.web)
    /// We wrote it: `Caches`, `UserDefaults`, the App Group, the Keychain.
    ///
    /// **Frozen.** These settings are what shipped builds encoded with, so changing
    /// one does not reformat the records — it makes them undecodable, which every
    /// store here reports as an empty cache rather than as an error. Change it only
    /// together with the schema version of whatever writes it
    /// (`RobotCatalogueCache.schema` is the precedent).
    public static let stored = JSONCodec(.stored)

    private enum Profile: Sendable {
        case daemon
        case web
        case stored
    }

    private let profile: Profile

    private init(_ profile: Profile) {
        self.profile = profile
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }

    public func encode(_ value: some Encodable) throws -> Data {
        try encoder().encode(value)
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        if case .daemon = profile {
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let string = try container.decode(String.self)
                let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
                if let date = (try? Date(string, strategy: fractional)) ?? (try? Date(string, strategy: .iso8601)) {
                    return date
                }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unrecognized ISO 8601 date: \(string)"
                )
            }
        }
        return decoder
    }

    private func encoder() -> JSONEncoder {
        // No branch yet: nothing in this app sends a `Date` to the robot or to
        // Hugging Face, and `.stored` is frozen on the defaults. The first payload
        // that needs one adds its case here rather than at the call site.
        JSONEncoder()
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```bash
./bin/mise x -- swift test --filter JSONCodecTests
```

Expected: 5 tests passing.

- [ ] **Step 6: Write the target's note**

Create `Sources/ReachyJSON/AGENTS.md`:

```markdown
# ReachyJSON

Every hand-written JSON call in this repository. Foundation and nothing else — it is linked by `ReachySSH` and
`HuggingFaceAuth`, which deliberately do not depend on `ReachyKit`.

- **Three profiles, and the difference is what they may become.** `.daemon` and `.web` describe somebody else's
  format and may follow it; `.stored` describes ours and may not move. Records written by shipped builds are on disk
  now, and a changed strategy does not reformat them — it makes them undecodable, which every store here reports as
  an empty cache rather than as an error.
- **The engine is Foundation, and that was measured rather than assumed** — `docs/adr/0004-one-json-codec.md` carries
  the numbers for swift-yyjson and the reason it was refused. `JSONCodecFreeFormTests` in `ReachyKitTests` is the gate
  any replacement engine passes first: it is where a decoder that turns `1.5` into `1` gets caught.
- **This is the only file allowed to name `JSONDecoder`/`JSONEncoder`**, enforced by a `custom_rules` entry in
  `.swiftlint.yml`. Two sanctioned exceptions live elsewhere with their reasons beside them: `SetTargetClient`
  (`JSONSerialization` over the teleop `anyOf` the generator cannot express) and `ReachyKitError` (loose parsing of a
  daemon error body).
- **The generated OpenAPI client is out of reach.** `OpenAPIRuntime.Converter` builds its own `JSONDecoder` in its
  `init` with no injection point — do not go looking for one.
```

Then link it:

```bash
ln -s AGENTS.md Sources/ReachyJSON/CLAUDE.md
```

- [ ] **Step 7: Lint and commit**

```bash
./bin/mise run format
./bin/mise x -- swiftlint lint --strict Sources Tests Apps/ReachyMini Apps/ReachyMiniUITests Apps/ReachyStorybook Apps/ReachyUISnapshotTests Apps/ReachyWidget
git checkout -- Package.resolved
git add Package.swift Sources/ReachyJSON Tests/ReachyJSONTests
git commit -m "feat(json): one codec for every hand-written JSON call"
```

---

### Task 2: The engine gate

**Files:**

- Create: `Tests/ReachyKitTests/JSONCodecFreeFormTests.swift`

**Interfaces:**

- Consumes: `JSONCodec.daemon` and `JSONCodec.stored` from Task 1.
- Produces: nothing other tasks depend on. This is the acceptance test any future engine must pass.

- [ ] **Step 1: Add `ReachyJSON` to `ReachyKit`**

In `Package.swift`, the `ReachyKit` target's `dependencies:` gains `"ReachyJSON"`:

```swift
dependencies: [
    "ReachyJSON",
    .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
    .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
],
```

- [ ] **Step 2: Write the failing test**

Create `Tests/ReachyKitTests/JSONCodecFreeFormTests.swift`:

```swift
import Foundation
import OpenAPIRuntime
import ReachyJSON
import Testing

/// The gate any replacement JSON engine passes before it is considered.
///
/// Free-form JSON is most of what this app reads: `AppInfo.extra` is the Hugging
/// Face card verbatim, and `control_loop_stats` is the robot's own telemetry. Both
/// arrive as `OpenAPIObjectContainer`, which identifies a value by trying `Bool`,
/// then `Int`, then `Double` — and relies on `Int` *refusing* a fractional number.
/// A decoder that rounds instead reports 49.58 Hz as 49 and 0.0207 s as 0, with no
/// error anywhere. swift-yyjson 0.6.0 does exactly that; see ADR 0004.
@Suite("JSON codec: free-form values")
struct JSONCodecFreeFormTests {
    private func value(_ json: String, _ key: String) throws -> String {
        let container = try JSONCodec.daemon.decode(OpenAPIObjectContainer.self, from: Data(json.utf8))
        return String(describing: try #require(container.value[key] ?? nil))
    }

    @Test("a fractional number stays fractional")
    func keepsFractions() throws {
        #expect(try value(#"{"float": 1.5}"#, "float") == "1.5")
    }

    @Test("the robot's control loop stats survive to the last digit")
    func keepsTelemetry() throws {
        let json = """
        {"mean_control_loop_frequency": 49.58092675563731,
         "max_control_loop_interval": 0.020709514617919922,
         "nb_error": 0}
        """
        #expect(try value(json, "mean_control_loop_frequency") == "49.58092675563731")
        #expect(try value(json, "max_control_loop_interval") == "0.020709514617919922")
        #expect(try value(json, "nb_error") == "0")
    }

    @Test("an integer written as an exponent is still an integer")
    func keepsExponentIntegers() throws {
        #expect(try value(#"{"exp": 1e3}"#, "exp") == "1000")
    }

    /// Beyond `Double`'s exact range, so a decoder that routes every number through
    /// `Double` loses the last digit here.
    @Test("an integer past 2^53 keeps every digit")
    func keepsLargeIntegers() throws {
        #expect(try value(#"{"big": 9007199254740993}"#, "big") == "9007199254740993")
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

```bash
./bin/mise x -- swift test --filter JSONCodecFreeFormTests
```

Expected: build failure, `no such module 'ReachyJSON'` — until Step 1's manifest edit is in place, then all four
tests pass on the first run (Foundation is already correct here). That is the point: the gate is written against a
known-good engine so it can catch the next one.

- [ ] **Step 4: Run it to verify it passes**

```bash
./bin/mise x -- swift test --filter JSONCodecFreeFormTests
```

Expected: 4 tests passing.

- [ ] **Step 5: Commit**

```bash
git checkout -- Package.resolved
git add Package.swift Tests/ReachyKitTests/JSONCodecFreeFormTests.swift
git commit -m "test(json): gate any future JSON engine on free-form values"
```

---

### Task 3: Migrate ReachyKit's daemon-facing sites

**Files (each line is one call to change):**

- Modify: `Sources/ReachyKit/Transport/StateStreamClient.swift:69`
- Modify: `Sources/ReachyKit/Transport/JobLogStreamClient.swift:121,124`
- Modify: `Sources/ReachyKit/Transport/RobotConnection+Apps.swift:49,184`
- Modify: `Sources/ReachyKit/Transport/RobotConnection+Wireless.swift:68`
- Modify: `Sources/ReachyKit/Transport/RobotConnection.swift:366,367`
- Modify: `Sources/ReachyKit/Transport/RobotConnection+WiFi.swift:24`
- Modify: `Sources/ReachyKit/Transport/CameraSignalingClient.swift:105,191`
- Modify: `Sources/ReachyKit/Transport/ConversationRPCClient.swift:118`
- Modify: `Sources/ReachyKit/WiFi/WiFiProvisioningTransport.swift:103`
- Modify: `Sources/ReachyKit/WiFi/SealedWiFiCredentials.swift:37`
- Modify: `Sources/ReachyKit/BLE/BLEProvisioningTransport.swift:16`
- Modify: `Sources/ReachyKit/Central/RemoteDaemonLog.swift:39,45`
- Modify: `Sources/ReachyKit/Central/RemoteRobotConnection.swift:147,156`
- Modify: `Sources/ReachyKit/Central/RemoteControlChannel.swift:232,250,301,391`
- Modify: `Sources/ReachyKit/Model/RobotApps.swift:161,162`
- Delete: `Sources/ReachyKit/Model/JSONDecoder+Daemon.swift`

**Interfaces:**

- Consumes: `JSONCodec.daemon.decode(_:from:)` and `JSONCodec.daemon.encode(_:)` from Task 1.

`RobotApps.swift:161-162` is included because it re-encodes the daemon's `extra` and decodes it back into `Card`;
both halves belong to the same payload and must name the same profile.

- [ ] **Step 1: Confirm the existing tests pass before touching anything**

```bash
./bin/mise run test
```

Expected: 1194+ passing. This is the baseline the migration must not move — the whole task is behaviour-preserving.

- [ ] **Step 2: Rewrite each call**

Two mechanical forms. Decode:

```swift
// before
try JSONDecoder.reachyDaemon.decode(DaemonJob.self, from: data)
try JSONDecoder().decode(RobotAppStatus.self, from: data)
// after
try JSONCodec.daemon.decode(DaemonJob.self, from: data)
try JSONCodec.daemon.decode(RobotAppStatus.self, from: data)
```

Encode:

```swift
// before
try JSONEncoder().encode(message)
// after
try JSONCodec.daemon.encode(message)
```

`StateStreamClient.swift:69` holds the decoder in a local (`let decoder = JSONDecoder.reachyDaemon`) and uses it in a
loop. Replace the local with `let decoder = JSONCodec.daemon`; the call sites below it need no change, because
`decode(_:from:)` keeps its signature.

Add `import ReachyJSON` to each file whose imports do not already have it, in alphabetical order among the existing
imports.

- [ ] **Step 3: Delete the old extension**

```bash
git rm Sources/ReachyKit/Model/JSONDecoder+Daemon.swift
```

Its one behaviour now lives in `JSONCodec.daemon`. `Tests/ReachyKitTests/FullStateDecodingTests.swift:19` names
`JSONDecoder.reachyDaemon` and must move to `JSONCodec.daemon.decode(...)` in the same commit, or the build breaks.

- [ ] **Step 4: Run the tests**

```bash
./bin/mise run test
```

Expected: the same count as Step 1, all passing. A failure here is a real regression, not a formality — the daemon
date rule reaching a site that did not have it before is the one behaviour change this task can cause, and it can only
make a previously-throwing decode succeed.

- [ ] **Step 5: Commit**

```bash
./bin/mise run format
git checkout -- Package.resolved
git add Sources/ReachyKit Tests/ReachyKitTests/FullStateDecodingTests.swift
git commit -m "refactor(kit): read every daemon payload through JSONCodec.daemon"
```

---

### Task 4: Migrate the stored and web sites

**Files:**

`.stored` — records this app wrote:

- Modify: `Sources/ReachyKit/Cache/RobotCatalogueCache.swift:107,117`
- Modify: `Sources/ReachyKit/Model/KnownRobot.swift:43,51,54,85`
- Modify: `Sources/ReachyKit/Model/RobotAppsCache.swift:91,101`
- Modify: `Sources/ReachyKit/Model/RobotSnapshot.swift:160,164`
- Modify: `Sources/ReachyKit/Model/MovePlaybackRecord.swift:43,47`
- Modify: `Sources/ReachyKit/Geometry/GeometryCache.swift:98`
- Modify: `Sources/ReachyKit/Preview/PreviewFixtures.swift:211,266`
- Modify: `Sources/ReachyKit/Preview/PreviewStoreFixtures.swift:59`
- Modify: `Sources/ReachyWidgetUI/RobotAppLaunchState.swift:82,108`
- Modify: `Sources/ReachyWidgetUI/RobotPowerTransitionState.swift:100,119`
- Modify: `Sources/ReachySSH/KeychainSSHStores.swift:98,107`
- Modify: `Sources/HuggingFaceAuth/KeychainHFTokenStore.swift:43,52`
- Modify: `Sources/ReachyUI/Apps/AppStoreModel.swift:308` (a `#if DEBUG` preview fixture)

`.web` — Hugging Face:

- Modify: `Sources/ReachyKit/Central/CentralRelayClient.swift:156,162,173,266`
- Modify: `Sources/HuggingFaceAuth/HFTokenExchanger.swift:66,127`

- Modify: `Package.swift` — `"ReachyJSON"` joins the `dependencies:` of `ReachyWidgetUI`, `ReachySSH`,
  `HuggingFaceAuth` and `ReachyUI`.

**Interfaces:**

- Consumes: `JSONCodec.stored` and `JSONCodec.web` from Task 1.

- [ ] **Step 1: Write the failing compatibility test**

The freeze in Task 1 is on a local type. This one is on a real shipped record, and it is what catches a migration that
silently re-formats what is already on disk. `RobotAppCatalogueRecord` is the one to use: it is the record with a
`Date` in it (`MovePlaybackRecord` has none — `robotID`, `uuid`, `dataset`, `move` and nothing else), and it is the
store whose contents were measured in megabytes on 2026-08-12, so there is real data in this shape.

Create `Tests/ReachyKitTests/StoredFormatTests.swift`:

```swift
import Foundation
@testable import ReachyKit
import ReachyJSON
import Testing

/// A record in the shape shipped builds wrote. `.stored` may not move without a
/// schema bump — see ADR 0004. What this pins is the `Date`: Foundation's default
/// encoding is a `timeIntervalSinceReferenceDate` number, and any strategy that
/// makes it a string leaves every catalogue on every device undecodable, which
/// `RobotCatalogueCache.record` reports as an empty cache rather than as an error.
@Suite("Stored format")
struct StoredFormatTests {
    @Test("a catalogue record written before JSONCodec still decodes")
    func decodesAShippedRecord() throws {
        let shipped = #"{"schema":1,"robotID":"hw-1","apps":[],"takenAt":776000000}"#

        let record = try JSONCodec.stored.decode(RobotAppCatalogueRecord.self, from: Data(shipped.utf8))

        #expect(record.robotID == "hw-1")
        #expect(record.schema == RobotCatalogueCache.schema)
        #expect(record.takenAt == Date(timeIntervalSinceReferenceDate: 776_000_000))
    }

    @Test("and one written now is still that shape")
    func writesTheSameShape() throws {
        let record = RobotAppCatalogueRecord(
            robotID: "hw-1",
            apps: [],
            takenAt: Date(timeIntervalSinceReferenceDate: 776_000_000)
        )

        let json = try String(decoding: JSONCodec.stored.encode(record), as: UTF8.self)

        #expect(json.contains(#""takenAt":776000000"#))
        #expect(!json.contains("1994-08"))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
./bin/mise x -- swift test --filter StoredFormatTests
```

Expected: FAIL — `no such module 'ReachyJSON'` in `ReachyKitTests` is already satisfied by Task 2, so the failure
should be the assertion or a decoding error if the literal does not match the type. Fix the literal until it passes
against the _current_ code, before changing any call site. A golden fixture that was never green against the old
encoder proves nothing.

- [ ] **Step 3: Rewrite each call**

```swift
// before
try? JSONDecoder().decode(RobotSnapshot.self, from: data)
try? JSONEncoder().encode(snapshot)
// after
try? JSONCodec.stored.decode(RobotSnapshot.self, from: data)
try? JSONCodec.stored.encode(snapshot)
```

and for the two Hugging Face files:

```swift
// before
try? JSONDecoder().decode(Whoami.self, from: data)
// after
try? JSONCodec.web.decode(Whoami.self, from: data)
```

Add `import ReachyJSON` where missing, and add the dependency to the four targets in `Package.swift`.

- [ ] **Step 4: Run the full suite**

```bash
./bin/mise run test
```

Expected: the same count as Task 3 Step 1, all passing, including `StoredFormatTests`.

- [ ] **Step 5: Commit**

```bash
./bin/mise run format
git checkout -- Package.resolved
git add Package.swift Sources Tests
git commit -m "refactor(json): name the profile at every remaining JSON call"
```

---

### Task 5: Make the rule hold without anyone remembering it

**Files:**

- Modify: `.swiftlint.yml`
- Modify: `Sources/ReachyKit/AGENTS.md`
- Modify: `CLAUDE.md` (root, the project rules list)

- [ ] **Step 1: Add the custom rule**

Append to `.swiftlint.yml`:

```yaml
custom_rules:
  json_codec_only:
    name: "JSON coder outside ReachyJSON"
    regex: '\bJSON(Decoder|Encoder)\('
    match_kinds:
      - identifier
      - typeidentifier
    excluded: ".*/(ReachyJSON/JSONCodec\\.swift|ReachyJSONTests/.*)"
    message: "Use JSONCodec.daemon / .web / .stored — see docs/adr/0004-one-json-codec.md"
    severity: error
```

- [ ] **Step 2: Run the linter to verify the rule fires and the tree is clean**

```bash
./bin/mise x -- swiftlint lint --strict Sources Tests Apps/ReachyMini Apps/ReachyMiniUITests Apps/ReachyStorybook Apps/ReachyUISnapshotTests Apps/ReachyWidget
```

Expected: zero violations. Then prove the rule actually fires — put `_ = JSONDecoder()` in any file under `Sources/ReachyKit`,
re-run, and expect exactly one `json_codec_only` error naming that line. Remove it again. A custom rule whose regex
never matches passes silently and guards nothing.

- [ ] **Step 3: Write the rules down where they will be read**

In `Sources/ReachyKit/AGENTS.md`, add to the bullet list:

```markdown
- **Every hand-written JSON call goes through `JSONCodec`** (`ReachyJSON`), naming `.daemon`, `.web` or `.stored`.
  There is no default profile on purpose: a default is how thirty files ended up taking Foundation's settings without
  deciding to. `.stored` is frozen — records from shipped builds are on disk, and a changed strategy makes them
  undecodable, which every store here reports as an empty cache rather than as an error. The generated OpenAPI client
  is outside all of this: `Converter` builds its own `JSONDecoder` with no injection point. Reasoning and the
  swift-yyjson measurements: `docs/adr/0004-one-json-codec.md`.
```

In the root `CLAUDE.md`, add to the numbered project rules:

```markdown
11. **JSON goes through `JSONCodec`.** `.daemon` for what the robot said, `.web` for Hugging Face, `.stored` for what
    this app wrote — and `.stored` may not change without a schema bump, because records from shipped builds are on
    disk. A `JSONDecoder()` outside `ReachyJSON` is a SwiftLint error. Two sanctioned exceptions carry their reason in
    the code: `SetTargetClient` and `ReachyKitError`.
```

- [ ] **Step 4: Full verification**

```bash
./bin/mise run test
./bin/mise run lint
./bin/mise run format-check
./bin/mise run build:app
```

Expected: tests pass, lint clean, formatting clean, the macOS app target builds (it links four of the five migrated
targets).

- [ ] **Step 5: Commit**

```bash
git checkout -- Package.resolved
git add .swiftlint.yml Sources/ReachyKit/AGENTS.md CLAUDE.md
git commit -m "chore(json): refuse a bare JSON coder outside ReachyJSON"
```

---

## What is deliberately not in this plan

- **The generated OpenAPI client.** No injection point exists; see ADR 0004.
- **`SetTargetClient` and `ReachyKitError`.** Both use `JSONSerialization` for stated reasons and are excluded from
  the lint rule's intent by not matching its regex.
- **Adopting swift-yyjson.** Refused with measurements in ADR 0004. `JSONCodecFreeFormTests` is what a future attempt
  runs first.
- **A `ReachyDesign` migration.** That target has no JSON.
