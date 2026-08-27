# Audio levels and microphone research

Measured on 2026-08-27 against a Wireless unit (daemon 1.9.0, audio board firmware 2.1.2) and
against the vendored daemon source in `.venv-sim`.

The question: a call sounds much louder from the robot's speaker than a robot app or a move,
"as if a limiter is fitted". Also, does the robot suppress noise, and can it hear better?

## The speaker: no limiter, and no headroom either

**The daemon applies no software gain on any path.** No `volume`, `audioamplify` or
`audiodynamic` element exists anywhere in the package, and `playbin`'s own `volume` property is
never set. Three paths, one sink:

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
