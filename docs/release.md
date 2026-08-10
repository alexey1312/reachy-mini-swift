# Releasing Hey Reachy

Signed artifacts are produced locally; CI only publishes the GitHub release with
generated notes. Credentials never enter the repository or CI.

## One-time setup

1. **App Store Connect API key** — App Store Connect → Users and Access →
   Integrations → App Store Connect API → Team Keys, role **App Manager**.
   Download the `.p8` once and write the credentials file:

   ```bash
   mkdir -p ~/.config/reachy-mini
   cat > ~/.config/reachy-mini/release.env <<'CONF'
   REACHY_DEVELOPMENT_TEAM=XXXXXXXXXX
   REACHY_ASC_KEY_ID=XXXXXXXXXX
   REACHY_ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   REACHY_ASC_KEY_PATH=/Users/you/.config/reachy-mini/AuthKey_XXXXXXXXXX.p8
   CONF
   ```

2. **App IDs and the App Group** — the first signed build with
   `-allowProvisioningUpdates` registers the bundle ids
   (`com.alexey1312.ReachyMini`, `.Widget`), but the
   `group.com.alexey1312.ReachyMini` capability must be added by hand in
   Xcode's Signing & Capabilities, once per App ID (app and widget separately,
   iOS and macOS separately). `xcodebuild` cannot create it.

3. **App Store Connect app record** — My Apps → New App:
   - Name: **Hey Reachy**; if taken, fall back to “Hey Reachy — robot remote”.
   - Subtitle: **Control your Reachy Mini**.
   - Bundle id `com.alexey1312.ReachyMini`.
   - The description must state it is an unofficial client for Reachy Mini by
     Pollen Robotics. A public TestFlight link goes through Beta App Review, so
     the name is checked before any App Store submission.
   - App Privacy: no data collected. The app talks to the robot on the local
     network and to Hugging Face with the user's own OAuth session; nothing is
     sent to the developer.
   - Encryption: answered in the Info.plist (`ITSAppUsesNonExemptEncryption`),
     ASC asks nothing per build.

4. **Developer ID Application certificate** (macOS) — Xcode → Settings →
   Accounts → Manage Certificates → “+” → Developer ID Application.

5. **macOS ships through both channels**, so the Mac App Store one needs its own
   signing assets besides the Developer ID certificate: Apple Distribution and
   Mac Installer Distribution. `-allowProvisioningUpdates` creates them through
   the Xcode account the same way it does for iOS. The app record already
   carries a macOS platform beside the iOS one — `mise run asc -- versions list
   --app 6799644194` shows both — so nothing has to be created in App Store
   Connect. What is not automatic is the App Group: step 2 registers it per App
   ID, and the macOS App ID is a separate one from the iOS App ID.

## Each release

1. Bump `MARKETING_VERSION` in `Apps/Project.swift` (bare semver, e.g. `0.2.0`)
   and land it on `main`. Build numbers are the commit count — nothing to bump.
2. Tag and push; the tag triggers the GitHub release with git-cliff notes:

   ```bash
   git tag 0.2.0 && git push origin 0.2.0
   ```

3. Produce and ship the artifacts:

   ```bash
   mise run release:ios     # archive → TestFlight
   mise run release:macos   # archive → both macOS channels (see below)
   gh release upload 0.2.0 Apps/DerivedData/Export/macOS/HeyReachy-0.2.0.zip
   ```

`release:macos` archives once and exports that archive twice, because
`-exportArchive` re-signs per method — the two artifacts are the same build:

| Channel        | Method            | Artifact                           | Ends up in              |
| -------------- | ----------------- | ---------------------------------- | ----------------------- |
| `developer-id` | notarize → staple | `Export/macOS/HeyReachy-<ver>.zip` | GitHub release, by hand |
| `appstore`     | upload            | `.pkg` (not kept)                  | TestFlight for macOS    |

Developer ID runs first on purpose: it is the artifact that always ships, and a
failed App Store upload should not also cost you the zip. Pick one channel with
`--channel appstore` or `--channel developer-id`.

Dry runs: `mise run release:ios -- --no-upload` exports an `.ipa` without
uploading; `mise run release:macos -- --no-notarize` stops the Developer ID
channel after the signed export, and `--no-upload` makes the App Store channel
leave a `.pkg` in `Export/macOS/AppStore` instead of uploading it. Each flag
belongs to one channel and is ignored by the other.

## The public beta

`https://testflight.apple.com/join/CGjefT9a` — the **Public Beta** group,
`c48f6abb-c178-40a2-8747-b6513add766e`, capped at 500 testers. The link is in
the README; raising the cap is one `groups edit --public-link-limit`, lowering
it below the people who already joined is not.

Uploading is not distributing. An upload reaches the internal group by itself,
because `Internal` carries `hasAccessToAllBuilds`; the public group has to be
attached per build, per platform, and each one is its own Beta App Review:

```bash
mise run asc -- builds add-groups --app 6799644194 --latest --platform IOS \
  --group c48f6abb-c178-40a2-8747-b6513add766e --submit --confirm
mise run asc -- builds add-groups --app 6799644194 --latest --platform MAC_OS \
  --group c48f6abb-c178-40a2-8747-b6513add766e --submit --confirm
mise run asc -- testflight review submissions list --build-id "<id>"
```

What review reads lives at the app level, not the build level, so it is written
once and stays: the tester-facing text in `testflight app-localizations`
(description, feedback email, marketing URL, and the privacy policy at
`docs/privacy.md` — which has to resolve on `main`, or review fails on a 404),
and the reviewer-facing contact and notes in `testflight review edit`. The notes
carry the thing no reviewer can guess — that the app needs a robot nobody at
Apple has, that the Bluetooth sheet auto-presenting on first launch hides the
Local Network alert underneath it, and that Hugging Face sign-in is the one path
that completes without hardware. Beta App Review has no demo account to give,
because the app has no accounts.

Testers see the same What to Test note per build:

```bash
mise run asc -- builds test-notes create --build-id "<id>" \
  --locale en-US --whats-new "..."
```

## Querying App Store Connect

`mise run asc` is the App Store Connect CLI with the same key already loaded —
`Scripts/asc.sh` maps the `REACHY_ASC_*` values onto the `ASC_*` names the tool
reads, so nothing is stored twice and no keychain profile exists to drift.
Everything after `--` goes to `asc`:

```bash
mise run asc -- apps list
mise run asc -- builds list --app 6799644194   # did the TestFlight upload land?
mise run asc -- testflight beta-groups list --app 6799644194
```

`asc` resolves a stored profile before the environment, so an `asc auth login`
run by hand silently outranks this wrapper — `mise run asc -- auth status`
prints which of the two is answering. The key is App Manager, not Admin, so the
same limit release-ios.sh documents applies: it can read and submit, and it
cannot manage provisioning profiles.

The CLI also ships 23 agent skills (`asc install-skills`, pinned to a reviewed
commit) covering TestFlight, metadata, submissions and signing.

## Xcode Cloud (optional, continuous TestFlight)

`Apps/ci_scripts/ci_post_clone.sh` makes a generated project buildable on
Xcode Cloud: it installs the pinned tools through the committed `bin/mise`
bootstrap, generates the workspace, and stamps `CI_BUILD_NUMBER` in as the
build number. Signing there is managed by Apple — no certificates leave the
account — and TestFlight distribution is a post-action checkbox. The setup
quirks (create the workflow from a local Xcode, start the build counter above
the last local upload, Git LFS is unsupported so never build the snapshot
scheme there) are commented at the top of the script.
