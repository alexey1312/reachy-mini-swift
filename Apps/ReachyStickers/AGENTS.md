# ReachyStickers — agent notes

The app's iMessage sticker pack: sixteen Reachy characters, animated, embedded as an
extension of the app rather than shipped as a listing of its own. There is not a line
of Swift here — a sticker pack is an asset catalogue that the system's own
`StickerBrowserViewController` renders, which is why the target declares no
`sources:` at all.

Everything under `Resources/` is **generated**: `mise run stickers:build` reads
`art/stickers` and writes the catalogue. Never hand-edit a `Contents.json` or an
image there; the script is `Scripts/build-stickers.py`, and a second run must leave
the tree clean.

## One pack, and iOS is what decided that

The plan was two extensions — stills at one sticker size, animations at another,
because Apple fixes `grid-size` per pack and forbids mixing sizes inside one. **iOS
refuses that shape**: an app may embed exactly one
`com.apple.message-payload-provider` extension. The second is rejected by `installd`
at _install_ time, with a green build and a signed bundle already in hand:

```
Multiple message payload provider extensions found in app but only one is allowed
(found com.alexey1312.ReachyMini.Stickers ; already found …StickersLive)
```

So the pack is the animated sixteen. Every character also exists as a still and both
forms fit the byte budget at this size, so a pack of all thirty-two is one flag in
`Scripts/build-stickers.py` away — it stays at sixteen because an animated sticker at
rest reads exactly like its still, and a drawer holding both is the same sixteen
characters listed twice.

A second, separate pack is still possible, but only as its own App Store record with
its own listing. That is a different product, not a build setting.

## The 500 KB limit is the whole design

Apple rejects any sticker file over 500 KB. A two-second loop at the source's own
30 fps is nowhere near it, and the obvious levers do not save it. Measured across all
sixteen animations:

| encoding                                 | avg    | max    |
| ---------------------------------------- | ------ | ------ |
| 408 px, 30 fps, RGBA                     | 5.2 MB | —      |
| 408 px, 15 fps, 32 colours, RGBA         | 757 KB | 1.3 MB |
| 408 px, 15 fps, 256 colours, **palette** | 489 KB | 721 KB |
| 408 px, 12 fps, 256 colours, palette     | 391 KB | 578 KB |
| 408 px, 10 fps, 256 colours, palette     | 328 KB | 482 KB |

The lever is **palette mode**, not colour count: 256 colours written as an 8-bit
indexed PNG beats 32 colours written as RGBA, on size _and_ on quality. Cutting the
palette while staying in RGBA is the intuitive move and it is the wrong one.

No single frame count serves all sixteen.
Each file starts at 30 frames — every second frame of the 30 fps source —
and drops one frame at a time until it fits;
below `MIN_FRAMES` (15) the script exits non-zero
rather than emit a file Apple will refuse.
Today nine files keep all 30 frames,
and the other seven keep 20 to 28 (`builder` 20, `cowboy`, `farmer` and `hacker` 25,
`explorer` and `fisherman` 27, `astronaut` 28).

**The ceiling is 500 000 bytes, not 512 000.**
Apple writes "500 KB" and does not say which kilobyte.
The stricter reading costs 2 % of the budget,
and App Store Connect gives its verdict only at upload.
The largest file today is `explorer` at 499 507 bytes.

## Every frame keeps its source time

In the 0.7.0 pack, nine stickers played source frames at strides of 1, 2 and 3 in turn,
six more at 2 and 3, and `magician` jumped at every loop.
Three causes were in this script, each one found by measurement:

