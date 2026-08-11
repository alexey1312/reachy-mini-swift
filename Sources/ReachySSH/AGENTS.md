# ReachySSH

SFTP to the robot, for the files the daemon API deliberately cannot reach. Foundation + Citadel, no UI imports,
Swift 6 strict concurrency.

**Why this is its own product and not a corner of `ReachyKit`.** `ReachyWidgetUI` depends on `ReachyKit`, and the
widget extension links `ReachyWidgetUI`. SSH inside `ReachyKit` would make a process woken for a moment to draw two
lines of text link SwiftNIO. Same argument the repository already made for `ReachyMedia`, applied to a different
dependency. `ReachySSH` knows nothing about robots either: host, port and credentials arrive as values, the way a
Hugging Face token reaches `ReachyKit` from `HuggingFaceAuth`.

## What is deliberately absent

- **No `exec`, no PTY.** The daemon already tails `journalctl` (`/logs/ws/daemon`, `LogStreamClient`) and already
  restarts itself and its apps (`POST /api/daemon/restart`, `/api/apps/restart-current-app`). Adding a command
  runner here would duplicate a supported surface and put robot control on a path that bypasses project rule 2.
  It also settles the question of whether `pollen` has passwordless `sudo`: it does not matter, nothing needs it.
  - **`SystemMetricsReader` is not a hole in that rule, and it is what keeps one from being needed.** Processor,
    memory and temperature exist in no daemon route at all — `psutil` is installed on the robot and used only to
    manage processes and list interfaces — so the obvious next request is `top`, `free`, `vcgencmd`. Reading
    `/proc` and `/sys` answers all three as **file reads**, which is what this layer already does. What that
    cannot reach stays unreachable rather than becoming a reason to add `exec`: **free disk space**, which needs
    the `statvfs@openssh.com` extension, and Citadel's `SFTPMessage` has no outbound `extended` case at all.
- **No text editor.** Editing is download → change on the device → upload over the same path, so `write` truncates
  and creates. That is why the upload flow has to offer "replace this file" and not only "add a file here".
- **No recursion.** `remove` picks `remove` or `rmdir` from the entry's kind, and `rmdir` refuses a non-empty
  directory. The server's refusal _is_ the guard; do not add a recursive delete.
- **No relay support.** SSH needs a TCP route to port 22, and the Hugging Face relay carries WebRTC (ADR 0003).
  `RobotSession.address` answers nil for a remote session, which is what closes the feature.

## Citadel, and the four things it made us do

Pinned `.upToNextMinor(from: "0.9.2")` — it is pre-1.0, where a minor bump is a breaking change, unlike the `from:`
every other dependency uses. It resolves **`Joannis/swift-nio-ssh`, a fork**, not Apple's `swift-nio-ssh`: the
fallback "just use swift-nio-ssh directly" is not a drop-in, and this fork is one person's.

Adding it also introduced **four `ld:` warnings that are not ours and cannot be fixed here**:
`building for macOS-11.0, but linking with dylib '/usr/lib/swift/libswiftCore.dylib' which was built for newer
version 13.0`, ×4. They come from `CitadelServerExample`, an executable target inside Citadel that `swift build`
compiles along with everything else, and from `ColorizeSwift`, which declares no `platforms:` at all and so falls
back to SwiftPM's ancient default. `mise run build` still reports `status: success` and CI has no
warnings-as-errors policy. Do not go hunting for them in this target — there is nothing here to change.

1. **`extension SSHClient: @retroactive @unchecked Sendable {}` is required, not tidying.** Citadel marks the
   `SFTPClient` it hands out `Sendable` but not the `SSHClient` that opened it, though both are driven through the
   same NIO `Channel`. An `SSHClient` built inside an `async` function is therefore task-isolated and **cannot be
   stored anywhere shared at all.** Measured, not guessed — all three alternatives fail:
   | Attempt                                                                                                           | Diagnostic                                                                  |
   | ----------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
   | actor stored property                                                                                             | `sending 'client' risks causing data races`                                 |
   | `nonisolated(unsafe) var client`                                                                                  | same — the diagnostic lands on the _local_, not the property                |
   | `Mutex<SSHClient?>`                                                                                               | `'inout sending' parameter '$0' cannot be task-isolated at end of function` |
   | If Citadel ever declares the conformance itself this becomes a duplicate-conformance build error. Loud, one line. |                                                                             |
