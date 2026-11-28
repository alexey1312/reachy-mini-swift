---
name: app-icons
description: The six generated Icon Composer .icon bundles, the visionOS and tvOS layered icons and the README render. Use when running theme:icons, changing ReachyTheme.palette or alternateIconName, touching Apps/ReachyMini/Resources/AppIcon*.icon, Apps/ReachyVision/Resources or Apps/ReachyTV/Resources, or refreshing docs/media/icon.png.
---

# App icons

**App icons are six Icon Composer bundles, generated — `./bin/mise run theme:icons`.** They live at
`Apps/ReachyMini/Resources/AppIcon*.icon` and are ordinary opaque resources: Tuist references each as one file, so
the existing `resources: ["ReachyMini/Resources/**"]` glob needed no change and nothing decomposes them into
`icon.json` plus `Assets/`. A second run must leave the tree clean — `JSONSerialization` is called with `.sortedKeys`
precisely so it does. There is **no asset catalogue for the app icon**: a `.icon` shadows a same-named `.appiconset`
completely (measured — the catalogue contributed zero renditions), so re-adding one is a silent no-op, and iOS 18–25
is served by the back-deployment rasters `actool` derives. Alternate icons are declared twice — in
`ReachyTheme.alternateIconName` and in `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES[sdk=iphone*]` — and only
`ThemeIconNameTests` keeps them in step; a mismatch fails inside `setAlternateIconName` on a device and nowhere
earlier. **No reference image covers any of this** — the suite renders views, never a Home Screen, so an icon change
is a device check plus one iOS 18 simulator install. Each extra icon is ~624 KiB in `Assets.car`.
**The robot is five SVG layers in three groups, and the SVG is what keeps an iPad sharp.**
`Scripts/render-app-icon/Geometry.swift` builds each shape once, as a `CGPath`.
`SVG.swift` writes those paths into the `.icon` bundles,
and `Drawing.swift` fills the same paths into the visionOS and tvOS bitmaps.
actool stores an SVG layer as a `Vector` rendition and a PNG layer as a bitmap of its own size.
The old layer was one 1024 px `robot.png`, and it showed pixel steps on an iPad.
To check a build, run `xcrun --sdk iphoneos assetutil --info <app>/Assets.car`:
every `AppIcon*_Assets/*` entry must read `Vector`.
**The dark background goes in `fill-specializations`, beside a default entry that names no appearance.**
With a top-level `fill`, Icon Composer 27.1 ignores the dark entry (measured with `ictool`):
the system puts its own near-black behind the robot and paints the theme's gradient onto the white shell,
so the six themes look the same in Dark Mode.
`ThemeIconNameTests.everyIconHasItsOwnDarkFill` fails on a top-level `fill`.
**Tinted and Clear keep only the luminance of each layer.**
So `icon.json` makes the antennas white and the goggles black in the `tinted` appearance,
which Clear also uses.
Ink antennas disappear against a dark background otherwise, in Dark Mode too,
where they take the theme's light stop.
**Render any appearance without a build** with `ictool`, in `Icon Composer.app/Contents/Executables` inside Xcode:
`ictool <x>.icon --export-image --output-file <png> --platform iOS --rendition TintedDark --width 256 --height 256 --scale 2`.
The renditions are `Default`, `Dark`, `ClearLight`, `ClearDark`, `TintedLight` and `TintedDark`.
No `simctl` command selects the tinted or clear icon style, so `ictool` is the only check of those two.
**visionOS takes no `.icon`, so the same script writes its icon as a layered image stack.**
`Apps/ReachyVision/Resources/Assets.xcassets/AppIcon.solidimagestack` holds three 1024 px layers,
which visionOS masks to a circle and moves apart as the reader looks at it:
the default theme's gradient at the back (opaque, as visionOS requires),
the antennas and the shell in the middle, the goggles in front, drawn 14 % smaller so the antenna tips stay inside the circle.
It is a gradient-plus-glyph composer, which the README render must not be, and that is the only way to make one:
the stops come from the same `iconThemes[0]` the `.icon` bundles use, so the colours cannot drift,
but the light, the glass and the shadow are visionOS's own and not Icon Composer's.
The default theme only, because visionOS offers no alternate icons.
**tvOS takes no `.icon` either, so the same script writes the TV app's brand assets.**
`Apps/ReachyTV/Resources/Assets.xcassets/App Icon & Top Shelf Image.brandassets` is what App Store Connect requires:
two layered image stacks (`App Icon`, 400 × 240 pt at @1x and @2x, and `App Icon - App Store`, 1280 × 768 at @1x)
with the visionOS split — opaque gradient at the back, antennas and shell in the middle, goggles in front,
the robot at 80 % of the height so the focus parallax does not crop the antenna tips —
and two flat, opaque top shelf images (1920 × 720 and 2320 × 720 pt, @1x and @2x), the gradient with the robot in the middle.
The names are Xcode's own, because the target names the set in `ASSETCATALOG_COMPILER_APPICON_NAME`.
The default theme only: tvOS offers no alternate icons. No reference image covers it; a TV Home Screen is a device check.
**`docs/media/icon.png` is a copy of the shipping render, not a second rendering of it** — the README shows the
default theme's icon, and it is refreshed by hand from a macOS build:
`iconutil -c iconset <app>/Contents/Resources/AppIcon.icns -o <dir>` and then its `icon_128x128@2x.png` (256 px,
which is the size the README already used). Do **not** re-add a gradient-plus-glyph composer to the script to
generate it: that would be a second answer to "what does the icon look like" that can drift from `actool`'s,
which is exactly the divergence deleting the asset catalogue removed. It shipped stale once already — the README
carried the coral icon for the whole of the theming work.
