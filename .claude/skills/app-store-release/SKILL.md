---
name: app-store-release
description: Ship one app to iOS and macOS in the same release, and rescue a submission that App Store Connect stalled or refused. Use it when a release covers both platforms, when Waiting for Review has run for days, or when a submit fails with an error that points at the wrong cause.
---

# App Store release across two platforms

A release is four things per platform: a version record, a build, metadata, and a
submission. iOS and macOS keep their own copy of all four. They share an app record
and nothing else, which is the single fact that explains most of the surprises here.

This skill assumes you drive App Store Connect from a CLI. Examples use `asc`
(the App Store Connect CLI). The API calls behind them are the same whatever tool
you hold, so the reasoning transfers.

## Before anything else, read the server

Two numbers decide whether a release can even start, and both live on the server
where your build cannot see them.

```bash
asc versions list --app APP_ID --limit 10
asc builds list --app APP_ID --limit 20
```

Look for a version already sitting in an editable state, and for the highest build
number. Then check which platform each build belongs to, because the list mixes them:

```bash
asc builds info --build-id BUILD_ID
```

The platform hides in the `preReleaseVersions` relationship. This matters more than
it sounds: iOS and macOS count builds separately, so a macOS build numbered 180 and
an iOS build numbered 37 can sit side by side, both correct, both accepted. Compare a
new build only against its own platform. Comparing against the mixed list makes you
"fix" a number that was never wrong.

## Reuse the version record if one exists

If a version sits in `PREPARE_FOR_SUBMISSION` or `DEVELOPER_REJECTED`, it is editable.
Rename it rather than make a new one:

```bash
asc versions update --version-id VERSION_ID --version 1.2.0
```

The record keeps its screenshots, review details, contact information and answers.
A new record starts empty, and refilling screenshots by hand costs far more than the
rename. Reach for `create` only when no editable record exists:

```bash
asc versions create --app APP_ID --platform MAC_OS --version 1.2.0 \
  --copy-metadata-from 1.1.0
```

## Push metadata, but look at the plan first

```bash
asc metadata push --app APP_ID --version 1.2.0 --platform IOS --dir ./metadata --dry-run
```

The dry run prints every field it will change, with the old and new value. Read it.
A metadata push writes what a reviewer reads, and the diff is where you catch a
description that drifted between platforms.

Then drop `--dry-run` to apply.

If the push fails on `whatsNew`, the version is probably the first one this platform
ever shipped. Release notes describe an update, so App Store Connect opens the field
only from the second release onward. See `references/troubleshooting.md`.

## Attach the build and submit

```bash
asc versions attach-build --version-id VERSION_ID --build-id BUILD_ID
asc review submit --app APP_ID --version-id VERSION_ID --build BUILD_ID \
  --platform IOS --confirm
```

`review submit` can fail with `does not contain target version` after it has already
built a perfectly good draft. Check the draft before you believe the error:

```bash
asc review items list --submission SUBMISSION_ID
asc review submissions-submit --id SUBMISSION_ID --confirm
```

Do the whole sequence once per platform. They are independent, so one can be in
review while the other is still building.

## When review has stalled

Apple usually answers in a day or two. A submission still in `WAITING_FOR_REVIEW`
after a week is worth acting on, but act in this order:

First, prove the stall is real. Find when the submission was actually sent, which is
not the same as when the version record was created:

```bash
asc review submissions-list --app APP_ID
```

Second, prove the fault is not yours. Confirm the draft holds an item, the attached
build is `VALID` and not expired, and the review details are filled. A submission
missing its item looks identical from the outside and waits forever.

Third, look for a control. If you shipped another platform around the same time and
it completed, the account is healthy and the queue for that one platform is the
problem. That comparison is the strongest evidence you can bring to Apple.

Then ask Apple before you cancel. The contact form under App Review, status of a
review, costs nothing and keeps your place in the queue. Say when you submitted,
what the submission contains, and name the control that completed.

Cancel only when Apple does not answer, or the user decides to stop waiting. Cancelling
throws away every day already spent in the queue, and it has a side effect that breaks
your diagnostics afterwards — `references/troubleshooting.md` covers it.

```bash
asc submit status --id SUBMISSION_ID
asc submit cancel --id SUBMISSION_ID --confirm
```

After a cancellation the version returns to `DEVELOPER_REJECTED`, which is editable.
That is the moment to rename it to a newer version and attach a newer build, rather
than resubmit code that has aged in the queue.

## Reference

`references/troubleshooting.md` holds the failures whose error text points at the
wrong cause. Read it when a command fails and the message does not match what you see
in App Store Connect. Each entry names the symptom first, so you can scan for yours.