2. **Pass `MultiThreadedEventLoopGroup.singleton` to every `connect`.** Citadel's default parameter is
   `group: MultiThreadedEventLoopGroup = .init(numberOfThreads: 1)` — a fresh group per connection — and `close()`
   closes the channel without shutting the group down. `SSHClient` has no `deinit` at all. So the default leaks one
   thread per reconnect, and a flaky LAN reconnects a lot.
   **Whoever owns a session must close it.** Because there is no `deinit`, a released owner leaves a live TCP
   connection to the robot and a NIO channel behind — one per visit to whatever screen opened it, for as long as the
   app runs. `RobotFilesModel` does this from its own `deinit` (`Task { await files.disconnect() }`, with `files`
   bound first so the closure never captures `self`), chosen over `.onDisappear` because it fires exactly when the
   last reference goes. Any future owner needs the same.
3. **Open the SFTP subsystem once per connection.** `openSFTP()` costs a child channel plus a round trip and logs
   its own warning about "too many SFTPClient handles". `SSHFileSystem` holds the one it opened. `connect` is
   single-flight for the same reason: the actor is reentrant across the handshake's suspensions, so a second call
   joins the attempt in flight rather than racing it — the loser of that race was a live `SSHClient` overwritten
   unclosed. `disconnect()` cancels the attempt, and the handshake checks for that before publishing its result.
4. **TOFU is two connections, because it has to be.** `validateHostKey` must resolve an `EventLoopPromise` during
   the handshake; there is no way to suspend it while a person reads a fingerprint. So `TOFUHostKeyValidator`
   **records the offered key and refuses**; `mapConnectFailure` reads that record — not the thrown error, which NIO
   wraps — to tell `hostKeyUnknown` from `hostKeyChanged`. The screen shows it, the user accepts, the key is pinned,
   the second connection succeeds. Citadel's own `InvalidHostKey` is public with an internal initialiser, hence the
   private `HostKeyRefused` sentinel.

## Facts about SFTP this layer encodes

- **There is no field for what kind of thing an entry is.** It lives in the `S_IFMT` bits of `permissions`
  (`0o040000` directory, `0o120000` symlink, `0o100000` file). `RemoteFile.kind(mode:longname:)` reads those and
  falls back to `longname`'s first character — the `ls -l` one — only when a server sent no permissions.
- **`permissions` is a bare `UInt32`.** `RemoteFile.permissionsText` renders `drwxr-xr-x` from it rather than
  reusing `longname`, which is the server's own rendering and varies between implementations.
- **There is no "directory not empty" status code.** OpenSSH answers a plain `failure` and puts the reason in the
  human-readable `message`, so that string is what `map` has to match on. Fragile by nature; it degrades to
  `.transport` rather than lying.
- `accessModificationTime.modificationTime` is already a `Date`, not the `UInt32` the wire format carries.
- `.` and `..` come back in every listing and are filtered here, once, rather than in each screen.
- **`readAll()` cannot read `/proc`, and it fails by returning nothing rather than by throwing.** Citadel drives its
  read loop from `attributes.size` (`SFTPFile.swift:99`) — `while readableBytes > 0` — and every entry under `/proc`
  and `/sys` reports a size of **0**, because the kernel generates the contents at read time and does not know the
  length in advance. The size is _present_ and zero, not absent, so the `else` branch that reads until EOF is never
  taken: the loop body runs zero times and the caller gets an empty buffer for a file that has plenty in it.
  `readPseudoFile(_:)` is the size-independent form — `file.read(from:length:)` forward until the server answers
  short, which is the only end-of-file SFTP offers (Citadel turns an EOF status into an empty buffer rather than
  throwing). It is bounded at 256 KiB because nothing can check a size first, and `/proc/kcore` is the machine's
  entire address space while also claiming to be empty.
  - **Confirmed against a real Reachy Mini Wireless.** `stat` on the robot reports `/proc/meminfo size=0`,
    `/proc/stat size=0`, `/proc/uptime size=0` — while `sftp pollen@robot:/proc/meminfo` retrieves **1149 bytes**.
    So the server does serve the contents on a sized `READ`, and OpenSSH's own client reaches them by reading
    forward rather than by trusting the size, which is exactly the strategy here. Anything driving `readAll()` at
    those paths gets an empty buffer and no error.
  - **`/sys` is not `/proc` in this respect**: `/sys/class/thermal/thermal_zone0/temp` reports `size=4096`, so it
    would survive `readAll()`. Only procfs reports zero. Both go through `readPseudoFile` regardless — one path
    for "the kernel made this up at read time" is simpler than remembering which half lies.

