# ReachyKeychain

The Keychain calls of `HuggingFaceAuth` (the Hugging Face token)
and `ReachySSH` (saved SSH passwords and pinned host keys).
Foundation and Security only.
Both targets used to carry a copy of the same `SecItem` code;
now this target holds the one copy and the one migration.

## macOS: the data protection keychain, and the move into it

- **Until this target, the macOS app wrote to the file-based login keychain.**
  `SecItem` targets that keychain on macOS
  unless a query sets `kSecUseDataProtectionKeychain` (TN3137).
  There, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` does not apply as it does on iOS,
  and access is an ACL per app, not an access group.
- **A signed build now uses the data protection keychain, in the app's own access group.**
  `SigningEntitlements.applicationIdentifier` reads `com.apple.application-identifier`
  from the running process with `SecTaskCopyValueForEntitlement`.
  Every query sets that string as `kSecAttrAccessGroup`, not only the add.
  A query without a group matches every group the app has,
  and one of those is the App Group `group.com.alexey1312.ReachyMini`, which the widget shares.
  The widget's application identifier is different, so it cannot read these items.
  The widget does not link this target either.
- **No `keychain-access-groups` entitlement is necessary.**
  The application identifier is always one of the app's access groups.
  Xcode adds it when a provisioning profile signs the app:
  App Store, Developer ID and development builds.
- **A process with no application identifier keeps the file-based keychain.**
  That is every `swift test` run and every unsigned build,
  `mise run build:app` included (`CODE_SIGNING_ALLOWED=NO`).
  The data protection keychain refuses such a process with `errSecMissingEntitlement` (-34018).
  So `swift test` cannot reach the data protection keychain at all,
  and `KeychainHFTokenStoreTests` still tests the file-based path.
- **The move is lazy and one item at a time.**
  A read that finds nothing in the data protection keychain reads the file-based keychain.
  If an item is there, the read writes a copy to the data protection keychain,
  deletes the old item only after that write succeeds, and returns the data.
  A failed write keeps the old item and still returns it, and the next read tries again.
  Nobody is signed out, and no saved password or pinned host key is lost.
- **A delete removes the item from both keychains, and must.**
  Without the second delete, a sign-out comes back on the next read,
  because the read finds the old item and moves it across again.
  Both deletes run, also when the first one fails, and the first failure is the error:
  `HFAccount.signOut` and the SSH screens call it with `try?`,
  so removing every copy possible is what counts.
  A write also deletes the old copy, but only as a best effort: reads find the new item first.
- **What stays behind:** an SSH item for a robot that the app never asks about again
  stays in the file-based keychain, because only a read moves it.
  A downgrade to a build before the move reads the file-based keychain only,
  so it shows the user as signed out.

## Tests

`KeychainItems` takes two `KeychainBackend`s through a `package` initialiser.
`InMemoryKeychain` in `ReachyTestSupport` is the fake, and it can refuse one kind of call with a status.
`KeychainItemsTests` holds the move,
and the store tests in `HuggingFaceAuthTests` and `ReachySSHTests` hold what the user sees.
The real data protection keychain is a manual check on a signed build.
