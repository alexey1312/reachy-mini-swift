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

Because no single frame rate serves all sixteen, `BUDGET_LADDER` is walked per
file — 15 fps, then 12, then 10, then a smaller palette — and the script exits
non-zero rather than emitting a file Apple will refuse. Today nine land at 15 fps,
six at 12, and `builder-hammer` alone at 10.

`GIF` is not an option despite also animating: its transparency is single-colour, and
these stickers are die-cut with an anti-aliased white outline that would fringe.
`ImageIO` can write APNG from Swift but only as 32-bit RGBA, five times over the
limit — which is why this one generator is Python and not another
`Scripts/render-*.swift`.

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