## Reading the robot's own vitals

`LinuxSystemSnapshot` + `LinuxProc` (parsers) + `SystemMetricsReader` (the five reads and the state between them).
Four facts about Linux that the parsers encode and that a reviewer should not "simplify" away:

- **`iowait` is idle time.** It sits beside `idle` in `/proc/stat` and means the core had nothing to run. Folding it
  into the busy side is the classic way to report 90% CPU on a machine that is only waiting on a disk.
- **`guest` and `guest_nice` are already inside `user` and `nice`.** Summing the whole `cpu` line double-counts them.
  Only the first eight counters are added, which is why the code says `.prefix(8)` rather than summing everything.
- **`MemFree` is not free memory.** Linux spends every spare page on cache and hands it back on demand, so free is
  alarmingly small on a healthy machine. `MemAvailable` is the one that means anything; reading the other reports a
  robot at 77% memory pressure while it idles.
- **A percentage needs two samples**, so the first reading of a session carries none. A reboot between two samples
  resets the counters, and subtracting `UInt64`s the wrong way round **traps** rather than going negative — hence the
  explicit backwards check rather than a `max(0,)`.

The thermal zone is found by reading each zone's `type` and matching `cpu`, not by assuming zone 0: the index follows
device tree order, and a board with a PMIC or disk sensor ahead of the processor would report that sensor's
temperature as the CPU's. The answer is cached, including the "this machine has none" answer, so the scan's ten round
trips are paid once per session rather than every five seconds.

## Credentials and keys

Both live in the Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, in the shape
`KeychainHFTokenStore` established — written against `Security` directly, because the whole surface is three calls
and a dependency holding a credential is one more thing to audit.

- **Keyed by the robot's hardware id, never by its address** (project rule 4). A robot moves between networks; its
  host key does not. `RobotIdentity.hardwareID` is nil on the simulator, so callers pass `deduplicationKey`.
- **The pinned key is stored as its OpenSSH text line**, not as an opaque blob:
  `String(openSSHPublicKey:)` ⇄ `NIOSSHPublicKey(openSSHPublicKey:)` is a documented round-trip, and a layout that
  belongs to a dependency has no business in a Keychain item.
- **`KeychainSSHCredentialStore` stores username and password only.** Host and port are the session's business; a
  remembered address is exactly the mistake rule 4 warns about, so `credentials(forRobot:)` returns an empty host
  for the caller to fill.
- **The fingerprint needs no SwiftNIO.** The base64 field of an OpenSSH line _is_ the SSH wire encoding, which is
  what OpenSSH hashes, so `HostKeyFingerprint` is Foundation plus one SHA-256 — and its tests use vectors from
  `ssh-keygen -lf`, not from this code. A trailing comment is dropped, or one key would pin as two.

## Defaults, and why they are only defaults

Reachy Mini Wireless ships with OpenSSH enabled, user `pollen`, password `root`. `SSHCredentials.defaultUsername`
offers the username as a prefill. Never assume the password: a user who takes the advice to change it must still be
able to connect. Say so on the screen.

## Testing

`Tests/ReachySSHTests` covers only what is pure — fingerprints, the mode→kind mapping, permission rendering, path
joining, error classification. There is **no integration test against a live SSH server**, and the cheap way to
exercise the real actor is to enable Remote Login on the Mac and point the app at it: that is a genuine OpenSSH
server for the price of a checkbox. `PreviewFileSystem` (in `Preview/`, `#if DEBUG`, the same convention as
`ReachyKit/Preview/PreviewRobotClient`) is what previews and the UI model's tests run against; it records calls in
order, so "did it even ask?" is assertable. It is here rather than in `ReachyTestSupport` so no other test target
links SwiftNIO.

`PreviewFileSystem.brokenPersonality()` is the 2026-08-07 incident as a fixture: `user_personalities/Test_Ru` in
the old four-file format with no `profile.md`. Keep it broken — it is the state the feature exists for.
