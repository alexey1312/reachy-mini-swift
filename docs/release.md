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

Both archive commands compile with the Xcode compilation cache off
(`COMPILATION_CACHE_ENABLE_CACHING=NO`) and then run
`Scripts/check-appintents-metadata.sh` against the archive before anything is
exported or uploaded. The intents live in a static SPM library, so the
Shortcuts app only ever sees what `appintentsmetadataprocessor` extracted into
`Metadata.appintents` — and extraction failing is a warning, never a build
error. TestFlight 0.1.1 shipped exactly that way: green archive, no actions in
the Shortcuts app. The check names every missing action instead; if it fails,
the fix is in the build, not in App Store Connect.

Dry runs: `mise run release:ios -- --no-upload` exports an `.ipa` without
uploading; `mise run release:macos -- --no-notarize` stops the Developer ID
channel after the signed export, and `--no-upload` makes the App Store channel
leave a `.pkg` in `Export/macOS/AppStore` instead of uploading it. Each flag
belongs to one channel and is ignored by the other.

### When `-exportArchive` fails

Two failures land on the same step and have nothing to do with each other.

`productbuild failed` with `CSSMERR_CSP_USER_CANCELED` in the distribution log is
the keychain: the Mac Installer identity lives in `reachy-signing.keychain-db`,
and macOS put up an access dialog that a non-interactive run cannot answer — it
"cancels" itself after a few minutes. Authorize the key once and the keychain
keeps it:

```bash
KC=~/Library/Keychains/reachy-signing.keychain-db
PW="$(cat ~/.config/reachy-mini/signing/keychain.pw)"
security unlock-keychain -p "$PW" "$KC"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC"
```

`Failed to Use Accounts` is the Xcode account instead, and only the upload leg
needs one. Export locally and hand the artifact to the API key, which does the
upload, the group and the Beta App Review submission in one call:

```bash
mise run asc -- publish testflight --app 6799644194 --platform IOS \
  --ipa "Apps/DerivedData/Export/iOS/Hey Reachy.ipa" \
  --group c48f6abb-c178-40a2-8747-b6513add766e \
  --wait --test-notes "…" --locale en-US --submit --confirm
```

A macOS `.pkg` is not a zip, so `asc` cannot read the version out of it: that one
also needs `--version` and `--build-number` (the commit count) spelled out.

## The store listing

The App Store copy lives in this repository, at `metadata/` — `app-info/en-US.json`
for the fields that belong to the app (name, subtitle, privacy policy URL) and
`version/<ver>/en-US.json` for the ones that belong to a version (description,
keywords, promotional text, support and marketing URLs). Edit those, then:

```bash
mise run asc -- metadata validate --dir ./metadata
mise run asc -- metadata push --app 6799644194 --version 0.2.0 --platform IOS --dir ./metadata --dry-run
mise run asc -- metadata push --app 6799644194 --version 0.2.0 --platform IOS --dir ./metadata
```

Push once per platform — `IOS` and `MAC_OS` carry separate version localizations
off the same files. `whatsNew` is deliberately absent: Apple refuses it on an
app's **first** App Store version (`Attribute 'whatsNew' cannot be edited at this
time`), so release notes start with the second one.

Everything that is not a localization is set once and stays: category, content
rights, age rating, availability, price, and the reviewer contact and notes. They
are listed by `asc validate --app 6799644194 --version-id <id> --platform <p>`,
which is the one command worth running before every submission — it prints an
ordered remediation plan and exits non-zero while anything is missing.

Two of those answers are judgement calls, and both were decided against the two
Reachy apps already on the store rather than from first principles. Pollen's own
`Reachy Mini` (id 6766823749) sells the same community app catalogue this one
does — "browse and launch community apps instantly" — and stands at **9+** with
_Infrequent/Mild Cartoon or Fantasy Violence_ and _Mature/Suggestive Themes_,
which is a statement about what a community app might do rather than about the
app's own content. The independent `Reachy's Brain` (id 6757115923) is **4+**
with no advisories, but it ships no catalogue at all, so it is not the precedent
to copy. Hence: `USES_THIRD_PARTY_CONTENT`, because the Apps tab renders a Hugging
Face catalogue this project does not own, and every age-rating answer left at
`NONE` with an explicit `--age-rating-override-v2 NINE_PLUS` on top — declaring a
shelf position rather than asserting content the app does not contain. Both are
one `asc` command to revert. Their public halves are readable without a session:
`curl -s "https://itunes.apple.com/lookup?id=<id>"` carries
`contentAdvisoryRating`, `advisories` and `genres`; the content-rights
declaration is private and cannot be checked this way.

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