- **ffmpeg's `fps` filter skips frames unevenly.**
  The WebMs carry a 1/1000 time base,
  and over it `fps=15` keeps source frames 1, 2, 4, 7, 8, 10, 13 …
  instead of 0, 2, 4, 6 …
  (checked with `-f framemd5` against a passthrough decode).
  So the motion ran at 0.5×, 1× and 1.5× speed in turn, five times a second.
  `fps=12` is 2:3 cadence by arithmetic, which is the same fault in a milder form.
  The script now decodes every frame with `-fps_mode passthrough`
  and chooses the frames itself.
  `settb=1/30,setpts=N,fps=15` also gives 0, 2, 4 …,
  but a fixed rate cannot help a file that does not fit 30 frames.
- **A file under 30 frames spends them where the motion is.**
  `motion_steps` measures how far the outline moves between two source frames,
  and `pick_frames` keeps the frames that make each displayed step move about as far:
  more of them in a fast stretch, fewer in a hold.
  Each frame then holds for a whole number of source frames, 2 to 6,
  so the motion keeps the source's own speed at any frame count.
  Against the analytic motion in `art/stickers/animated/animate.py`,
  the outline metric correlates at 0.86 to 1.00.
  Source frame 0 is always kept, so the first frame is the pose the loop starts from.
- **Each delay is a fraction, not a count of milliseconds.**
  Pillow writes a delay in whole milliseconds — 67 for two source frames —
  so a 30-frame loop played for 2.01 s.
  The script now writes the APNG chunks itself,
  with each `fcTL` delay as source frames over 30,
  and reads each file back through Pillow before it keeps it.
  ImageIO on macOS 27 reads all sixteen as exactly 2.0000 s, loop count 0.

**The shortest delay is two source frames, and that is a floor, not a taste.**
ImageIO raises an APNG delay under 50 ms to 50 ms —
a test file with a 33.3 ms frame reads back as 50 ms —
so a one-frame delay would play slow and break the timing.
The same floor sets the largest step a fast motion can get:
two source frames of it, whatever the byte budget.
That is why there is no zopfli.
It saves about 6.5 % and fits one to three more frames into the seven tight files,
but leaves the largest step of each one unchanged,
and its search alone took 131 s against 28 s for the whole script.

The fourth cause was in the motion itself, and `animate.py` now fixes it:
`magician-pop` had no exit, so its scale jumped from 1.0 to 0.55 at the seam,
and three presets moved too fast for 15 fps
(see "Плавность в iMessage" in `art/stickers/animated/README.md`).

Measured on the 0.7.0 pack against this one.
A _step_ is the mean colour difference between two displayed frames,
premultiplied by alpha, over the visible pixels;
the _seam_ is the step from the last frame to the first;
_px_ is the largest step of the analytic motion, in pixels at 408 px.
Neither pack has two equal frames in a row;
`doctor` and `plumber` each have one pair inside a hold that differs by under 0.5.

