# Bluetooth provisioning and recovery — hardware checklist

Everything the app does over Bluetooth was written against `bluetooth_service.py` in daemon 1.9.0 (read from
`.venv-sim/lib/python3.12/site-packages/reachy_mini/`), against `StubBLETransport` and `FakeBLETransport`, and against
nothing else. **The robot's GATT service is Linux/BlueZ — no simulator can stand in for it**, and the iOS Simulator has
no Bluetooth at all. So none of this is confirmed until a real Wireless unit says so.

**Status: OPEN.** Nothing below has run against hardware yet.

This file is the tracker.
Issue #156 carried the same run and was closed on 2026-10-02 without one,
because nothing in it can be done without a Wireless unit at hand;
the three checks it added are under **Since daemon 1.10** below.
Record each measurement beside its box, the way `.claude/rules/daemon-api.md` records its own.

## Step 0 — the one that gates everything

The sealed `WIFI_CONNECT_ENC` payload runs to roughly 208–260 bytes. At the default iOS ATT MTU of 185 a single write
carries about 182. The robot's `WriteValue` ignores `options["offset"]`, so a value CoreBluetooth splits into ATT
prepare/execute writes arrives as _two separate commands_, not as one reassembled payload. If it does not fit, the
Bluetooth path cannot provision at all and the HTTP path through `reachy-mini-ap` becomes the only one.

The onboarding "Joining" screen prints both figures from the live link, so running setup once answers this:

- [ ] `maximumWriteValueLength(for: .withoutResponse)` — the single-packet budget the pump enforces.
- [ ] `maximumWriteValueLength(for: .withResponse)` — expected to read 512 on every iPhone. It is the maximum
      _attribute_ length, not what survives one packet, which is exactly the trap.
- [ ] A real join with a real password. `ECHO: <fragment>` or `ERROR: Invalid payload (expected JSON)` means the write
      was split and the fallback is mandatory. `OK: working` means it fits.

`RobotConnection` already implements `WiFiProvisioningTransport`, so the HTTP fallback is written and tested; what is
missing in that case is only the screen that sends the phone to the robot's access point first.

## Protocol behaviour to confirm

- [ ] Scanning filtered on the **status** service `…cdef3` finds the robot; filtering on the command service `…cdef0`
      finds nothing (the advertisement carries only the status service).
- [ ] No pairing prompt appears. The robot registers a `NoInputNoOutput` Just Works agent.
- [ ] Characteristics really are registered in reverse order — the client matches by UUID and must not care.
- [ ] `PING` answers on a **read**, with no notification. This contradicts upstream's own documentation and is what
      `BLECommandPump` is shaped around; if a notification does arrive, the pump's ack check still handles it.
- [ ] Three wrong codes lock the robot, the lockout survives a disconnect, and a correct code during the lockout is
      still refused (the robot does not even compare it).
- [ ] How many SSIDs `WIFI_SCAN` actually returns before the 180-byte cap bites. The "Other network…" row is designed
      around this being a small number.
- [ ] `JOURNAL_READ` above ~182 bytes. The robot slices its buffer at 480 characters and **empties what it hands
      over**, so whatever a read cannot carry is gone. Confirm how much is lost, and that `BLEJournalReader` still
      never emits a half line.
- [ ] A wrong Wi-Fi password: the robot comes back on `reachy-mini-ap` within about 60 s and the screen says so.
- [ ] A `kid` older than 600 s is refused as bad credentials and the single automatic retry with a fresh `WIFI_KEYEX`
      recovers it. This is the reason that retry exists.
- [ ] `…cdef7` equals `GET /api/daemon/hardware-id`, so the robot set up over Bluetooth is recognised when it appears
      on the LAN.
- [ ] `…cdef6` lists exactly the scripts in the robot's `commands/` directory, comma-and-space joined, `.sh` stripped.

## Since daemon 1.10

Written against the stubs like everything above, and added from #156.

- [ ] `SET_NAME <name>` on a 1.10+ robot renames it,
      and the new name is what `GET /api/daemon/status` and the relay report afterwards.
- [ ] `SET_NAME` on a 1.9.x robot comes back as `ECHO: SET_NAME <name>`,
      and onboarding says the name waits for Settings rather than reporting a failure.
- [ ] `UPDATE_CHECK PRE` offers the pre-release where plain `UPDATE_CHECK` does not,
      and `UPDATE_START PRE` installs that one.
- [ ] **A reconnect in the middle of the flow asks for the PIN again.**
      The daemon binds the PIN session to the connection that entered it
      (GHSA-993g-hgjh-whmf, merged 2026-09-30, and already in 1.11.0's `bluetooth_service.py`):
      `_on_central_disconnected` zeroes the session on any disconnect,
      and a `CMD_*` must come from the same device.
      `BLEPinSession.invalidate()` already assumes this,
      and `BLEProtocolTests` holds it against the stub
      ("reconnecting always needs the PIN again, even inside the 300 s window");
      what the robot does is the open half.
      Drop the link between the PIN and the Wi-Fi join, reconnect,
      and confirm `WIFI_CONNECT_ENC` answers `ERROR: Not connected. Please authenticate first.`
      until the PIN is entered again.

## Recovery scripts

Run them in this order. The first three are the way back; the last one is the one you cannot undo.

- [ ] `CMD_RESTART_DAEMON` — expect the GATT **write to report an error** even though the script ran: the handler
      returns `None` on success and the robot crashes encoding the reply. Verify by side effect in the journal.
      Confirm the PIN is required again afterwards (the handler clears its own flag in a `finally`).
- [ ] `CMD_HOTSPOT` — the robot leaves the network and raises `reachy-mini-ap`. This is the escape route; confirm it
      works **before** trying anything destructive.
- [ ] `CMD_WIFI_RESET` — every saved network except `Hotspot` is deleted.
- [ ] Confirm the Bluetooth link survives all of the above. `reachy-mini-bluetooth` is its own systemd unit and the
      scripts restart `reachy-mini-daemon`, so it should — the console assumes it.
- [ ] `CMD_SOFTWARE_RESET` — **last, once, and only after checking `/restore/venvs` exists on the robot.** About five
      minutes. Confirm the Bluetooth service keeps answering `PING` throughout (it lives in `/bluetooth`, outside the
      `/venvs` tree being erased) and that the daemon reappears in the journal at the end.

## Update surface

- [ ] A real update from one release back, 10–20 minutes. The socket closing is the completion signal — the daemon
      restarts before it can send a terminal `done`.
- [ ] `pre_release=true` offers a different version from `false`.
- [ ] `available_version: "unknown"` reproduces when the **robot** has no route to PyPI (block its WAN, not the
      phone's), and the app says the robot has no internet rather than that the check failed.
