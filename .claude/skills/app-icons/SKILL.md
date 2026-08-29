---
name: app-icons
description: The six generated Icon Composer .icon bundles and the README render. Use when running theme:icons, changing ReachyTheme.palette or alternateIconName, touching Apps/ReachyMini/Resources/AppIcon*.icon, or refreshing docs/media/icon.png.
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
**`docs/media/icon.png` is a copy of the shipping render, not a second rendering of it** — the README shows the
default theme's icon, and it is refreshed by hand from a macOS build:
`iconutil -c iconset <app>/Contents/Resources/AppIcon.icns -o <dir>` and then its `icon_128x128@2x.png` (256 px,
which is the size the README already used). Do **not** re-add a gradient-plus-glyph composer to the script to
generate it: that would be a second answer to "what does the icon look like" that can drift from `actool`'s,
which is exactly the divergence deleting the asset catalogue removed. It shipped stale once already — the README
carried the coral icon for the whole of the theming work.
