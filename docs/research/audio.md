# Audio levels and microphone research

Measured on 2026-08-27 against a Wireless unit (daemon 1.9.0, audio board firmware 2.1.2) and
against the vendored daemon source in `.venv-sim`.

> **Re-read on 2026-10-01 against daemon 1.11.0, reachy_mini `main` (1.12.0.dev0)
> and the conversation app's `main` (5eb39ed).**
> The question this time was the other way round:
> the conversation app speaks much more quietly than a call through the same speaker.
> Two claims below are stale and are corrected in place —
> since 1.10.0 there _is_ an `audiodynamic` element on every speaker path,
> part of a level-neutral EQ ([below](#since-1100-one-eq-and-one-clamp-on-every-path)),
> and the robot's microphone profile does not survive the conversation app starting
> ([below](#the-conversation-app-rewrites-the-board-at-every-start)).
> The conclusion is unchanged: nothing on the robot gives one source more gain than another.
> What makes the app quiet is [its source](#the-conversation-app-is-quiet),
> and the one lever left is firmware 2.1.4, which nothing installs for you.
> The robot was not reachable that day, so its board version was not re-read.

> **Daemon 1.10.0 ships audio firmware 2.1.4 — but shipping it is not installing it.** Re-read on
> 2026-09-01 against a Wireless unit already on daemon 1.10.0: its board still answers
> `VERSION → [2, 1, 2]`. So the numbers below still describe that robot, and the way to check any
> other one is a single call:
>
> ```
> curl http://reachy-mini.local:8000/api/audio/config/parameter/VERSION
> ```
>
> Every configured microphone register was re-read at the same time and **none had moved**:
> `PP_AGCDESIREDLEVEL` 0.0045, `PP_AGCMAXGAIN` 64, `PP_LIMITPLIMIT` 0.47, `PP_MIN_NS` 0.15,
> `PP_MIN_NN` 0.51. Only `PP_AGCGAIN` differed (7.996 against 4.93), which is the one this page
> already calls a reading of the moment rather than a setting. The three profiles in
> `AudioParameter.swift` are therefore still right.
>
> What 2.1.4 changes when a board does get it: **+6 dB of maximum speaker output**, which is
> exactly the finding this page is named after — "no headroom either" — so re-measure the speaker
> section then. The microphone side has no reason to move.
>
> The ten-band EQ is not something this app can reach at all: it lives in `daemon_config.json` on
> the robot and needs a daemon restart, with no route to read or write it.

The question: a call sounds much louder from the robot's speaker than a robot app or a move,
"as if a limiter is fitted". Also, does the robot suppress noise, and can it hear better?

## The speaker: no limiter, and no headroom either

**The daemon applies no software gain on any path.** No `volume` or `audioamplify` element
exists anywhere in the package, and `playbin`'s own `volume` property is never set.
(On 1.9.0 there was no `audiodynamic` either;
1.10.0 added one, as the clamp after a level-neutral EQ —
see [the next section](#since-1100-one-eq-and-one-clamp-on-every-path).)
Three paths, one sink (line numbers are 1.9.0's):

| Path                                   | Pipeline                                                                          | Source                             |
| -------------------------------------- | --------------------------------------------------------------------------------- | ---------------------------------- |
| Call (phone → speaker)                 | `appsrc → rtpopusdepay → opusdec → tee → audioconvert → audioresample → alsasink` | `media/media_server.py:459-535`    |
| `play_sound` (moves, wake, soundboard) | a new `playbin` per call, into the same tee-bin                                   | `media/media_server.py:1203-1251`  |
| An app on the robot                    | `appsrc(F32LE 16k) → audiomixer → tee → alsasink` in the app's own process        | `media/audio_gstreamer.py:353-448` |

All three end at `alsasink device=reachymini_audio_sink`, the 16 kHz dmix alias from `.asoundrc`
(`media/audio_utils.py:192-230`). The hardware mixer reads 100 on both directions
(`GET /api/volume/current`, `GET /api/volume/microphone/current`).

**So nothing throttles a sound, and nothing can make one louder.** The difference is the level of
the source. Built-in assets are recorded 17 dB apart:

| Asset            | Peak     | RMS       |
| ---------------- | -------- | --------- |
| `go_sleep.wav`   | 0.0 dBFS | −6.8 dBFS |
| `confused1.wav`  | 0.0      | −11.3     |
| `dance1.wav`     | −4.5     | −13.6     |
| `wake_up.wav`    | −12.0    | −21.1     |
| `count.wav`      | −12.8    | −22.9     |
| `impatient1.wav` | −15.5    | −23.9     |

A voice on a call arrives compressed and near full scale, because the phone runs it through the
system voice-processing unit (`mode: .videoChat`, `MediaAudioSession.swift:74`) and then through
libwebrtc's own gain control. A 16 kHz dmix rate also cuts everything above 8 kHz, which makes a
move's music sound duller than it is.

**The only control is on the phone**, and that is what `CameraSession.micVolume` is: it scales
this device's voice before the robot plays it. The robot cannot come up to meet the call, so the
call comes down to meet the robot.

### Since 1.10.0: one EQ and one clamp, on every path

reachy_mini #1267 (merged 2026-07-20, released in 1.10.0) put a `speaker_eq` bin on the speaker branch
of all three paths:
F32 caps → `equalizer-10bands` → `audiodynamic` (`threshold 0.9`, `ratio 0.0`) → `audioconvert`
(`media/audio_base.py:51-100` in 1.11.0).
It is inserted identically on the call (`media/media_server.py:602`),
on `play_sound` (`:1498`)
and on an app's own playback (`media/audio_gstreamer.py:324,399`),
after the wobbler tee, so head motion still follows the uncorrected signal.
It is skipped entirely when every gain is zero
or when the output is not the Reachy Mini Audio device.

`ratio 0` makes the `audiodynamic` a hard clamp at 0.9 (about −0.9 dBFS),
there to stop the EQ's boosts clipping at the final integer conversion.
It is memoryless, so it clips rather than compresses:
a source already near full scale — a call — gets more clipped, not louder.

The default gains correct the head shell's "boxy" resonance (`media/audio_utils.py:34-45`):

| Band (Hz) | 29 | 59     | 119   | 237   | 474   | 947  | 1889 | 3770 | 7523 | 15011 |
| --------- | -- | ------ | ----- | ----- | ----- | ---- | ---- | ---- | ---- | ----- |
| Gain (dB) | 0  | −13.21 | −5.55 | −4.28 | −4.32 | 5.80 | 4.65 | 4.90 | 3.41 | 0     |

The calibration tool (`tools/speaker_eq_calibration/calibrate.py`) re-centres the gains on their median,
so the EQ adds no broadband level by design — the median of the defaults is exactly zero.
It moves energy out of the low mids and into 1–7.5 kHz,
which may help intelligibility a little and cannot make a quiet source loud.

The gains are `speaker_eq_gains` in `daemon_config.json`, ten numbers in −24…+12, and **no route reads or writes
them**. The 2026-09-01 note above says a change needs a daemon restart; the source suggests otherwise —
the file is read afresh each time a pipeline is built (each call, each `play_sound`, each app's audio init) —
but that is inferred, not tried.

## The conversation app is quiet

This is the same finding from the other side, and it has the same cause: the level of the source.

- **The app plays the model's audio exactly as it arrives.**
  Its only backend is Hugging Face's realtime server (OpenAI and Gemini went in conversation-app #444),
  asked for native 16 kHz PCM.
  `play_loop` (`console.py:886-929` on its `main`) decodes each delta as `int16`,
  divides by 32768 (`streaming.py:48-54`) and calls `push_audio_sample`.
  No multiplier, no clip, no normalisation, no resampling.
  `_LEVEL_GAIN = 6.0` in the same file scales only the `conversation.level` meter, never the audio.
- **The SDK adds nothing either.** `MediaManager.push_audio_sample` duplicates mono to stereo and wraps the bytes;
  from there it is the app path in the table above, `speaker_eq` included.
- **A call is the loud one because the phone compresses it**, as the section above says.
  So the call-gain slider can only bring a call down to the app's level;
  nothing on the client can bring the app up to the call's.
- **This client already receives a reading of the app's level.**
  `conversation.level` for `assistant` is RMS × 6, clamped to 1,
  so a meter reading of `r` below the clamp is a raw RMS of `r / 6`, or 20·log₁₀(r / 6) dBFS.
  Comparing that against the table above is the cheapest measurement of "how quiet" there is.

### What upstream has done about it, as of 2026-10-01

Nothing that reaches a robot.

- Conversation-app PR #404 ("audio is boosted", a 0–24 dB output gain with a slider) was closed unmerged on
  2026-06-29 — the maintainer preferred a proper limiter, and the author found firmware 2.1.4 made it unnecessary.
- reachy_mini PR #1187 (`REACHY_AUDIO_GAIN_DB`, a `volume` plus `rglimiter` on all three paths) was closed unmerged
  on 2026-07-13, for the same reason.
- reachy_mini #569 ("louder sound") is still open.
  One comment there (2026-05-29) says Gemini's realtime voice was much louder by itself than OpenAI's,
  which is the same source-level story, and moot now that the app speaks only Hugging Face.
- reachy_mini #844 was closed on 2026-09-15: there is no `mini.media.set_volume()`, and apps are told to use
  `POST /api/volume/set`.
- The conversation app's `main` has a `volume_control` tool the model can call (#555, merged 2026-09-17).
  It drives `/api/volume/*` — the system mixer, already at 100 — and it is not in Space v1.0.1, which is what a
  robot installs.
- **No release after 1.11.0 exists**, and nothing on `main` touches the output path.
  #1373 (open) consolidates the four speaker-branch builders and changes no level.

### Firmware 2.1.4 is the one lever, and nothing installs it

`assets/firmware/` in the daemon package carries v2.1.2, v2.1.3 and v2.1.4 (plus a six-channel 2.1.4),
and 2.1.4 is the newest anywhere.
Its PR (reachy_mini #1242, merged 2026-07-17) says it "increases the max volume by 6dB";
its own `CHANGELOG.md` says "+6dB gain on the audio input".
From the USB device's side the input _is_ the playback stream,
and a tester in the #1187 thread measured louder playback after flashing,
so the two are most likely one claim worded twice — inferred, not measured here.

**Nothing flashes it.** The only caller is `assets/firmware/update.sh`,
which is `dfu-util -R -e -a 1 -D <file>`;
no route, no startup check and no update job runs it,
and the OS image's own check script only reads the version.
Pollen's troubleshooting page answers "low audio volume" with that script.
So upgrading the daemon puts the file on the robot and changes nothing,
which is exactly what the 2026-09-01 note found.

Checking a board is one `GET` (`/api/audio/config/parameter/VERSION`).
Flashing is a shell on the robot; stopping the daemon first — it holds the USB audio device — is sensible but
undocumented, and none of it has been tried from here.
If it is done, re-measure this page's speaker section, and the app's level through `conversation.level` beside it.

## The microphone: an XMOS XVF3800, and every knob is an HTTP call

Four microphones on a linear array, 33.3 mm apart (`AEC_MIC_ARRAY_GEO`), one far-end reference.
The register map is `media/audio_control_utils.py:46-178`; XMOS documents each name. Two routes
reach it: `GET /api/audio/config/parameter/{name}` and `POST /api/audio/config/apply`.

Values read from the unit before anything wrote to it. The daemon ships no defaults of its own
(`media/audio_base.py:186-188`), so these are the board's own configuration:

| Register                             | Value  | Meaning                                            |
| ------------------------------------ | ------ | -------------------------------------------------- |
| `AUDIO_MGR_MIC_GAIN`                 | 90.0   | microphone input gain                              |
| `AUDIO_MGR_REF_GAIN`                 | 8.0    | reference (speaker) gain into the echo canceller   |
| `PP_AGCONOFF`                        | 1      | gain control on                                    |
| `PP_AGCMAXGAIN`                      | 64.0   | gain ceiling, +36 dB                               |
| `PP_AGCDESIREDLEVEL`                 | 0.0045 | target level, −47 dBFS                             |
| `PP_AGCGAIN`                         | 4.93   | gain applied at the time of reading, +13.9 dB      |
| `PP_LIMITONOFF`                      | 1      | limiter on                                         |
| `PP_LIMITPLIMIT`                     | 0.47   | limiter threshold, −6.6 dBFS                       |
| `PP_MIN_NS`                          | 0.15   | steady-noise floor, −16.5 dB of suppression        |
| `PP_MIN_NN`                          | 0.51   | other-noise floor, −5.8 dB of suppression          |
| `PP_ECHOONOFF` / `SHF_BYPASS`        | 1 / 0  | echo cancellation runs on the chip                 |
| `PP_NLATTENONOFF` / `PP_DTSENSITIVE` | 1 / 1  | non-linear echo attenuation, sensitive double-talk |
| `AEC_HPFONOFF`                       | 2      | high-pass filter, mode 2                           |
| `AEC_FIXEDBEAMSONOFF`                | 0      | beams chosen adaptively, not fixed                 |

Three answers:

- **Noise suppression exists.** Steady noise falls up to 16.5 dB. Other noise — a television, a
  second voice — falls only 5.8 dB, so `PP_MIN_NN` is what to lower first.
- **Sensitivity is adjustable**, through `PP_AGCDESIREDLEVEL` above all. A target of −47 dBFS is
  low, which is why a distant voice stays near the noise floor.
- **A limiter really is fitted**, at −6.6 dBFS. It sits on the **microphone** path, not on the
  speaker: it limits what the robot sends out, not what it plays.

`MicrophoneProfile` names three sets of these registers, and `AudioSettingsSection` offers them.

### The conversation app rewrites the board at every start

`audio/startup_config.py` in the conversation app (#331, 2026-05-01, so in every 1.0 release) writes its own
tuning through the SDK as it comes up (`console.py:795`):

| Register          | Written     | Board default |
| ----------------- | ----------- | ------------- |
| `PP_AGCMAXGAIN`   | 10.0        | 64.0          |
| `PP_MIN_NS`       | 0.8         | 0.15          |
| `PP_MIN_NN`       | 0.8         | 0.51          |
| `PP_GAMMA_E`      | 0.5         | —             |
| `PP_GAMMA_ETAIL`  | 0.5         | —             |
| `PP_NLATTENONOFF` | 0           | 1             |
| `PP_MGSCALE`      | 4.0 1.0 1.0 | —             |

So under that app the gain ceiling is +20 dB rather than +36,
noise suppression is nearly off (−1.9 dB on both floors),
and non-linear echo attenuation is off — speech recognition prefers a noisier signal to a mangled one.
It goes through `apply_audio_config` in the SDK rather than the HTTP route,
so the integer register below is written without trouble.

Three consequences for this app:

- **A profile chosen before the app starts loses three of its five registers**
  (`PP_AGCMAXGAIN`, `PP_MIN_NS`, `PP_MIN_NN`), and the Hearing picker then matches none of the three profiles.
- **A profile chosen while it runs undoes the app's own tuning** until the app next starts —
  "Noisy room" puts `PP_MIN_NN` back to 0.18, the opposite of what the app asked for.
- None of this is a bug on either side, and nothing here should fight it:
  a robot app owns the board while it runs, the way it owns the motors.

### The phone's microphone cannot reach an app on the robot

Asked on 2026-10-01, because the robot's array is what the conversation app hears through,
and a phone held by the speaker hears them better. **Not with anything on the robot today:**

- The app reads the robot's microphone and nothing else — `record_loop` calls `get_audio_sample()`,
  and with the SDK's WebRTC backend (an app run off the robot) that is still the robot's microphone.
- `conversation.mic` is mute and unmute only (`console.py:597-602`); there is no source to select.
- The daemon plays what a WebRTC client sends and then drops it: a pad probe feeds the speaker,
  the head wobbler and (in simulation) the echo canceller, and nothing else (`media/media_server.py:527-686`).
  `clear_incoming_audio` only flushes that queue.
- The app's old `--gradio` mode did take the **browser's** microphone over WebRTC;
  it was removed in v0.8.0 (#356, #431).
- Upstream's plan for it is a draft: reachy_mini PR #1303 says v1 "keeps mic + speaker on the robot" and remote
  audio routes come "later".

What this client can do instead is transcribe on the phone and hand the words over with `conversation.say`,
which the app answers as a user message — see "Talk from this device" in `Sources/ReachyUI/AGENTS.md`.
The robot then hears text, not a voice: no intonation, and no barging in by speaking.

## The trap: an integer register cannot be written at all

`ApplyAudioConfigRequest.values` is typed `list[float]` in the daemon, so an integer register
reaches `ReSpeaker.write` as `1.0` and `struct.pack("i", 1.0)` throws. The daemon counts that as a
failure and answers `{"applied": false}`. `verify: false` does not help, because the write itself
is what fails.

Measured one register at a time: every `int32` register refused (`PP_AGCONOFF`, `PP_ECHOONOFF`,
`AEC_HPFONOFF`, `PP_NLATTENONOFF`, `PP_DTSENSITIVE`) and every `float` register took
(`PP_AGCDESIREDLEVEL`, `PP_AGCMAXGAIN`, `PP_LIMITPLIMIT`, `PP_MIN_NS`, `PP_MIN_NN`).

**It reads as success.** The register already held the value, so a readback answers correctly and
only `applied: false` says the write never happened. `MicrophoneProfileTests` holds the constraint
so no profile can name an integer register.

## Re-reading the board

```bash
curl -s http://<robot>:8000/api/audio/config/parameter/PP_MIN_NN
curl -s -X POST http://<robot>:8000/api/audio/config/apply \
  -H 'content-type: application/json' \
  -d '{"config":[{"name":"PP_MIN_NN","values":[0.25]}],"verify":true}'
```

A write is global and it outlives the session. Whether it outlives a reboot is untested: the
register map holds a `SAVE_CONFIGURATION` command that nothing in this app sends.
