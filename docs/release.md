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
   mise run release:macos   # archive → Developer ID → notarize → staple → zip
   gh release upload 0.2.0 Apps/DerivedData/Export/macOS/HeyReachy-0.2.0.zip
   ```

Dry runs: `mise run release:ios -- --no-upload` exports an `.ipa` without
uploading; `mise run release:macos -- --no-notarize` stops after the signed
export.

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
