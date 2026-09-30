# ADR 0003: Remote access over the Hugging Face relay

- Status: Accepted
- Date: 2026-08-05
- Amended: 2026-10-01 — "Decision: a robot signs itself in with a device code"

## Context

Everything before this was a LAN client. `RobotBrowser` finds robots over Bonjour, `RobotConnection` dials an address,
and a robot on another network simply does not exist as far as this app is concerned. ADR 0001 made that a security
position as well as a limitation: the daemon has no authentication and no encryption, so v1 supports a trusted private
network or the robot's own access point and nothing else.

Two things then arrived at once. The daemon grew an app store whose catalogue includes private Hugging Face Spaces,
which needs an account to read. And upstream shipped a central relay: the robot, given a token, registers itself with
a Hugging Face service and becomes reachable from outside its network.

That turns one question into three. Whose account is it. What does the relay actually carry. And what, honestly, can
a robot do when it is reached that way.

## Decision: the Hugging Face account belongs to this app, not to the robot

`HuggingFaceAuth` is its own target and nothing in it knows what a robot is. `ReachyKit` does not depend on it; a
token reaches the robot as a value the UI passes in.

Sign-in is a **public OAuth client with PKCE** — a client with no secret, which is what Hugging Face calls a public
app. A secret shipped inside an app is not a secret, and PKCE is what stands in for one. The same protocol the daemon
uses for its own browser flow, against the same endpoints.

The `client_id` is committed in `HFOAuth.swift` rather than hidden. It travels in the authorize URL of every sign-in,
so it identifies rather than authenticates; the daemon likewise carries its own as a constant in
`apps/sources/hf_auth.py`. What binds the flow to this app is the registered redirect — Hugging Face answers `400` to
any redirect it does not know, verified against the live service — and PKCE, which makes an intercepted code useless
without a verifier that never leaves the device. A fork registers its own app; `HFOAuthConfiguration.unregistered`
keeps that a real, tested state, where the browser button is absent rather than broken and the pasted-token path still
works.

Presentation is `ASWebAuthenticationSession`, non-ephemeral on purpose: it runs the page in Safari's own context, so a
user already signed in to the Hub is one tap from done, and this app never sees the page, the password or the cookies.

Linking a robot hands it a **copy** of the token. Signing out of this app deliberately does **not** unlink the robot: a
robot left reachable with a token its owner believes they revoked is the one outcome worth going out of the way to
prevent, so unlinking is its own explicit action.

## Decision: a robot signs itself in with a device code