| sticker       | frames  | largest step / median | seam / median | px          | bytes             |
| ------------- | ------- | --------------------- | ------------- | ----------- | ----------------- |
| astronaut     | 24 → 28 | 1.71 → 1.57           | 1.52 → 1.43   | 6.9 → 5.1   | 420 560 → 488 099 |
| builder       | 20 → 20 | 1.49 → 1.21           | 0.09 → 0.82   | 26.7 → 18.6 | 493 974 → 494 466 |
| captain       | 30 → 30 | 1.80 → 1.27           | 1.80 → 1.23   | 13.0 → 8.9  | 446 224 → 445 997 |
| cooking-chief | 30 → 30 | 1.42 → 1.15           | 1.18 → 1.08   | 14.7 → 12.2 | 493 790 → 492 657 |
| cowboy        | 24 → 25 | 1.46 → 1.39           | 1.66 → 1.39   | 24.7 → 16.2 | 477 248 → 497 167 |
| doctor        | 30 → 30 | 8.41 → 5.38           | 1.39 → 0.62   | 24.2 → 17.7 | 379 080 → 377 682 |
| explorer      | 24 → 27 | 2.62 → 1.72           | 0.59 → 0.03   | 33.5 → 17.8 | 420 822 → 499 507 |
| farmer        | 24 → 25 | 1.61 → 1.52           | 1.43 → 0.98   | 3.2 → 2.7   | 475 534 → 494 129 |
| fisherman     | 24 → 27 | 3.33 → 2.71           | 1.56 → 1.06   | 35.4 → 21.7 | 434 958 → 488 529 |
| hacker        | 24 → 25 | 1.40 → 1.08           | 1.39 → 1.06   | 6.7 → 4.6   | 467 711 → 487 144 |
| jazzman       | 30 → 30 | 1.76 → 1.46           | 1.76 → 1.45   | 31.6 → 22.4 | 444 843 → 443 479 |
| magician      | 30 → 30 | 5.21 → 1.84           | 5.98 → 0.84   | 76.2 → 15.1 | 411 202 → 379 464 |
| plumber       | 30 → 30 | 1.87 → 1.34           | 1.74 → 1.28   | 7.7 → 5.9   | 476 852 → 477 251 |
| rich          | 30 → 30 | 2.37 → 1.27           | 2.36 → 1.27   | 9.4 → 6.1   | 417 635 → 416 332 |
| student       | 30 → 30 | 5.34 → 3.22           | 2.10 → 1.27   | 21.7 → 10.9 | 436 274 → 433 520 |
| update-box    | 30 → 30 | 3.40 → 2.79           | 0.15 → 0.08   | 47.4 → 47.4 | 391 881 → 391 334 |

Three ratios stay high, and each one is the motion, not the encoding.
`doctor` and `student` hold a pose for most of the loop, so their median step is small.
`update-box` hits the table in one source frame on purpose,
and its source was not re-rendered: `update-box-ink.png` is not in the repository.

`GIF` is not an option despite also animating: its transparency is single-colour, and
these stickers are die-cut with an anti-aliased white outline that would fringe.
`ImageIO` can write APNG from Swift but only as 32-bit RGBA, five times over the
limit — which is why this one generator is Python and not another
`Scripts/render-*.swift`.

## The animated stickers are named `.png`, and `.apng` is a rejected upload

Every animated payload is written as `<name>.png`.
That is not sloppiness about the format:
an APNG _is_ a PNG —
same `89 50 4E 47` signature, with `acTL`, `fcTL` and `fdAT` as ancillary chunks
that a plain decoder skips —
and `file` reports ours as `PNG image data, 408 x 408, 8-bit colormap`.

The extension matters because **App Store Connect validates it and `apng` is not on
the list**.
Nothing local catches this.
`actool` compiles the catalogue,
the extension builds,
the archive signs,
Messages renders the animation —
and then every sticker in the pack is rejected at upload, one error each:

```
File 'ReachyMini.app/PlugIns/ReachyStickers.appex/ReachyMini.stickerpack/farmer.apng'
has invalid extension for a 'Sticker' file. Supplied 'apng'.
Should be one of 'jpg, jpeg, gif, png'.
```

So the generator names them `.png` and the comment at that line says why.
Do not "fix" it back to the more descriptive extension.

**Renaming them is not enough on its own, because `actool` does not prune.**
A build over an existing `Apps/DerivedData` leaves the previously emitted
`<name>.apng` sitting in the product beside the new `<name>.png`,
and ships **both** — 32 files where the catalogue holds 16.
The build is green, the count in `Info.plist` is right at 16,
and the upload is rejected exactly as before.
Check the bundle rather than the catalogue after any rename here:

```bash
ls Apps/DerivedData/Build/Products/*-iphoneos/ReachyStickers.appex/ReachyMini.stickerpack
```

Deleting that `.appex`, its `PlugIns` copy inside `ReachyMini.app`
and the target's `*.build` intermediates is enough;
a full clean is not needed.
For an archive the stale copies live under
`Build/Intermediates.noindex/ArchiveIntermediates/` instead.

## Two spellings of the catalogue, and only one works

