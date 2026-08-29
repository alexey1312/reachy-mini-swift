# Errors that name the wrong cause

Each entry starts with what you see, so you can scan for your symptom. The pattern
running through all of them is the same: App Store Connect reports the mechanism that
refused, not the reason it refused.

## Contents

1. A submission sits in Waiting for Review for days
2. `Attribute 'whatsNew' cannot be edited at this time`
3. `review submission … does not contain target version`
4. `multiple app infos found` breaks validate and doctor
5. A build number looks far too low, or far too high
6. The build cannot be swapped while review is pending

---

## 1. A submission sits in Waiting for Review for days

Normal review takes a day or two. A week or more is a stall, and nothing in the API
says whether the fault is yours or Apple's. Work through it in order rather than
guessing.

Get the real submission date. The version record's `createdDate` is when you first
made the record, often weeks earlier, and reading it as the submission date makes a
normal wait look like a disaster:

```bash
asc review submissions-list --app APP_ID
```

Then rule out the three faults that are yours. An empty draft waits forever and looks
identical from outside, so confirm the submission holds an item:

```bash
asc review items list --submission SUBMISSION_ID
```

Confirm the attached build is `VALID` and has not expired, and confirm review details
carry contact information and notes. A build expires 90 days after upload, and an
expired build under a pending submission is a stall you caused.

Finally, look for a control. If another platform of the same app was submitted around
the same time and completed, the account and the metadata are fine, and one platform's
queue is the problem. That single comparison turns a vague complaint to Apple into
evidence, and it is what the contact form asks for.

Ask Apple through the App Review contact form before cancelling. Asking keeps your
place in the queue; cancelling does not.

## 2. `Attribute 'whatsNew' cannot be edited at this time`

The full error arrives wrapped in `The request cannot be fulfilled because of the
state of another resource`, which sends you after app infos, version states and
submissions. None of those is the cause.

Release notes describe an update, so App Store Connect offers the field only after
the platform has shipped at least once. On a platform's very first version the field
does not exist, and the same push succeeds for a platform that already has releases.

Confirm it by listing versions. If every version for that platform is the one you are
working on, this is the first release:

```bash
asc versions list --app APP_ID
```

Push the other fields directly and leave release notes out:

```bash
asc apps info edit --app APP_ID --version-id VERSION_ID --platform IOS --locale en-US \
  --description "..." --keywords "..." --promotional-text "..."
```

Keep the notes in your metadata files. The next release accepts them.

## 3. `review submission … does not contain target version`

A submit command builds the submission, adds the version to it, then fails to read its
own work back. The items endpoint answers without relationships unless they are asked
for, so the final check cannot see the item it just created and reports the version as
missing. The draft is correct; only the verification is blind.

Look at the draft rather than trusting the error:

```bash
asc review items list --submission SUBMISSION_ID
```

An item in `READY_FOR_REVIEW` means the draft is complete. Submit it directly:

```bash
asc review submissions-submit --id SUBMISSION_ID --confirm
```

If the item really is missing, add it and then submit:

```bash
asc review items add --submission SUBMISSION_ID \
  --item-type appStoreVersions --item-id VERSION_ID
```

Adding an item that is already there answers `was already added to this
reviewSubmission`, which is a safe way to check.

The same failure appears when a submit command times out. It leaves a real draft
behind, so look for one before you start again — a second attempt on top of an
existing draft is how you end up with two submissions for one version.

## 4. `multiple app infos found` breaks validate and doctor

Symptom: readiness commands stop working, and the message lists two app info records,
one `READY_FOR_DISTRIBUTION` and one `DEVELOPER_REJECTED`.

Cancelling a submission creates the second record. It is a normal editable draft of
the app-level information, and it disappears when the next review completes. Nothing
is broken.

The catch is that `asc validate` and `asc review doctor` have no flag to choose
between the two, so both stay unusable until then. Commands that do take
`--app-info` keep working:

```bash
asc metadata push --app APP_ID --version 1.2.0 --platform MAC_OS \
  --dir ./metadata --app-info APP_INFO_ID
```

Submission itself is unaffected. Check age rating and the other app-level answers by
reading both records, then submit without the readiness report:

```bash
asc apps info list --app APP_ID
```

## 5. A build number looks far too low, or far too high

`CFBundleVersion` is tracked per platform. A macOS build numbered 180 and an iOS build
numbered 37 are both valid, and the build list shows them mixed together with no
platform column. Read the platform per build before concluding anything:

```bash
asc builds info --build-id BUILD_ID
```

The platform sits in the `preReleaseVersions` relationship.

Two traps follow from this. Comparing a build against the mixed maximum makes you
raise a number that was already fine, and every raise is permanent, because the next
build has to clear it too.

The other trap belongs to build numbers derived from commit count. A shallow clone
answers `git rev-list --count` with its own depth, so CI can stamp a number far below
what the server holds. The upload then fails with ITMS-90061 after the build is
compiled, signed and sent, because the number it clashes with lives on the server
where neither the build nor the export could see it. Deepen the clone before counting,
and refuse to build when the count falls below the highest number already accepted.

## 6. The build cannot be swapped while review is pending

A version in `WAITING_FOR_REVIEW` holds its build. There is no call that replaces it,
so a submission stuck for two weeks is pinned to two-week-old code, and every fix
merged since then waits with it.

Cancelling is what frees the build, and it costs the whole queue position. When you do
cancel, do not resubmit the same version. The version record returns to
`DEVELOPER_REJECTED`, which is editable, so rename it forward and attach a current
build:

```bash
asc versions update --version-id VERSION_ID --version 1.2.0
asc versions attach-build --version-id VERSION_ID --build-id NEW_BUILD_ID
```

Renaming keeps the screenshots, review details and answers that the record already
carries. Creating a fresh record throws them away, and screenshots are the expensive
part to replace.
