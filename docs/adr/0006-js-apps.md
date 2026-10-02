# ADR 0006: Hosting JS apps — a narrow token, a page of its own, and the robot handed over

- Status: Proposed —
  the decisions below stand,
  and the questions marked **Open** are measured with the prototype on a robot before this is Accepted
- Date: 2026-10-01
- Issue: #159, closed on 2026-10-02 with the run on a robot still to do;
  **What a run on a robot has to answer** below is the tracker from here on

## Context

On 2026-09-30 Pollen made JS apps the default path for Reachy Mini apps
([From Python to JavaScript](https://pollen-robotics.com/reachy-mini/blog/from-python-to-js/)).
A JS app is a web page served from a Hugging Face Space,
and it opens its own WebRTC session to the robot through central.
Python apps "are not going away",
but they are installed through the desktop app and sit behind a filter.
Pollen's mobile app hosts JS apps and nothing else,
and it moved teleop and the camera into one of them, Telepresence.

Our Apps tab lists the Python catalogue only —
the daemon's own over the LAN, and the Hub's over the relay since #158 —
which is the half Pollen stopped promoting.

### What hosting means upstream

Read as a specification (project rule 1) from
`pollen-robotics/reachy_mini_mobile_app@1eeef20b` and `pollen-robotics/reachy_mini@551679dd`:

- **The catalogue** is `GET https://pollen-robotics-reachy-mini-api.hf.space/api/js-apps`,
  public, uncredentialed, `max-age=60`, already moderated:
  every entry it returns is `mobile_visible` and not blocked.
  Measured on 2026-10-01: 69 apps out of 91 moderated, 62 `static` and 7 `docker`,
  two of them official.
- **The address** is the Space's runtime host —
  `<slug>.static.hf.space` for a static Space, `<slug>.hf.space` otherwise,
  the slug being the repository id lower-cased with `_` and `/` turned into `-` —
  with `embedded=1` and a theme in the query,
  and the credentials in the **fragment**:
  base64 of a JSON object, percent-encoded (`buildEmbedUrl.ts`).
- **The credentials** carry the user's Hugging Face token, the user name,
  the robot's central peer id and hardware id, the signalling URL and the theme.
  The page's SDK reads them, wipes the fragment,
  and keeps the token in `sessionStorage` (`ts/host/src/embed/index.ts`).
- **Protocol v1** is `postMessage` between page and host,
  every message carrying `source: "reachy-mini"` and `version: 1`.
  No message carries a secret; the token travels in the fragment alone.
- **The hand-over**: the mobile app releases its own session before showing the app
  and takes it back afterwards, without waking the robot.
  Central admits one session per robot,
  and the daemon refuses a second central session.

## Decisions

### 1. A web app gets a token for `openid profile`, minted for it, held in memory

**Upstream hands every app the account's whole token**:
`openid profile read-repos write-repos manage-repos inference-api` (`oauthLoopback.ts`).
Ours asks for the same five (`HFOAuthConfiguration.reachyMiniScopes`),
so following upstream would give a page from a stranger's Space
the power to rewrite or delete every repository its reader owns —
and the SDK leaves that token in `sessionStorage`, where any script on the page can read it,
as Pollen's own cameraman app does.

**Central needs `openid profile` and nothing more.**
A standalone Space mints exactly that for its own sign-in,
and central validates a token by asking the Hub who it belongs to (`whoami-v2`).

So hosting uses a **second authorization of the same OAuth client**,
for `openid profile` alone (`HFOAuthConfiguration.reachyMiniWebApps`).
The token lives in an `InMemoryHFTokenStore` owned by whatever asked for it —
never the Keychain beside the account's —
and the web view runs on a non-persistent data store,
so the copy the page keeps dies with the page.
Safari's session makes the second authorization a consent, not a password.

Apps whose card declares more (`hf_oauth_scopes`) are not hosted:
four did on 2026-10-01, among them `marionette-js`, which asks for `write-repos` and `manage-repos`.
They are listed as needing more access than this app gives a web page,
with a way to open them on Hugging Face instead.

This changes an invariant `AppSettingsScreen` states —
that this app never holds a Hugging Face credential in a web view.
It now never holds **the account's** credential in one.

- Considered and not taken: **narrowing through the refresh grant**
  (RFC 6749 §6 allows a refresh request to ask for fewer scopes),
  which would spare the second consent.
  The Hub rotates refresh tokens,
  so spending the account's own for a narrow one risks knocking the account into `needsReauth` —
  the race `HFAccount.renewal` exists to prevent.
- Considered and rejected: **the account's own token, as upstream does.**
- **Open:** that central accepts a token issued to this client for `openid profile`.
  Expected, since it validates by `whoami-v2`, and measured by step 1 below.

### 2. Two catalogues with two different reaches, on one tab

A JS app needs a Hugging Face account, central, and the robot's relay switched on.
A session over the LAN does not stop it running —
the page reaches the robot through central whatever path this app is on —
but a robot that is not linked to the reader's account, or whose relay is off, cannot run one at all.

The Apps tab gains a second section, **Web apps**, beside the robot's own.
It is never hidden:
when one of the three conditions is missing it says which,
because a section that appears and disappears with the relay
reads as a store that lost its apps.
The robot is found on central by hardware id, never by name or address (project rule 4).

### 3. The robot is handed over, and taken back only once the page has let go

Central admits one session per robot (`robot_busy`),
and the daemon refuses a second central session (`robot_busy_local`, `robot_busy`).

- **Over the relay** this app's session is ended before the page loads,
  and dialled again once central lists the robot free.
- **Over the LAN** there is no central session of ours to end.
- **Closing is never a swipe.**
  The host posts `host:leaving`; the page puts the robot to sleep, stops its session and answers `embed:left`;
  the host tears the page down then, or after 9.5 s,
  the reference host's own bound (`useHostBridge.ts`).
  A page that never reached the robot is let go at once.
- **The shipping version keeps the shell up while the robot is lent.**
  The prototype reconnects through the connect gate, visibly, because how long that takes on a real robot
  is what decides whether a dedicated `RobotSession` phase is worth its cost.
  The expectation is that it is, since the gate is a full-screen change on every app closed.
- **Answered from the daemon's source, and not yet on a robot**
  (`reachy_mini` 1.11.0: `daemon/robot_app_lock.py`, `media/central_signaling_relay.py`, `apps/manager.py`).
  - `robot_app_lock` serialises two things and only two: central sessions and local Python apps.
    A LAN client takes no part in it, the camera's WebRTC session included,
    so the page's central session is admitted beside a LAN camera,
    and `webrtcsink` gives each consumer a session of its own.
    Whether the robot's CM4 encodes two streams at once is what a robot adds.
  - The gate underneath the page **does** reconnect over the LAN when the robot is on the same Wi-Fi:
    `CandidateSweep` starts dialling the moment `ConnectionScreen` appears,
    and the daemon admits it for the same reason.
    That settles it for the shipping phase,
    which has to keep the sweep from dialling while the robot is lent.
  - While a Python app runs, central admits the page as a **control-only** session:
    it drives the robot over the data channel, takes no lock, and the app keeps the slot.
    The other way round depends on the door.
    `POST /api/apps/start-app/{name}`, which this app's LAN Apps tab calls, evicts the page with `endSession`;
    `apps.start` over the data channel keeps the session that asked;
    and the startup app's no-evict start is refused while the page holds the slot.
- **The hand-over has fifteen seconds.**
  A session ended on purpose frees the slot with `expect_handoff`,
  and the daemon then waits `IDLE_RESET_HANDOFF_GRACE_S`, 15 s, before putting the robot to sleep —
  1.5 s after a drop.
  The page's session taking the slot cancels it.
  The prototype spends that window waiting for central to list the robot free (up to 20 s),
  loading the page, and letting the page set up its own WebRTC session,
  so a slow hand-over shows as the robot going to sleep and the page waking it again.
  How much of the fifteen is left is a number step 2 reads off a robot.

### 4. Report, hide the author, and consent — for both catalogues

Upstream ships the three things App Review guideline 1.2 asks of user-generated content:
"Report this app" opens the Space's own report form (`?report=true`),
"Hide apps from {author}" is a local list,
and a versioned consent names third-party apps before the first one opens.
The kill switch is server-side, in the moderation the catalogue already applies.

All three come before web apps leave the flag —
and the Python store owes the same three,
since it too lists Spaces written by strangers.
`JSApp.reportURL` is the link.

**The Python store has them now**, and the web apps inherit them rather than build them again.
`HubSpacePage` builds the page and report links for both catalogues;
`AppModerationStore` keeps the hidden authors and the version of the notice agreed to,
per device rather than per robot.
In the store, Discover is what is moderated —
the notice stands in front of it on the first visit,
and a hidden author's cards leave it —
while Installed is left alone, because hiding there would strand an app on the robot
with no page to remove it from.
Report is on every page with a Space id.
What web apps add is a **bump of `noticeVersion`**:
their notice has to say that the page receives a Hugging Face sign-in,
which the Python store's does not.

### 5. The page is loaded on its own in a `WKWebView`, not in an iframe of ours

There is no page of ours to put an iframe in,
and the SDK already handles a page loaded on its own:
seeing `window.parent === window`, it resolves its credentials from the fragment at once
rather than waiting for `host:init`,
and posts its protocol to its own window (`awaitHostInit`, `postToHost`).
A script injected at document start listens there
and forwards `embed:*` to a script message handler (`JSAppHostBridge`);
host messages go back through `evaluateJavaScript("window.postMessage(…)")`.

**Measured on 2026-10-01, on macOS, against the live Hello World Space**
with made-up credentials (`JSAppHostLiveTests`):
`embed:ready`, then `embed:app-state` `connecting`/`link`, two `embed:debug`,
then a fatal `embed:error` reading `Error: HTTP 401` — the Hub refusing the made-up token,
which is as far as such a run can go.
So the page booted from the fragment with no `host:init`,
its messages reached Swift through the bridge,
and `window.location.hash` no longer held the credentials afterwards.

**The same on iOS, measured on 2026-10-02** in an iPhone 17 Pro simulator on iOS 27.0.
The test now compiles wherever WebKit does,
and `xcodebuild test` reaches the iOS half that `swift test` cannot (its doc comment has the line).
It passed in 11 s:
`embed:ready`, the page moving on without `host:init`, and the fragment wiped.

- **A non-persistent data store**, so nothing one app stored is there for the next.
- **The Space's origin and nothing else** for the page itself;
  every other link, and every `window.open`, goes to the system browser.
- **The microphone may be asked for, from the app's origin; the camera never.**
  Telepresence speaks through the phone's microphone.
  This app's camera usage string promises it never records with the phone's camera,
  and a page does not get to break that for it.
- **The same code on macOS**, whose sandbox already carries `network.client` and `device.audio-input`.
- Pollen's save-file bridge exists for Android, which has no `navigator.share`;
  it is not built here.

## The prototype

Settings → Advanced → **Web apps**, compiled in `DEBUG` only, so it ships to nobody.
It is laid out as an instrument rather than a store:
the narrow sign-in, the robot as central lists it through that sign-in, and the catalogue with each app's SDK and
declared scopes, each on its own row so a run can say which one failed.

- `Sources/ReachyKit/JSApps/` — `JSApp`, `JSAppCatalogue`, `JSAppEmbed`, `JSAppHostProtocol`.
  Pure, always compiled, unit-tested against the shapes measured on 2026-10-01.
- `Sources/HuggingFaceAuth/HFOAuth.swift` — `HFOAuthConfiguration.reachyMiniWebApps`.
- `Sources/ReachyUI/JSApps/` — the bridge, the web view, `JSAppHostModel`,
  the full-screen host and `RootJSAppHost`, which is mounted on the root above the gate and the shell,
  because ending the relay session throws the shell away.
- `JSAppHostLiveTests` loads a real Space in a real `WKWebView` with made-up credentials
  and checks that the page boots from the fragment and that its messages reach Swift.
  It is gated on `REACHY_JS_APP_LIVE`, the way `SimulatorIntegrationTests` is gated on `REACHY_SIM_HOST`.

### What a run on a robot has to answer

1. **Authorize web apps**, then **Through central** lists this robot:
   central accepts the narrow token (decision 1).
2. Over the relay, open **Reachy Mini Hello World** (`tfrere/reachy-mini-sdkjs-demo-static`, static, no
   microphone, no camera): the page reaches `live`, the antennas move,
   **Close** brings `embed:left` inside 9.5 s with the robot asleep,
   and this app reconnects — how long the gate is on screen is the number decision 3 is waiting for.
3. Over the LAN with the camera streaming, the same app: does the page get its session (decision 3's open question)?
4. **Telepresence** (`pollen-robotics/telepresence`, docker): the microphone prompt, and audio through the robot.
5. Steps 2 and 4 on a Mac.

Safari's Web Inspector attaches to the page in `DEBUG` builds.

**What a simulator can stand in for, checked on 2026-10-02.**
`mise run sim-daemon` registers on central by itself when the Mac holds a Hugging Face token
(`huggingface_hub.get_token()`):
it logged `Remote access enabled as 'reachy_mini'` twenty seconds after it started.
So the first half of step 1 runs against it —
central answering the narrow token with a listing rather than a refusal is decision 1's measurement,
and with the simulated robot online that listing should not be empty.
What no script can supply is the consent itself, given in the browser by the account's owner.
Steps 2 and 3 cannot use it.
A simulated daemon has no hardware id —
`utils/hardware_id.py` derives one from the Pollen audio board's USB serial and omits it without one —
so central lists it without an id,
and the prototype, which finds and hands over a robot by hardware id alone (project rule 4),
neither finds it nor releases it.
Step 3's question is answered from source under decision 3; a robot only confirms it.
Step 4 needs the robot's own microphone and speaker.

## Consequences

- Rule 8 is waived for the prototype and said so in its doc comments:
  a web view renders nothing headless, and none of it ships.
  The shipping version owes previews for every state around the page —
  the three missing conditions, the hand-over, the leave, and a failed app.
- Leaving the flag costs, beyond that:
  the Web apps section on the Apps tab,
  the consent, report and hide wired to its cards
  (built for the Python store, decision 4, with a `noticeVersion` bump for the token),
  and the phase that keeps the shell up while the robot is lent.
- Nothing about a shipped build changes in this step:
  the ReachyKit half is unreachable from it, and the ReachyUI half is not compiled into it.