It is `Stickers.xcassets` — a plain asset catalogue holding a `.stickerpack` — which
is what Xcode 27's `Sticker Pack Extension.xctemplate` writes. The older
`Stickers.xcstickers` spelling still exists in the _Component_ template and Tuist even
knows the word, but **Tuist silently drops it**: no error, no warning, and
`grep -c Stickers.xcstickers project.pbxproj` answers 0. The build then succeeds and
produces an appex holding an executable, an Info.plist, and no stickers at all. If
the pack ever comes up empty, check that number first.

The resource is named rather than globbed for a related reason: `Resources/**` walks
_into_ the catalogue and copies each nested `Contents.json` as its own resource,
which fails as "Multiple commands produce …/Contents.json".

## The dependency condition is load-bearing

The app embeds the pack with `condition: .when([.ios])`. A Messages extension has no
macOS form — Xcode's template allows `com.apple.platform.iphoneos` alone — and
`docs/release.md` records that the notary reads **every** executable in a bundle,
which is how 0.4.0 failed over `ReachyWidget.appex`. Dropping the condition puts an
appex the Mac cannot host inside the Developer ID bundle.

It also means `mise run build:app` (macOS) does not compile the pack at all. Only
`mise run build:app:ios` does, exactly as with the widget's Control Centre controls.
Check with `ls ReachyMini.app/Contents/PlugIns/` — a macOS build shows
`ReachyWidget.appex` and nothing else.

## Reading the build back

`actool` compiles the pack into a `.stickerpack` folder beside `Assets.car` in the
appex, not into the car file, and its `Info.plist` is where every claim here can be
checked at once:

```
plutil -p ReachyMini.app/PlugIns/ReachyStickers.appex/ReachyMini.stickerpack/Info.plist
```

`IMStickerPackLayout` should read `MSStickerSizeClassRegular`, and `IMStickers`
should hold sixteen entries each carrying an `IMStickerAccessibilityLabel` — which is
how the `accessibility-label` key in a `.sticker`'s `Contents.json` is confirmed to be
the right one. `actool` itself validates nothing: a standalone `--compile` over the
catalogue emits no diagnostics, and a misspelled key draws no complaint, so this
plist is the only place a typo shows up short of VoiceOver on a device.

## Other things worth knowing

- **An asset catalogue has no localisation slot for `accessibility-label`.** These are
  therefore English-only, a deliberate exemption to project rule 9 rather than an
  oversight — there is nowhere to put the other five languages.
- **`NSStickerSharingLevel` goes in the Info.plist dictionary, not the build
  settings.** Xcode's template spells it `INFOPLIST_KEY_NSStickerSharingLevel`, which
  Xcode reads only when it generates the Info.plist itself; Tuist writes ours, so that
  setting is silently ignored and the key has to be declared directly. With it, the
  stickers reach the system Stickers app, the Messages camera and FaceTime rather than
  only a conversation.
- **Never Git LFS.** `.gitattributes` routes the snapshot references through it; these
  assets must stay out. Xcode Cloud does not support LFS and the workflow it runs
  archives the `ReachyMini` scheme, which embeds this pack — pointers would archive as
  text stubs and ship a build full of broken stickers, with nothing failing along the
  way.
- **This directory is not in the `lint` task's `PATHS`**, on purpose: SwiftLint over a
  directory with no Swift in it has nothing to say. Add it if the pack ever gains code.

## The icon

`iMessage App Icon.stickersiconset` — twelve slots in two aspect ratios, generated by
the same script over the graphite `iconSwatch` gradient. The marketing slot is
**1024×768**, not the 1024×1024 the Human Interface Guidelines table shows; Xcode's
template is what `actool` reads, so the template wins. The gradient constants are
hand-copied from `ReachyTheme.palette` for the same reason
`Scripts/render-app-icon.swift` copies them: a standalone script cannot link
ReachyDesign.