Amendment, 2026-10-01.
Copying this app's token to the robot had two costs the section above accepts rather than removes:
the token crosses the local network over plain HTTP,
and the robot receives an access token with nothing to renew it,
so it drops off central when that copy expires.
Daemon 1.10.0 mounts a device-code flow (`/api/hf-auth/oauth/device/*`, pollen-robotics/reachy_mini#1223)
that removes both.

- **From 1.10.0 the robot links itself.**
  It asks the Hub for a code, this app shows the code and opens the approval page,
  and the robot polls the Hub over HTTPS until it holds a token of its own — with a refresh token behind it.
  This app never sees a token, and none crosses the local network.
- **No sign-in in this app is needed for it.**
  The approval happens in the browser, with whichever account the robot should hold.
  The two custody points stay apart, now by construction rather than by a copy.
- **`save-token` stays for 1.9.x**, which does not mount the routes,
  together with the footer that says the hop is unencrypted.
  The choice is made on the daemon's version, withheld only on evidence like every other gate,
  and a 404 is still reported rather than assumed away.
- **Daemon 1.12 signs every robot out once** (pollen-robotics/reachy_mini#1367):
  it moves to a credential store of its own with no migration,
  so a robot linked on 1.11 reads as unlinked after the update and leaves central.
  The card says so on a robot known to run 1.12 or later.
  Relinking needs the local network, so a robot updated remotely cannot be brought back remotely.

## Decision: the relay carries signaling, not robot data

`CentralRelayClient` speaks the relay as it is: a long-lived `GET /events` server-sent-event stream for inbound
messages and `POST /send` for outbound ones. It announces itself as a listener before reporting the connection,
because central evicts peers with no recent inbound traffic and the name sent there is what the robot's owner sees
holding their robot.

Everything past the handshake is a **WebRTC session negotiated through that stream**, so `CentralSignalingTransport`
implements the same signaling seam `CameraSession` already used on the LAN. Once the peer connection is up, robot
data flows peer-to-peer. Hugging Face brokers the introduction; it does not carry video, audio or commands.

## Decision: the data channel is the remote control surface

The daemon's HTTP API is not reachable from outside the robot's network. The same commands arrive instead as JSON on
the reliable `"data"` channel of that peer connection.

**The wire has no request ids.** Most commands are answered by echoing the name back, but five answer with a bare
payload and no name at all — `get_version`, `get_hardware_id`, `get_state`, and both motor-mode commands, which reply
under `motor_mode`. A reply can therefore only be attributed by something the caller supplies, which is what
`RemoteControlChannel.Correlation` is: either the echoed command or a named reply key. Two commands sharing a token
are serialised rather than guessed at — correct for the motor-mode pair, where nothing on the wire tells them apart.

Unsolicited broadcasts share the channel — joint positions at 50 Hz, move progress, update log lines — and every one
of them names a `type`, which no reply ever does. That is the whole discriminator between `{"state": …}`, an answer,
and `{"type": "daemon_status", …, "state": …}`, which is not.

`daemon_status` is **assembled rather than fetched**. The daemon publishes it once a second, but `_publish_status`
calls `ws_server.publish_status` rather than broadcasting to data-channel clients, so it never arrives and no command
asks for it. `RemoteRobotConnection` builds one from `get_version` and `get_hardware_id`, carries the robot's name in
from the central listing, and sets the fields it cannot know to values that _close_ a feature rather than open one.

Nothing on this channel promises a deadline, so the channel imposes one. A caller left awaiting forever is worse off
than one told the robot went quiet.

## Decision: a remote session is an honest subset, not a facade

`RemoteRobotConnection` conforms to the same `RobotAPIClient` as the LAN path, so `RobotSession` and every screen above
it are unchanged — which is what let `RobotSession.connect(using:)` exist at all: a session that cannot dial an
address, because by the time the client arrives it is already talking to the robot.

Everything the channel does not carry is left on the protocol's throwing defaults rather than stubbed out. Moves, URDF
and kinematics, `/wifi`, `/update`, and renaming are HTTP-only, and asking for them here fails rather than lies. The
UI reads those refusals as capabilities: `supportsRename` is answered `false`, so the name field is greyed out instead
of failing on save.

The 3D scene is the visible casualty. It is built from URDF and STL served over the daemon's HTTP API, which is
exactly what a remote session cannot reach. The camera, by contrast, comes free — it is the same peer connection.

## Consequences

- A robot is reachable from anywhere its owner's account can see it, with no port forwarding and nothing exposed
  publicly. ADR 0001's position is unchanged: port 8000 is still LAN-only, and this path does not open it.
- `runningMoveUUIDs()` returns an empty set by construction rather than by guess — this connection never hands out a
  move id — which is what lets `waitForMoveToFinish` return at once instead of sitting out its whole timeout.
- Access tokens expire (the OAuth app sets the lifetime). Renewal is handled where a refresh token is issued;
  otherwise the user signs in again, which Safari's cookies make close to instant.
- **The full chain has no automated test.** Both ends are covered — `CentralRelayClient` and `CentralSignalingTransport`
  against stubbed HTTP, `RemoteControlChannel` and `RemoteRobotConnection` against scripted channels — but the joint
  between them needs a live `RTCDataChannel`, which does not exist outside a real peer connection, and `ReachyMedia`
  has no test target. `RemoteRobotLink` and the root view's wiring are therefore verified by hand, on hardware.
- `sim-daemon` cannot stand in for central, so none of this is exercised by `test:sim`.
- Browser sign-in was verified end to end on device: authorize page, consent, callback, and the account named in the
  app afterwards.
