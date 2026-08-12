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
