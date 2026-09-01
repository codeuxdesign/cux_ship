# Changelog

## Unreleased

**The Play uploader checks an image's alpha channel and bit depth, and stops
parsing PNG headers itself.** `_loadImages` validated extension, count and
dimensions before uploading and checked neither — so `play upload --metadata`
sent a listing Play refuses during ingestion, having read the very header that
says so.

It re-checks rather than trusting `verify`, and the reason is that `verify` is
not on this path: `runPlay` does call `checkPlayTree`, but only when the
repository declares listing requirements, so a project with no `play:` block in
`.cux-ship.yaml` uploaded with that check skipped entirely — and it is the
project least likely to have run `cux_ship verify` first.

The second hand-rolled header parser is gone with it. It read dimensions and
nothing else, which is how one of the two copies of an image check ended up
never being told about alpha; `readImageInfo` and `imageEncodingProblem` in
cux_ship_verify now answer for both. A re-check that can disagree with the check
is worth less than no re-check, because it makes a green `verify` mean less than
it says.

**`screenshots flatten` reduces 16 bits per channel to 8, and used to preserve
it.** `flattenPng` returned "already opaque" with nothing to write whenever the
image had fewer than four channels, so a 48-bit RGB capture was left exactly as
found; and where it did rewrite, `convert(numChannels: 3)` preserves the source
format, so a 16-bit RGBA capture came back with the alpha channel gone and the
depth untouched. Both are reachable from one capture — a macOS `--no-chrome`
fallback writes depth 16 — which made this the remedy those checks name for a
state it could not reach.

Conversion rescales rather than truncating: 65535 becomes 255 and 256 becomes
1, where taking the low byte of each would satisfy "the depth is 8 now" having
thrown the picture away. Below 8 bits is left alone, matching the checks —
a palettised PNG's entries are already 8-bit and no store has been seen to
refuse one.

**And it flattens a greyscale-with-alpha PNG, which the same gate called
opaque.** PNG colour type 4 decodes to *two* channels, so "fewer than four
channels" declared "already opaque" a file the checks refuse for its alpha
channel — and pointed the user back at this command. The gate now asks whether
the image has an alpha channel; where such a file carries real transparency it
is promoted to RGBA before compositing, because `compositeImage` reads a
two-channel colour as fully opaque.

`FlattenOutcome` still answers only about the alpha channel, and the depth is
`FlattenResult.reducedBitDepth` beside it. The two are independent, and an enum
answering both would have to invent a precedence and then hide whichever answer
lost. `--check` reports both and now exits 2 on a file whose only problem is
depth, which it previously passed.

**This needs the cux_ship_verify that ships `store_image.dart`, and the
constraint here still says `^1.9.0`.** Raise it on the release branch, once that
version exists: the workspace cannot resolve a constraint naming a version no
member is at, so a feature branch cannot raise it and then be tested. Publishing
`cux_ship` against `^1.9.0` would let a consumer resolve a `cux_ship_verify`
without `imageEncodingProblem` in it, and fail to compile.
**Play's data safety declaration is published when you ask for it, and checked
every time.** `play upload` sent the CSV on every run that was given one, and
Play files each POST as a pending **App content → Data safety** change whether
or not an answer moved — so an app uploaded weekly accumulated one unsubmitted
review per upload, against a declaration nobody had touched in months. The line
it printed, `data safety declaration updated`, said the same thing on the run
that changed something and the run that changed nothing, which is why this took
so long to notice.

The listing images already skip when they match: each carries a sha256, so a
listing publish says `4 phoneScreenshots unchanged` and sends nothing.
`applications.dataSafety` cannot be made to work that way — v3 has no GET for
the labels and the POST answers `$Empty`, so a run genuinely cannot tell an
unchanged declaration from a changed one. The alternative, remembering the last
CSV sent, is state outside the repository, which is worse than the problem.

So `--data-safety` now means *check this*, and the new `--send-data-safety`
means *publish it* — and the output distinguishes `data safety declaration
sent` from `data safety declaration checked, not sent`, which are different
facts and only one of them was previously sayable. The structure check still
runs on every upload, because the run that publishes is the one that cannot
afford to meet a broken CSV.

**Breaking for anyone passing `--data-safety`,** which is the intended usage: a
build script that passes it on every upload keeps validating the declaration
and stops publishing it. Add `--send-data-safety` to the run after you edit the
CSV. A run whose only argument was `--data-safety` now refuses as `nothing to
do` rather than committing an empty edit.

## 3.6.2

**A listing publish that is going to be refused is refused before it writes
anything.** `_publishAscListing` acquired the `appInfos` record before writing
app-level fields and the version *after* them — so a run against a version
Apple will not let anyone edit wrote the content rights, the categories, the
age rating and the localized name, and only then took a 409 naming the
version. Half applied, and needing a diff against the store to notice.

That satisfied "acquire before write" for each resource separately while
breaking it for the pair, which is not a weaker form of the rule but a
different one that happens to coincide when there is a single resource. Every
acquisition that can refuse now happens before any write: the writable record,
the age-rating declaration, the version name, the version, and the review
contact — which refuses a half-set `APPLE_REVIEW_CONTACT_*` environment and
had been read beside the write it feeds, so its own reason for existing
described what it then did.

It needs app-level drift and an unusable version together, which is the
combination nobody arranges deliberately and everybody meets after a
rejection. Found by a consuming project pointing a `--listing-only` run at a
released version; it wrote nothing only because that tree happened to match.

**A publish that changes nothing now writes nothing, including the version
text.** 3.6.1 compared the app-level half and the screenshots before writing
them, and rewrote the copyright, the review notes and every localized listing
field regardless — so a run against an unchanged tree still sent seven PATCHes
carrying identical values.

Harmless per request, which is why it survived, and seven more chances to exit
non-zero having already written something — the failure shape the rest of this
package is built to avoid. The boundary was not a decision: each comparison in
3.6.1 exists because a specific defect demanded one, and these fields had no
defect behind them. The rule stopped where the bugs did.

The review contact is part of the comparison, not just the notes: Apple refuses
an update carrying notes without the whole contact beside them, so the pair is
what gets written and the pair is what has to match. A field Apple did not
report counts as differing, as everywhere else here.

Found by a consuming project upgrading to 3.6.1 and reading its own
`--listing-only --dry-run` output — the same run that confirmed the screenshot
skip working for the first time.

## 3.6.1

**`appstore promote` can say how the release should start, and always says how
it will.** `appStoreVersions.releaseType` decides what happens once Apple
approves — wait for somebody to press release, or go out on approval — and
there was no flag for it. Asked how a release should go out, a maintainer chose
automatic; the version cux_ship created was `MANUAL`, because that was
hardcoded. Nothing was rejected and nothing was reported: the decision had
nowhere to go, and the default stood. It only did not matter because manual is
the safer end of that mistake.

`--release-type MANUAL|AFTER_APPROVAL` now carries it. **An unset flag still
changes nothing** — a new version is created `MANUAL` as before, an existing
one is left exactly as App Store Connect has it. A tool that normalised the
unset case to its own preference would be the same failure running the other
way. `SCHEDULED` is refused rather than approximated: Apple takes it, but only
beside an `earliestReleaseDate` this tool has no way to send, and a version
already scheduled is refused rather than silently rescheduled.

And the run prints the effective release type, read back from the record Apple
acknowledged rather than from the flag — *print effective configuration, never
intended*. That line is the half that would have caught this, because the run
it needed to catch passed no flag at all.


**`promote` no longer fails because the *other* platform is in review.** An app
has one set of app-level records shared by both platforms, so
`promote --platform macos` refused with 409 whenever the iOS side sat in
`WAITING_FOR_REVIEW` — and refused at the first thing a promotion does, so
nothing downstream ran: no version created, no build attached, no submission
made. The gate was this package's own invention. Apple accepts a `PATCH`
against an `appInfos` record in that state. `editableVersionStates` is
unchanged, because it is also what refuses a push against a *version* that is
with Apple, and that refusal is correct; the app-level half now has its own
list.

**And it does not fail for a listing it was not going to change.** The
app-level half opened by demanding an editable record before anything had
decided whether the tree carried app-level content at all, so a promotion
whose listing already matched App Store Connect failed for want of a record it
would never have touched. It now reads the records once, compares field by
field, and asks for something to write to only when something needs writing —
which is the ordinary case on a release where the categories, the age rating
and the name have not moved since the last one. A run that changes nothing
writes nothing.

Content rights is the exception that proves the shape: it is an attribute of
the app rather than of an `appInfos` record, so it is no longer gated on
acquiring one — and it is still skipped when it already matches. Two
properties, and it needed both.

**Where a refusal is still right, it now says which field and what to do.** A
value that could not be read counts as differing rather than as matching,
because skipping a write on the strength of not knowing is how a listing
silently fails to publish. Refusals name the fields that would have been
written and the states that would have accepted them, and the two 409s no
longer read alike: "no record can be written to" is answered in App Store
Connect, "Apple rejected this value" is answered in the tree.

Writability is a whitelist. A record under active review, and any state this
package has not enumerated, is refused rather than written to — Apple has
changed that enum before, and an unrecognised state that refuses costs
somebody a minute where one that writes changes something nobody examined.
One consequence worth knowing: a record whose `appStoreState` Apple does not
report is now refused too, where it used to be treated as editable. It only
arises when a write is actually needed.

**A promotion that fails after creating the version now says so.** Creating it
is one of the first things a promotion does, so a failure anywhere after that
exits non-zero having already changed what App Store Connect holds — and
"exit 1" reads as "nothing happened". The failure now names the version it
left behind and that a rerun will adopt rather than duplicate.

**The App Store rejects emoji in "What's New" too, and this package said it
did not.** The stripper existed and was applied to TestFlight only, under a
notice that told you in so many words that "the App Store release notes keep
them". That claim was reasoned from published listings carrying emoji — which
is evidence about the *description*, a different field with a different rule —
and nothing had ever exercised it, because the only prior submission for the
app in question was a first release and a first release has no "What's New" at
all. The first second-release to meet it got a 409 naming `🧭, 🗺, 🌍` and a
bare variation selector, after the version had been created and the build
attached.

Release notes are now stripped for both surfaces, by one rule rather than two
lists that would drift apart. The App Store notice names the exact characters
removed, with code points, because one of them is invisible and because this
is copy a shopper reads: publishing something other than what CHANGELOG.md
says should never be quiet. Play still gets them verbatim, and the changelog's
"emoji are welcome and encouraged" rule is unaffected — absorbing Apple's
restriction is the tool's job, not the changelog's.

**Screenshots that have not changed are no longer re-uploaded, and a
screenshot Apple rejects is no longer reported as uploaded.** `--metadata`
deleted the whole screenshot set and re-uploaded every file on every run. That
was recorded as known and harmless. It was neither: four assets going up
immediately before a submission is what made `promote --metadata` fail with
`appStoreVersions '…' is not in valid state` — a message about the version, for
a problem with its screenshots, on a run that had reported every one of them
uploaded. Measured: the identical request, replayed forty minutes later with
no upload, was accepted.

The set is now compared before it is deleted, by delivery state, by file name,
and by the same MD5 Apple stores as `sourceFileChecksum` — which this package
already computed in order to commit it. Order is part of the comparison,
because screenshots are shown in the order they were uploaded and the same
files rearranged are a different listing. Anything that cannot be shown to
match is re-uploaded, so the cost of doubt is an upload nobody needed rather
than a listing nobody updated. Only an asset Apple reports as `COMPLETE`
counts as published: the checksum is committed before ingestion finishes, so
name and checksum alone would match one that later failed, or one still in
flight when an earlier run gave up — republishing neither, which is both of
the defects below arriving back through the skip meant to remove them.

Underneath that was the quieter defect. Committing an upload returns a
verdict, and the response was discarded — so a screenshot refused during
ingestion for an alpha channel or the wrong dimensions printed `uploaded` and
was then simply absent from the listing, with nothing in the run saying so.
The run now waits for Apple to finish with each asset and reports a rejection
in Apple's own words. With unchanged screenshots skipped there is usually
nothing to wait for, so the wait costs nothing on the release where nothing
moved.

**A category write now checks that nothing else moved.** A category `PATCH`
names only the relationships the metadata tree declares, so it always omits
the rest — the other category, and the four subcategory slots this package has
never managed. Everything says omission leaves them alone: JSON:API specifies
it, established clients of this API distinguish omitting a relationship from
setting it explicitly null, and partial category documents go out against a
very large number of apps without lost subcategories being a known problem.

That is a good argument, and it was still only inference about somebody's
published listing. On the rare run that writes a category at all, the six
relationships are now read before and after, and anything that moved without
the tree asking is reported. If the reading cannot be taken, it says so rather
than passing quietly — a check that silently did not happen is otherwise
indistinguishable from one that found nothing. It never fails the run: the
write has already landed by then, and a diagnostic that can take down a
publish is worse than the uncertainty it was added to remove.

**Fixed: `promote --metadata` published the whole listing twice**, clearing
and re-uploading every screenshot both times, under a comment claiming it
published in one place only. Two conditions at two sites that had to stay
complementary by discipline; now one decision, read at both.

**`screenshots flatten` picks the PNG filter by measuring instead of assuming,
and store screenshots get about a third smaller.** `encodePng` defaults to
`PngFilter.paeth`, which is the right guess for a photograph and a poor one for
a screen capture: a store screenshot is mostly flat panels of one colour with a
single photographic region, and a per-scanline predictor that helps the
photograph hurts everything around it. On a 2880x1800 macOS capture, paeth
produced 3,953,681 bytes where no filtering produced 2,685,629 — 32% smaller,
and smaller than the RGBA original the flatten was handed.

The filter is now chosen by trying them and keeping the smallest, so which one
wins is a property of the picture rather than a default: a listing of dense
photographs may still choose paeth, and it gets paeth. The compression level is
deliberately left alone — the same measurement puts level 9 within 0.8% of level
6 on every filter, which is noise against the time it costs on files that can be
tens of megabytes.

It matters because these bytes are committed. A listing's screenshots live in
the repository that ships them, where they are paid once in history and again in
every worktree.

## 3.6.0

**`appstore beta-groups` prints the groups an app has, and the kind of each.**
A group's *name* is the one input `--beta-group` cannot infer, default or
guess, and nothing printed one: the only command that touched groups filtered
by exact name, so a caller who did not already know the name had to leave the
tool and read App Store Connect. The kind comes with it because the kind is
half the answer — assignment alone delivers an internal group within minutes
and delivers an external one nothing until beta review passes, so choosing a
name from this list is choosing what a release costs.

**And the lookup that misses now names the groups that exist.** `no beta group
called "X"` was true and unhelpful: filtering by exact name answers only about
the name asked for, so the refusal withheld the one string the caller was
missing — from a response the command was already entitled to make. It now
lists what the app has, with each kind, or says the app has none at all and
that groups cannot be created over the API.

Found from the consuming end, staging a build to external testers on a release
where the group's name was not written down anywhere: 3.5.0 made the release
work and left no way to discover what to call it.

**A group whose kind Apple did not report is refused at release, not
guessed.** The kind was read `== true`, which collapsed "false" and "absent":
a `betaGroups` resource not carrying `isInternalGroup` — a sparse fieldset, an
API change — silently read as external, on the one field a beta release
branches on. The defaults are not symmetric, which is why neither is taken:
external submits an internal group for beta review and fails at Apple, where
somebody sees it; internal assigns an external group and prints done, the
silently hollow release this flow exists to prevent. The release path now
refuses an unknown kind before anything is written. The two display sites —
the `beta-groups` listing and the miss's group list — print `unknown` instead
and carry on, because a diagnostic must not blank itself over one malformed
group, and "Apple did not tell me" points at the cause where a guessed kind
points nowhere. Both listings are now also sorted by name, since the API
promises no order and stable output is diffable output.

## 3.5.1

**Manifests written by 3.5.0 name producer "cux_ship 3.4.2"** — the release
bumped the pubspec and not the hand-maintained `cuxShipVersion`, and nothing
on the publish path runs the test that exists for exactly that drift. The
constant is right again, and the release script now refuses to publish when
the two disagree, beside its version-set-by-HEAD guard: the same class of
silence, where nothing fails and a wrong provenance string reads exactly like
a right one.

**The committed-notes guard now looks through a symlink, not at it.** `git
status -- <link>` answers for the link object, which stays clean while the
file it points at is mid-edit — and the link's parent decided which repository
was asked, the wrong one for a link into another checkout. A repository
keeping `CHANGELOG.md` as a root symlink shipped an uncommitted section
straight past the guard that way. Refusals through a link now name the
resolved file, the one to commit.

## 3.5.0

### External TestFlight groups are a release, not an assignment

`--beta-group` used to add the build to the group and stop — complete for an
internal group, which receives an assigned build within minutes, and silently
hollow for an external one, which receives *nothing* until the build passes
Apple's beta review. The flag now reads the group's kind and carries an
external release the rest of the way: the Beta App Description is reasserted,
the build is submitted for beta review — idempotently, a retried job finds the
first run's submission instead of a 409 — and the closing line reads back the
`externalBuildState` Apple now reports, because what a run sent is not
evidence of what arrived. The internal path is unchanged to the byte.

**`appstore beta-release` is promote's TestFlight sibling.** For the build
somebody else's job uploaded — CI, usually — where `upload` has nothing left
to carry:

```bash
cux_ship appstore beta-release --build-number 52 --beta-group "External Testers"
```

`--build-number` is required, not defaulted to the newest, for the reason
`wait` requires it: a release to testers is a release of a *specific* build,
and "newest" would release somebody else's upload.

**The description is owned like every listing field.**
`store/appstore/listings/<locale>/beta_description.txt` present means
reasserted on every release; absent means App Store Connect owns it and
nothing here touches it; only *no description anywhere* — no file, no locale
in the console holding one — is refused, before anything has been written.
`--beta-description <file>` overrides the tree; it is a file option and never
a bare string, so what testers read went through a working tree rather than
shell history, and like the changelog it must be committed.

New refusals, each closing a silent failure: `--beta-description` against an
internal group, or without any `--beta-group`, publishes nothing and says so
instead; `--skip-waiting` with `--beta-group` asked for incompatible things
and used to skip the group step while still printing done; a prior beta
review submission Apple `REJECTED` is a hard failure rather than a green
no-op, because a build is submitted at most once and re-running does not
resubmit.

**`promote --beta-group` no longer publishes the listing.** The option's help
always said a group promotion creates no App Store version and publishes no
listing; the inferred `store/appstore` tree made both claims false. The
inference is suppressed under `--beta-group`, and an explicit `--metadata`
alongside is refused as the contradiction it is.

## 3.4.2

### Windows

`deps install` pins `sops` and `age` for `windows_x64`, and the `exec` paths run
there. Reported as a pin-table addition; it was four things before a pin was
reached, each unreachable until the one before it was fixed:

- **sops names its Windows asset by architecture alone** — `sops-v3.13.3.amd64.exe`,
  with no `windows` in it, where every other platform is `<os>.<arch>`.
- **age ships a `.zip`** where every other platform ships `.tar.gz`, which decides
  the URL *and* whether `tar` gets `-xf` or `-xzf`; GNU tar cannot read a zip.
- **Binaries need `.exe` on disk**, and every lookup had to agree — the install
  wrote `sops.exe` while `findSops` asked for `sops`, then fell back to
  `sh -c command -v`, and there is no `sh` on a Windows runner.
- **A shebang is a POSIX kernel feature.** `./ci.sh` is handed to `CreateProcess`,
  which cannot run it. Shell scripts are launched through Git Bash, chosen by
  location — `C:\Windows\System32\bash.exe` is the WSL launcher, and on a runner
  with no distribution it exits 255 saying so.

`windows_arm64` is deliberately unpinned: sops publishes `arm64.exe`, age
publishes no windows-arm64 archive, and half a toolchain is worse than the
message saying what to install.

**Signal watching now asks the platform first.** `ProcessSignal.sigterm.watch()`
raises on Windows, asynchronously, and `secrets exec` carried on running — so the
watcher that cleans up a decrypted key on Ctrl-C was **not armed, and armed and
unarmed looked identical**. Little is actually lost there: Windows has no POSIX
SIGTERM, `SIGINT` is what Ctrl-C sends, and Dart watches that fine.

### Known limitation on Windows: a Dart grandchild's console

**Under `secrets exec` or `keychain exec` on Windows, a Dart process spawned
below the child can die silently.** Isolated to one boundary by a consumer, with
a four-level repro: bash chains and command substitutions are fine at any depth,
and the defect turns on precisely at a Dart parent spawning with
`ProcessStartMode.inheritStdio` — below which descendants lose the console in
both directions, and a Dart grandchild dies with exit 255 before its first write.

**The workaround is to redirect that tool's output to a file**, which restores
it completely. That is a workaround, not a fix, and is named as one here.

Not fixed in this version on purpose. The mitigation in our layer would be to
pipe and forward rather than inherit, which costs interactive children, TTY
detection and correct stream interleaving — a trade worth making only if the SDK
says the behaviour is intended. A minimal repro exists for that question.

### Two runners recording the same build is no longer read as a collision

**A release matrix could not record an upload.** Jobs that share a commit and a
build number — playstore and playstoredev, ios and macos — each mint their *own*
annotated tag object for the same name and the same commit: different timestamp,
different message, therefore a different object id. Git refuses to replace one
with the other and rejects the push as `! [rejected] ... (already exists)`,
which is the same words as a genuine collision.

The push treated any rejection as that collision, so the second job's upload was
blocked having done nothing wrong — and because the record is written before the
store is contacted, the release half-shipped: one store took the build and the
others refused to start. AuthPass hit this on a real stable push.

Origin is now asked what its tag actually names, exactly as the local path
already asks:

```
git ls-remote origin 'refs/tags/<name>^{}'
```

The `^{}` is the fix. Without it `ls-remote` answers with the tag *object* id,
and comparing those reports a collision on every parallel release and never on a
real one. Same commit is `alreadyRecorded`; a different commit is still
`UploadCollisionException` and still exit 3. A rejection with no remote tag at
all — credentials, network, a hook — re-runs the push so git's own message
reaches the operator rather than an invented one.

The existing remote-collision test used a *different* commit, which is the rare
case; a matrix sharing one commit is every release. The same-commit case has its
own test now, and it fails against the old push.

## 3.4.1

### The fixes below have tests that die when the fix is removed

Found by review, and the most useful thing in it: reintroducing the guard bug
left all 464 tests green, and deleting the collision's `catch` clause did too.
Both fixes were as untested as the defects they fixed, and both defects were the
silent kind — so the suite would have watched either walk back in.

The guard's decision is now `uploadRecordFor`, split out of the store plumbing
so it can be exercised without a store, a network or a repository; three of its
cases go red against the old guard. The collision drives the real binary in a
git repository holding a colliding record, and observes exit 3 — reachable
because the record is written before the store is contacted.

Neither test could have been written against the old shape. That is the finding
rather than an aside: a decision buried in a method that needs credentials to
reach is a decision nothing will check.

### A listing-only push no longer demands a build it did not upload

`play upload --metadata` publishes a store listing and hands over no artifact —
documented, with a worked example. Repairing the recording guard made every such
run refuse under `tag.upload.enabled`, before any store contact, because the
record's scope was "the upload command ran" rather than "an artifact reached the
store". An operator supplying the previous build's numbers to get past it would
have been told the upload *collided* — exit 3, on a run that uploaded nothing.

Recording now requires an artifact in the run: `--aab`, `--artifact`, or one the
manifest names.

### An Android manifest carrying neither value is a refusal, not trust

Every valid `.apk` and `.aab` declares `versionCode` and `versionName`. Finding
neither means the walk lost its place, and reporting that as "taken on trust"
was the same collapse the cross-check exists to prevent, one level in. Related:
`_pooled` treated *any* out-of-range string index like the format's explicit
`0xFFFFFFFF` sentinel, so a desynced read produced a plausible partial answer
instead of an error.

A partial check now names the half it did not check — `build number agrees with
…, version name taken on trust`. It used to print only what it had compared, so
"checked one of two" and "checked both" differed by which nouns appeared.

### Smaller, all from the same review

- `readApkFacts` and `readAabFacts` caught only `FormatException`, but the
  walk's reads are `ByteData` and raise `RangeError` — so a manifest declaring
  sizes past its own end escaped as an unhandled Dart error with forty frames,
  out of a binary whose exit codes are a documented interface.
- `unzip` exit **1** means "warnings, and the extraction succeeded". It was
  refused as "not the archive its extension claims", which is both wrong and
  wrongly worded. Exit 11 ("no matching files") is now its own sentence too.
- `release finish` computed the tag name before consulting `--no-tag`, so a run
  that had just decided not to tag could refuse over the name it would not
  write. The `ProjectException` handler also still prefixed every message with
  `--app-dir:`, which this version made a lie — config and tag-naming errors
  now reach it too, and were being blamed on a flag the operator had not passed.
- `tag.upload.format` without `tag.upload.enabled` validated the format and then
  wrote nothing. It is refused as the contradiction it is; defaulting it *on*
  would hand a repository a push-credential requirement it never asked for.


### The cross-check runs at `manifest write` too, not only at upload

The design said *both* chokepoints and only the upload one was built, so
`manifest write` printed no cross-check line at all — meaning "no reader for
apk" and "checked and agreed" were the same output, one command away from where
that distinction is the entire point. Reported by a second consumer wiring the
writer.

It runs **before the file is written**, so a mismatch leaves no manifest rather
than a wrong one on disk for somebody to find and believe.

### A collision now has an exit code a shell can see

`UploadCollisionException` has existed since 3.3.0 with a doc comment promising
it "gives the CLI a distinct exit code". Nothing mapped it, so the only thing a
wrapper could observe was `1` — indistinguishable from the failure release
scripts deliberately swallow (`|| exitCode=$?`, so re-running a release for a
build the store already holds is a no-op). A collision exited through that same
path and the release finished green having published nothing.

`uploadCollisionExit` is **3**. A `ReleaseException` now also prints its sentence
and exits 1 rather than escaping as an unhandled Dart error, because forty
frames of stack bury the one line an operator needs.

### `tag.release` — `release finish` stops hardcoding its tag name

```yaml
tag:
  release:
    enabled: true          # default, unlike upload
    format: v{version}     # default
```

The name was `'v' + version`, in the source. A repository whose releases are
named `rel/1.2.3`, or carry a platform prefix, needed a fork. `{build}` is
optional here and *required* in `tag.upload.format` — a release names a version,
an upload record names one upload of it.

`--no-tag` overrides `enabled: true`, and the log says which asked: `not
tagging: --no-tag` against `not tagging: tag.release.enabled is false`. A flag
and a config key answering the same question is how a setting comes to appear
inert.

### `.apk` cross-check

Binary XML (axml) — a chunked format with a string pool, structurally unlike the
`.aab`'s protobuf, so a second reader rather than a tweak. Verified against a
real profile `.apk` and `aapt2 dump xmltree`, which agreed on `versionCode 1`
and `versionName 1.1.0-profile`.

The trap it sets, and the reason the type has to decide where to look: reading
the `data` word for a *string* attribute yields a pool index printed as a
number — a plausible wrong answer rather than a failure.

Both string-pool encodings are now covered by tests. The UTF-16 branch had
none — not from the fixtures here, which build UTF-8 pools, and not from the
three production `.apk`s it was validated against, which are all UTF-8 — so it
shipped on the strength of the spec alone. The two layouts share nothing: UTF-8
stores two lengths per string and UTF-16 stores one, counted in different units,
with a different continuation bit. Non-ASCII cases are in both, because ASCII is
exactly where the encodings agree and an ASCII fixture cannot tell a working
reader from a lucky one.

### A reader that cannot read is no longer reported as no reader at all

`readApkFacts`, `readAabFacts` and `readIpaFacts` returned null when the archive
could not be opened — and null upstream means *this format has no reader*. So a
missing `unzip`, a truncated download, or a file that is not the archive its
extension claims all printed `cross-check: no reader for aab — build number and
version name taken on trust`: a sentence that reads like ordinary operation,
while the check silently stopped running for the rest of that machine's life.

Failing to read now raises, naming the cause. Null is reserved for the formats
that genuinely have no reader (`pkg`, `dmg`, `msix`, `snap`, `deb`, archives),
which stay trusted-out-loud as before. Reported by Copilot, which raised it as a
suppressed comment on the review.

Separately, an archive that opens but carries neither value now reports *that* —
`carried neither value — taken on trust`, naming the file it read — rather than
falling back to the no-reader sentence.

### A tag format that wants a build number and has none is refused

`tag.release.format` is checked for `{version}` at parse time, but `{build}` is
legal there and whether a build number exists is a property of the invocation
rather than the file. The substitution filled it with an empty string, so
`v{version}+{build}` under `release finish` wrote and pushed `v1.2.3+` — wrong
by one trailing character, in a name nobody reads twice.


### `provenance:` is now `tag:` — **breaking, and free**

```yaml
tag:
  upload:
    enabled: true
    format: uploaded/v{version}+{build}    # default
```

**There is no compatibility window, and the failure is total rather than
partial.** Neither version accepts both spellings and there is no alias: 3.4.0
knows `provenance` and not `tag`, 3.4.1 knows `tag` and not `provenance`, and an
unknown top-level key stops *every* command — not only the ones that write a
tag. So the constraint and `.cux-ship.yaml` must move in **one commit**, and
afterwards there is no version to fall back to without editing the file back.

This is the opposite shape from 3.3.0 → 3.4.0, where constraint-first was
survivable because the newer version tolerated the block being absent. Raised by
a consuming repository that was about to migrate and read the code rather than
the notes to find it out — which is the wrong way round, and why it is written
here now.

`provenance` was specialist vocabulary twice over: the art world's word for an
object's ownership history, and — in software — the supply-chain term for
*signed* attestations (npm `--provenance`, SLSA, sigstore). A reader arriving
from the second expects a transparency log and gets one annotated git tag. A
name that promises more than it delivers is worse than one that says nothing.
Every comparable tool calls this a tag: fastlane's `add_git_tag`,
semantic-release's `tagFormat`, Maven's `tagNameFormat`, npm's
`git-tag-version`.

**Breaking in name only, and safe to break**: the feature never worked (below),
so no repository has it set in anger.

`tag:` is a namespace for every kind of tag this tool writes, not just uploads.
**`tag.release` lands in this same version**, so `release finish` no longer
hardcodes `v{version}` — a repository whose releases are named `rel/1.2.3`, or
carry a platform prefix, stops needing a fork. It is enabled by default, where
an upload record is opt-in, because a release tag is what this tool has always
written.

Singular `tag:` rather than `tags:` because the config's own convention is
plural-holds-a-list (`locales`, `screenshots`), singular-holds-a-map (`play`,
`appstore`).


**`provenance.record-uploads` recorded nothing unless `--commit` was typed by
hand** — which is every caller using `--manifest`, the flag whose whole purpose
is supplying that commit. So the feature has never worked for its intended
caller since it shipped in 3.3.0.

The guard asked `ArgResults.options.contains('commit')`, which holds what was
*provided or defaulted*. What it meant to ask — and what its own doc comment
says — is whether the subcommand *declares* the option, so that a parser without
it is skipped rather than interrogated. Those two disagree exactly when an
option exists and was not given, which is the case that matters.

Nothing failed. The guard returns early and silently, so `record-uploads: true`
read as working for as long as nobody went looking for the tag. Found by turning
it on in a real repository, uploading, and finding no tag.

## 3.4.0

**The pre-release becomes a release.** `3.4.0-dev.1` was published so the
repository driving these changes could use them before the flag names settled;
they have settled, and a second project has now wired the same commands into its
own release path. Everything below landed under that pre-release or after it.

### `manifest write --derived-from` — a repackaged artifact inherits its provenance

```bash
cux_ship manifest write --artifact authpass_1.9.15_amd64.deb \
  --platform linux --format deb \
  --derived-from authpass-1.9.15.tar.gz.manifest.json \
  --packaging gitSha=bbbb1111 --packaging repo=authpass-deb
```

No build facts retyped. The `.deb`'s manifest carries the *tarball's* `gitSha`,
`dirty`, `versionName` and `buildNumber` as its own, because build-manifest.md
requires inherited facts hoisted to top level always — a reader that knows
nothing about derivation must still get true answers from the fields it already
reads.

**The flag takes the parent's manifest, not a hand-assembled entry.** The spec
says a repackager writes `[parent] + parent's own derivedFrom`; making each
producer implement that is how one producer's version of it ends up subtly
wrong. Pointing at the parent lets the chain build itself, and it stays flat and
nearest-first through however many steps — a `.snap` from a `.deb` from a
tarball records both ancestors and still reports the tarball's commit.

**The parent is digest-checked when its artifact sits beside its manifest**,
which is the normal case after downloading both. An artifact and its sidecar
upload non-atomically, so a fetch can straddle the two; this turns that skew
into a loud refusal rather than a chain that records a derivation from bytes
nobody has.

Explicit flags still win, so a repackager that genuinely knows better can say
so — but it has to say so.


### The manifest is checked against the artifact, not only against its digest

```
==> how-it-went-1.1.0-65.aab — build 65 of 1.1.0 from bd8d32f…, digest verified
    cross-check: build number and version name agree with base/manifest/AndroidManifest.xml
```

The digest proves the bytes are the ones the manifest was written for. It cannot
notice that the *build* disagreed with the values the script passed — an export
step rewriting `CFBundleVersion`, a Gradle override, a variable that evaluated
empty, a stale artifact copied over a fresh manifest's neighbor. In all of those
the manifest honestly describes the wrong artifact and every upload flag is
correct.

That check existed, at the store: Play parses an uploaded bundle and reports its
versionCode, and `play upload` compares afterwards. Right answer, learned after
transferring 69 MB. `verify()` now reads the values out of the artifact it is
already holding — **0.77 s including VM startup**, on a real 69 MB bundle.

| Format | Read from | How |
|---|---|---|
| `aab` | `base/manifest/AndroidManifest.xml` | zip entry + a minimal aapt2-proto walk |
| `ipa` | `Payload/*.app/Info.plist` | zip entry + `plutil` |
| everything else | — | **trusted, and said so out loud** |

**A format with no reader prints that it was trusted.** `cross-check: no reader
for pkg — build number and version name taken on trust` is a different line from
success, because "not checked" and "checked and fine" must not render the same.

The `.aab` walk needed no `bundletool` and no Java. Neither that nor `aapt2` is
necessarily installed, and `aapt2 dump xmltree` refuses an `.aab` outright, so a
hundred lines of Dart is not a shortcut around a heavier tool — it is the only
local option. The walk is two levels deep rather than five: `XmlAttribute.value`
already carries `"65"` as a string beside the compiled integer, so nothing
decodes `Item` or `Primitive`.

Reading and deciding are separate functions. Getting bytes out of a zip needs a
zip; deciding what a disagreement means does not, and a test that must build an
`.aab` to assert on a comparison is one nobody writes the third case for.


### Two defects a real upload found, and one refactor

**A placeholder build number is refused.** `buildNumberAssigned: false` says
allocation failed and the number is a stand-in. The field was read, written and
printed as `UNASSIGNED`, and `verify()` never acted on it — so the only guard
anywhere was a shell `if` in one consuming repository, and every other
`--manifest` caller would have shipped build 0. A specified refusal that exists
everywhere except in the code is the worst kind: the field's presence is what
stops anyone looking. No override; `--allow-dirty` does not wave it through.

**The build number could become the version name.** The Play path resolved
`opt('version-name') ?? buildNumber ?? defaults.versionName`, so with the flag
omitted Play would have taken a release named `65 (65)` — and the changelog
lookup went after a section headed `65`, failing with *"CHANGELOG.md has no
section for 65"*. The message named the wrong thing, so the fix an operator
would reach for is adding a `## 65` heading. Unreachable while every caller
passed `--version-name`; reachable the moment one switched to `--manifest`, and
found on the first real upload through that path. Now
`resolveVersionName({explicit, fromManifest})`, a signature with nowhere to put
a build number.

**Versions are parsed into `Version` (pub_semver).** The bump path hand-rolled
`^(\d+)\.(\d+)\.(\d+)$` and answered two questions with one pattern: what is
a version, and which versions this will bump. `1.0.3-beta` and `1.0.3+41` are
valid semver and are still refused — that is policy, not parsing, and it now
reads as a check on `isPreRelease` and `build`. The two failures report
differently. `pubspecVersion` returns `Version?` and `FinishOptions.version` is
a `Version`, which removed an `Object` inference in `runner.dart` where a
`String?` and a `Version?` met in a `??` chain.

Ordering comes with the type: `1.0.10` above `1.0.9`, and build metadata
excluded from precedence — the rule `vX.Y.Z+<build>` tags depend on. The
dependency was already in the lockfile transitively, so nothing new enters
anyone's graph. `cux_ship_verify` stays zero-dependency.


### `verify` finds a split App Store tree, and checks both halves

A repository shipping to both Apple platforms keeps `store/appstore/ios` and
`store/appstore/macos`. The default resolved to their *parent*, which holds a
README and two subdirectories and nothing a validator recognizes — so a bare
`cux_ship verify` reported `store/appstore holds no info/, no listings/ and no
age-rating.json — nothing to publish` on a repository that was entirely fine.

**A check that cries wolf on a healthy repository is how people learn to skip
the check**, which is the failure the offline verifier exists to prevent,
committed by the verifier. Reported by a second project hitting it during a
real release, where the workaround was three invocations naming each tree.

Now: a split layout is found and **every tree is checked in one run**, each
against its own platform's rules. `--platform` narrows to one, and is still
required alongside `--appstore` when two platforms are declared — one path
cannot say which platform it is, and applying the wrong one refuses a macOS
listing for lacking iPhone screenshots.

`--changelog`, `--appstore`, `--play` and `--data-safety` now render as
`--changelog=<path>` in the usage, and the stale "Defaults to store/appstore"
help texts say what the defaults now do.

### `cux_ship manifest write` — one producer for the file every upload is named by

```bash
cux_ship manifest write --artifact dist/how-it-went-1.1.0-53.aab \
  --platform android --format aab \
  --version-name 1.1.0 --build-number 53 \
  --git-sha "$SHA" --no-dirty
==> wrote dist/how-it-went-1.1.0-53.aab.manifest.json
      android/aab  1.1.0 (53)  d9c394b  sha256:8f3ac91b0d24
```

`--manifest` gave this package a reader in 3.4.0-dev.1. The file it reads was
still written by a shell heredoc in each consuming repository — so the schema
existed twice in prose and nowhere in code, and a field one of them omitted was
invisible until an upload weeks later published an artifact described by the
wrong numbers. The round trip is now a test rather than a convention.

Three things it refuses, each earned:

- **The digest is computed here, never passed in.** Taken from the artifact as
  it stands, so a digest recorded before signing cannot be written at all.
  Otherwise that fails verification on every real release rather than never.
- **`--dirty` has no default.** It must be given as `--dirty` or `--no-dirty`,
  because a build script that forgot the flag would certify every dirty build
  as clean and nothing downstream could tell.
- **A short `--git-sha` is refused.** The reader normalizes whatever it is
  given, which is exactly what lets a seven-character sha survive here and
  break a tool that does not.

`--git-sha` and the dirty flag are inputs and are never derived, because this
runs *after* the build: a tree that moved in between would be invisible here
and wrong in the file. The build knows both when it starts and passes them down.

`--out` renames the manifest **within the artifact's own directory**, for a
build that keeps one artifact per platform directory and wants a fixed
`manifest.json` its uploader can name without globbing. Anywhere else is
refused: the artifact is recorded as a basename resolved against the manifest's
directory — which is what keeps a `dist/` tree movable between machines — so a
manifest written elsewhere parses cleanly and then cannot find its artifact.

`buildNumber` is written as a **JSON integer**, which is what the schema always
said and what the first writer got wrong — it emitted a string. Nothing failed,
because the reader stringifies whatever it finds; that is exactly how a spec and
its only implementation drift apart with every test green. A value that is not
an integer is now refused rather than coerced.

### Manifest schema 2

Read alongside schema 1, which stays readable for as long as anything writes
it — refusing it would strand every `dist/` already on disk, and a reader that
cannot read yesterday's build is one nobody can adopt one repository at a time.

New fields, all optional: `flavor`, `builtAt`, `producer`, `toolchain`,
`gitTag`, `buildNumberAssigned`, `packaging`, `derivedFrom`, and `x` for
repo-local keys that no shared tool reads. Schema 1's `variant` is renamed
`format` and both spellings are read — *variant* means flavor-plus-buildType in
Gradle, and one consuming repository has six flavors that share a version *and*
a build number, so the two needed separate names.

`buildNumberAssigned: false` says the number is a placeholder because allocation
failed, so an upload can refuse it rather than ship under a number that means
nothing. Absent reads as true: a schema-1 manifest never carried the field and
is not claiming otherwise.

## 3.4.0-dev.1

**A pre-release**, published so the repository that drove these changes can use
them before they are settled. The three additions below are in use but not yet
proven by a second consumer; treat the flag names as provisional until 3.4.0.

### `--manifest` — name the build once, and check it

```bash
cux_ship appstore upload --platform ios --manifest dist/ios/manifest.json
==> how-it-went-1.1.0-51.ipa — build 51 of 1.1.0 from fef65ce, digest verified
```

Supplies `--artifact` (or `--aab`), `--build-number`, `--version-name` and
`--commit` from a build manifest written beside the artifact. Explicit flags
still win — a manifest is inference, and inference loses to what was typed.

It **verifies the artifact against the digest the manifest records**, which is
the part no flag can give you: every argument can be correct while the bytes
belong to a different build — a `dist/` edited, half-written, or left from an
earlier build whose manifest was replaced without its artifact being rewritten.
A manifest recording a dirty tree is refused unless `--allow-dirty`.

Schema 1; an unknown schema is refused rather than read optimistically.

This reverses a stated decision — both store libraries said they knew nothing
about manifests, on the grounds that a project's upload script had already
checked one. That held while every project had such a script. It stopped when
provenance moved into this tool in 3.3.0, since a record of which commit shipped
cannot be written by a command forbidden to know the commit; and it never held
for the Apple side, where no such script has ever existed.

### Recording which commit an upload came from

`play upload` and `appstore upload` can write an annotated tag naming the commit
an artifact was **built from**, before contacting the store. Off unless declared:

```yaml
# .cux-ship.yaml
provenance:
  record-uploads: true
```

Off by default because recording pushes a tag to `origin`, so enabling it for
every consumer would turn a missing push credential into a total upload block
rather than a skipped record.

The default name is `uploaded/v{version}+{build}`, and the namespace is a
correctness property rather than a preference: a release guard that asks "has
this version shipped" by taking the highest `v*` tag reads a bare `v1.0.4+56` as
a released 1.0.4 — `sort -V` ranks build metadata *above* the version it
annotates — and then refuses to build 1.0.4, naming a release that never
happened. Override with `provenance.tag`, which must contain `{build}`.

The tag records an upload **attempted**, not accepted: it is written before the
store is contacted, so a signature refusal leaves it standing over an artifact
nobody received. That is the right trade — the alternative failure mode is
*shipped but unprovable* — but consumers must read these as attempts.

### `release refspecs`

`refs/buildnumbers/*` and the build-number notes ref sit outside `refs/heads`
and `refs/tags`, so a clone's default refspec ignores them and a fresh clone has
no allocation history until something fetches it explicitly. Run once per clone.
It appends to `remote.<remote>.fetch` and never replaces it.

## 3.3.0

**`release finish` now refuses a tag that names a different commit, and pushes
one it finds already there.** Both are behavior changes on a path every release
runs, so read this before upgrading — nothing else in this release is reachable
from the command line yet.

### A failed tag push used to be permanent

The tag was pushed only on the run that *created* it. So a run whose push failed
— an expired token, a runner without the route, a network blip — left a tag that
no later run would ever publish: every repeat found it locally, logged
`v1.0.3 already exists at abc1234 — leaving it alone`, and finished green while
the remote never got it. The release then had no tag anywhere a later reader
would look, and nothing said so.

The push now runs whether or not this invocation created the tag. Pushing a tag
the remote already holds at the same commit is a no-op; pushing one it holds at
a *different* commit is rejected, which is the collision below arriving from the
side a local check cannot see. The `— leaving it alone` half of that log line is
gone, because it was no longer true.

### An existing tag at another commit is now an error

It used to log and carry on, **including the version bump**. One version
recorded against two commits is one of them being wrong, and continuing left
whichever it was standing as the record of what shipped. It now throws, in
`--dry-run` too, and the bump does not happen.

If you have a release in that state, the fix is to decide which commit shipped
and retag deliberately. This refuses rather than choosing for you.

### Commit arguments are resolved before they are compared

`--commit HEAD` and `--commit abc1234` used to work on the first run and fail on
the second. The tag side of the comparison is `rev-parse` output — always a full
40-character SHA — while the other side was whatever you passed, so the
*legitimate repeat* was reported as a version naming two commits. That
accusation is the loudest error this command can raise and it was false.

Both sides now go through the same resolution, which also turns a commit that is
simply absent from a shallow clone into a message saying so, instead of git's
`fatal: bad object type.`

### Internal: recording what reached a store

`recordUpload` writes an annotated tag naming the commit an artifact was **built
from**, so a build number still resolves to a commit after `git gc` has taken
the branch that contained it. It is not wired into `play upload` or `appstore
upload` yet and there is no way to reach it from the CLI in this release; it is
published now so the repositories that will call it can be built against it.

Two things worth knowing before that wiring lands, because both change how a
caller has to behave:

- **The tag records an upload *attempted*, not accepted.** It is written before
  the store is contacted — tagging afterwards would make the failure mode
  "shipped but unprovable" — so a signature refusal leaves the tag standing over
  an artifact nobody received. Anything reading these tags must read them as
  attempts.
- **A collision throws `UploadCollisionException`**, distinct from an ordinary
  `ReleaseException`, so a wrapper can tell it apart. Release scripts routinely
  call the upload under `|| exitCode=$?` so that re-running a release for a
  build the store already holds is a no-op. A collision exiting through that
  same path would be downgraded to a tolerated failure and the release would
  finish green with the loudest error unreported.

## 3.2.1

**Every `appstore` subcommand crashed in 3.2.0 if the repository declared an
`appstore:` block.** Upgrade immediately; 3.2.0 should not be used.

```
Unhandled exception:
Invalid argument(s): Could not find an option named "--require-screenshot-type".
#1  _derivationProblem (package:cux_ship/runner.dart:1535:12)
#2  _AscSubcommand.run (package:cux_ship/runner.dart:190:15)
```

`upload`, `promote`, `wait`, `builds`, `versions`, `signing` and
`screenshot-types` all died before doing anything. Nothing reached Apple and
nothing was published wrongly — the command could not start. `verify` and the
whole Play side were unaffected.

`_derivationProblem` read `--require-screenshot-type` out of `ArgResults`. That
option is declared on `verify` alone; the function was also wired into the App
Store path, where `argResults` is a parser that has never heard of it.

**And 3.2.0 left no way back.** A repository that adopted the declaration could
neither upload on 3.2.0 nor fall back to 3.1.0, which refuses the config
outright:

```
--app-dir: .cux-ship.yaml has unknown keys: appstore, play
    known keys: app-dir, apple
```

3.2.0's own notes said to land the constraint bump and the config in one commit.
That is right for *migration ordering*, and it removes the *rollback* — which
those notes did not say and should have. Anyone who followed them was stuck on
both sides until this release.

### The fix, and why it is not the one-line guard

`_derivationProblem` takes the flag's value as a parameter now instead of
reading it. `verify` passes what its flag supplied; the App Store path passes an
empty set, because it has no such flag.

Guarding the read — `args.options.contains(…)` before `multiOption` — works, and
leaves the function still asking a question about a parser it does not own,
which is the same trap for the next helper shared across two commands. Declaring
the option on the App Store parser would grow the CLI surface to fix internal
wiring. A parameter makes the question unaskable.

### Worth saying plainly

**The crash was in the error-reporting path 3.2.0 added to close a silent-pass
hole.** That guard existed to make an underived screenshot requirement loud
rather than silent; instead it killed the command and named a flag the user
never passed. A check that cannot start is not a stricter check.

And the ordering is the general lesson, in the words of the project that hit
it: **loudness added at the wrong layer is quieter than what it replaced.** The
guard ran before the validation that would have produced a useful message, so
it did not merely fail to help — it hid the thing that would have.

It shipped because no test ran a subcommand against a repository that declares a
store block — the crash needs one to fire, and every fixture in this package had
none. `test/subcommand_smoke_test.dart` now starts every subcommand against both
shapes: a repository declaring `appstore:` and `play:`, and one declaring
neither. It asserts only that a command gets past argument handling and into its
own body, which is the whole class of failure this was.

Found by a consuming project, one command after adopting the config, by somebody
doing something unrelated.

### `3.2.1` means uploads tell you the truth, not that they succeed

If a project has an interpolated `PRODUCT_BUNDLE_IDENTIFIER` — per-configuration
suffixes, `design.codeux.example$(BUNDLE_ID_SUFFIX)` — the next thing it meets
is 3.1.0's refusal:

```
PRODUCT_BUNDLE_IDENTIFIER in ios/Runner.xcodeproj/project.pbxproj is
'…$(BUNDLE_ID_SUFFIX)', which Xcode expands at build time and this can only
read as text — pass --bundle-id
```

That is correct and is not a regression: `--bundle-id` is required for those
projects and always was. But 3.2.0's crash fired *before* it, so two blockers
were stacked and only the second becomes visible once this release removes the
first. Nothing further is broken; there is simply a second thing to pass.

## 3.2.0

**A repository can declare what its listings must carry, and `verify` reads it.**

```yaml
appstore:
  locales: [en-US]
  screenshots:            # optional — derived when absent
    ios: [APP_IPHONE_67, APP_IPAD_PRO_3GEN_129]
play:
  locales: [en-US]
  screenshots: [phoneScreenshots, tenInchScreenshots]
```

`--require-screenshot-type` and `--require-locale` never varied between runs;
they vary between apps, which is what `.cux-ship.yaml` is for. Three consuming
repositories had each hand-written the same wiring to say them.

### **Breaking, in a minor. Read this one.**

**A project that has a listing tree and does not declare it now fails
`verify`.** Semantically this is a major; it ships as a minor deliberately,
because the alternative is a major every few days and a version number that has
stopped carrying information. The compensation is that the break is loud, early,
and says what to do:

```
.cux-ship.yaml: appstore: is not declared, and store/appstore exists — so the
tree is checked but nothing says which locales it must carry […] Declaring
appstore has been required since 3.2.0: add appstore.locales, e.g.
locales: [en-US]
```

The failure names **the version that introduced the requirement**, because the
question a reader actually has is not *what is missing* but *why did this work
yesterday*.

**Nothing checks less than it did before.** A present tree is still validated
against everything intrinsic to it, declared or not — an upgrade that quietly
checked less would be the exact failure this release exists to remove. What the
declaration adds is the one thing that cannot be inferred: which locales the
listing must carry, so that one silently disappearing is noticed.

**Take this bump in a commit that also adds the config**, in the same way the
secrets file moves with a constraint that admits a new shape.

### `verify` gains the Play half

`--play`, `--data-safety`, and the checks behind them. Play was covered for
release-note length and nothing else.

**`data-safety.csv` is the reason this release is ordered the way it is.**
`play upload --dry-run` discards its edit rather than validating it, and skips
the declaration outright; a real run sends it as a separate POST, deliberately
after the commit, because it is not versioned with a release. That ordering is
right and cannot be changed — so a broken declaration fails *after* the release
is public, and an offline check is the only place it can be caught at all.

Structure, never content: whether the answers are *true* is a question about a
particular app, and this cannot answer it. There is also nothing to specify —
the file is Play's own export and every row states its own answer requirement.

### Screenshot types are derived from `TARGETED_DEVICE_FAMILY`

`{APP_IPHONE_67, APP_IPAD_PRO_3GEN_129}` is Apple's current requirement for a
universal app, not a fact about any app: the 6.7" class replaced the 6.5" one.
A project holding those names in its own config holds a value that ages into a
rejection after upload; one derived here is fixed for everybody by taking a new
version. `appstore.screenshots` overrides it when Apple and this table disagree.

macOS has no `TARGETED_DEVICE_FAMILY`, so that side is a constant rather than a
lookup — two mechanisms behind one word, said out loud.

`TARGETED_DEVICE_FAMILY` gets 3.1.0's refuse-on-ambiguity rule. It is the same
multi-target shape that forced `PRODUCT_BUNDLE_IDENTIFIER`'s.

### The declared requirements are enforced on `appstore upload`, not only in `verify`

A requirement that is a property of the repository and is honoured by one
command out of two reads as a standing fact and is not one. `upload` is the
command that reaches Apple.

### Listing URLs are checked for reachability, and never block

A privacy policy URL that 404s is a rejection, and the site is usually deployed
by a different command than the app. This runs on the upload path, always, and
**reports rather than fails**: a URL can be legitimately dead at exactly one
release — a policy site deployed after the app — and a gate there would fail
correctly and teach the bypass.

It is not in `cux_ship_verify` and never will be. That package has no
dependencies and makes no network calls, and `verify --help`'s "No network, no
credentials" is an **invariant**, not a description of what it currently does.

### Two checks were written, run against a live listing, and deleted

Both would have failed a listing a store is serving right now:

- *a response id belongs to one question* — Play reuses them across questions by
  design. 22 problems on an accepted declaration.
- *an enumerated set of answer requirements* — exports also use `SINGLE_CHOICE`
  and `OPTIONAL`. 88 problems.

Play's published "longest side at most twice the shortest" is absent for the
same reason. A 20:9 phone capture is 2.22:1, and the reductio needs no
counterexample: Play *mandates* a 1024x500 feature graphic, which is 2.048:1.

**A check that fails what a store accepts is worse than one that passes
vacuously**, because the first response to a red board over a live listing is to
find the flag that turns it off. No dimension or length rule should ship without
being run against a real listing and asked whether it would have failed
something already published.

## 3.1.0

**Inference refuses an ambiguous project instead of taking the first match.**
`PRODUCT_BUNDLE_IDENTIFIER` and `DEVELOPMENT_TEAM` are read from the Xcode
project as before when the project names one of them. When it names several,
the command stops and lists them rather than picking.

**The one thing to check on upgrade**, because a caret constraint takes this
without asking: a project that was inferring by luck now needs a flag. It stops
at the start of a release rather than partway through, and names the project and
the candidates — but it can stop a run that worked yesterday. Two real projects
were relying on that luck, in different ways and neither visibly:

- One puts an app extension's target first, so the first match was the appex
  rather than the app. Its uploads were correct only because the release script
  passes `--bundle-id` — remove that flag and it would have talked to Apple
  about the extension.
- One interpolates `design.codeux.howitwent$(BUNDLE_ID_SUFFIX)`, which Xcode
  expands at build time and this can only read as literal text. Apple answered
  404 for an app by that name, which sends you to look at the app record and
  the API key before the project.

`head -1` on a file that may legitimately name several things is not a rule,
it is a coin toss that has been landing the same way.

### The refusal says which failure it is

Three situations a single null cannot tell apart, so they no longer share a
message: nothing could be read, several were read, or the one that was read is
not literal text. Only the first is answered by *pass the flag*. Reporting the
others as the first is what sends someone to check their credentials — the
sentence has to name the project, or the afternoon goes elsewhere.

An absent iOS project is unchanged and still just absent. That is ordinary, not
a problem, and "none could be read from the Xcode project" was already right.

### `secrets add certificate --from-keychain` defaults `--team`

From `DEVELOPMENT_TEAM`, as `keychain exec --team` already did. It was the last
value in an Apple setup still typed by hand, out of a file already being parsed
for the bundle identifier. A team retyped once a year during a certificate
rotation is where a transposition survives — the wrong one exports somebody
else's identity and surfaces much later as a profile mismatch that never
mentions the team.

`keychain exec --team` gets the ambiguity refusal too, and there it is a
tightening rather than a convenience: `expectTeam` is optional, so an ambiguous
project used to become an *unchecked* one. Silently dropping the check that
exists to catch a certificate from another account is a worse answer than the
guess it replaced.

### `--no-metadata` on `appstore upload`

Uploads the build and leaves the store listing alone.

Omitting `--metadata` never did this: the default is inferred from
`store/appstore` whenever that directory exists, so there was no way to put a
build on TestFlight without also publishing the listing. When the App Store
version is locked by review — `WAITING_FOR_REVIEW` or `IN_REVIEW`, both
ordinary states — the listing push fails with a 409.

It failed *last*. The binary and the TestFlight notes were already up, so the
command did everything asked and then exited non-zero, which invites the one
response that is wrong: run it again.

A TestFlight build is not a version submission and needs no listing. Apple
reviews the listing together with the version, which is why `upload` is where
metadata belongs and `promote` still never publishes it — that part is
unchanged and deliberate.

`--metadata` and `--no-metadata` together are refused rather than ordered.

## 3.0.0

**`keychain exec` gives its child the keychain it made and nothing else.**
Everything further is named at the call site:

```
keychain exec --profile ios_appstore -- tool/build.sh          # APPLE_KEYCHAIN only
keychain exec --only tokens.marks -- tool/build.sh             # and that token
keychain exec --only ssh_keys.github_deploy -- ci-release.sh   # and the deploy key
```

`secrets exec` is unchanged by default — it places everything, because a
general-purpose wrapper that hands over nothing is inert — and takes the same
`--only` when a caller wants to narrow it.

The selector is `family` or `family.instance`, comma-separated or repeated:
`tokens`, `tokens.marks`, `apple.certificates.distribution`.

### Why the default is nothing rather than something better

This replaces a hardcoded three-family withhold list that no caller could see,
extend, or ask for something different from. The obvious replacement was a
better default, and three were tried: "the minimum that signs", then "withhold
values and pass paths", then two rules applied per variable. Each needed more
structure than the last, ending in one rule, one guarantee and a seven-row
table.

The reason is structural rather than a failure to pick well. **A default has to
satisfy every consumer, so it is the union of their needs, and a union is wrong
for each of them individually.** A union has no explanation, only a membership
list — which is why it could not be written down in a way anyone could hold in
their head. A call-site selector is one consumer's own set, and it has a reason
that fits in the flag.

It also could not be derived. `keychain exec` wraps a *build script*, so what
that script consumes happens below this command's arguments — in one real case
four layers down inside a function, with the variable's name in a `printf`
format string. A rule of "do not withhold a credential whose variable appears in
the command line" was proposed and would have withheld the one token that must
never be withheld: it failed on the example it was designed around.

### `SOPS_AGE_KEY` is stripped from `keychain exec`'s child

Unconditionally, with no way to readmit it. It is the master key to the whole
file, value-shaped, and not a credential *in* the file — so no selector can name
it and no default covered it, while an Xcode script phase writes the whole
environment into a build log.

Nothing outside cux_ship reads it. The one composition that did — a nested
`secrets exec` inside a `keychain exec` child — is replaced by running the two
as siblings, which is a change in the consuming project rather than here.

This is also what makes the archive guarantee true rather than nearly true. A
child that could decrypt the file could mint the App Store key the archive is
meant not to hold.

### Check the advice your own tooling prints

This release changes no message cux_ship prints. It can invalidate messages
**you** print. Grep your own scripts for a remedy naming `keychain exec` without
`--only`:

```
no temporary keychain — run this through `cux_ship keychain exec`
```

Correct for years, and incomplete at 3.0.0. Someone who follows it gets a
keychain, clears that check, and dies further down on the credential the empty
default no longer places — one error handing them to the next, each true on its
own. Name the whole invocation instead, `--only` included.

The asymmetry is what hides this. Advice naming `secrets exec` survives
unchanged, because that command kept its everything default; only `keychain
exec` moved. The two read as the same kind of sentence, so a sweep for one does
not suggest a sweep for the other.

Worth doing even though your build passes. The loud version of this failure is
the lucky one — a later check that refuses outright. Where the credential is
read by something that merely carries on without it, an optional feature quietly
staying off or a signing step choosing a different identity, nothing fails and
the sentence that sent them there still reads as correct.

### Behaviour worth knowing

- **A selector that does not resolve is fatal, and the three mistakes get three
  messages.** Unknown to the schema, a named instance absent from the file, and
  a section named instead of a family are different errors; telling someone
  their spelling is wrong when it is not sends them looking in the wrong place.
- **A known family that is empty in this file is reported, not fatal.** Naming a
  family is a scope; naming an instance is an existence claim. That is the line
  `decideProfile` already draws.
- **Resolution is against what the process holds, not the file.** Under
  `secrets exec --only x -- keychain exec --only y --`, the inner command asking
  for something the outer stripped fails there, naming it, rather than four
  layers down inside a build. A partial match is fatal too.
- **Selection removes, it does not merely decline to place.** An outer wrapper
  has already put everything in the environment before an inner one runs.
- **`--keystore` and `--api-key` are refused alongside `--only`**, which already
  names the instance they exist to choose. `--only apple.profiles.*` is refused
  pointing at `--profile`, and `placed.*` pointing at `secrets place`.
- **`secrets exec --only` warns when it omits a keystore the file holds.** A
  missing Android keystore is the one absence that is silent: Gradle falls
  through to the debug key and produces an artifact only the store rejects.

### Fixed on the way

`secrets exec` never passed `includeParentEnvironment: false` to its child.
`Process.start` merges the map into the parent's environment, so anything
removed from the map came back. It had never removed anything, so it had never
needed the flag — and the moment `--only` gave it something to remove, the
removals silently did nothing. `keychain exec` has carried the flag, and a
comment warning about exactly this, since 1.9.1.

## 2.3.2

- **An App Store Connect error that blocks a submission now says where to fix
  it.** "Unable to Add for Review — an Admin must provide information about the
  app's privacy practices in the App Privacy section" stops a release and names
  no remedy, and the natural reading of an API error is that the caller sent
  something wrong. The printed failure now adds the console path, that an
  **Admin** must do it (a Developer-role account cannot, which the error does
  not say), and that it is per *app* rather than per version.

  It also says plainly that cux_ship cannot check this in advance and will not
  pretend to. **App Privacy is absent from the App Store Connect API** — not
  readable, not writable — so nothing here can tell you the section is
  incomplete before Apple does. That was checked rather than assumed: Apple's
  API index enumerates the areas it automates and privacy is not among them,
  the `App` resource carries `appEncryptionDeclarations` and
  `accessibilityDeclarations` and nothing for data usage, and fastlane's
  privacy action authenticates with a web session because the endpoints are not
  in the official API.

  Only this one error is annotated. An error that already names its field is
  actionable as printed, and a paragraph on every failure trains people to stop
  reading the paragraph.

## 2.3.1

- **`Platform` is extracted as `xml1` rather than `json`.** On a `macos-15`
  runner `plutil -extract Platform json` exits 1 with empty stderr — not an
  absent key, not a malformed profile, a subprocess that fails and says
  nothing. `keychain exec --profile` therefore refused every provisioning
  profile on that runner, which is every GitHub job using `macos-latest` at the
  time of writing.

  Measured on a real runner rather than predicted, and found in one line
  because 2.3.0 had already stopped reporting a failing `plutil` as an absent
  key. The old message asserted the one thing that was false; the new one named
  the command, the exit code, and the absence of any explanation to pass on.

  This is the second failure of `-extract … json` on that OS — the first was
  `DeveloperCertificates`, an array of `<data>` which JSON cannot represent and
  plutil refuses outright. `Platform` is an array of *strings*, which JSON
  represents perfectly well, so the two have no cause in common except the
  format. `xml1` works on both macOS versions. `UUID`, `Name` and
  `ExpirationDate` stay on `raw`, which has never failed and is unambiguous for
  a scalar.

## 2.3.0

- **`cux_ship secrets add`** puts a credential *into* the file. Until now
  `secrets` could read one five ways and write one — `pack`, and only for a
  `placed` file `place` had already written — so adding a certificate, a
  profile or a token meant a hand-rolled `ruby | sops set` pipeline in every
  project. Those encode the schema path by hand, write one field at a time so
  an interrupted run leaves a half-credential, and hand `sops set` a bare
  string when it wants JSON — which is accepted, stored wrong, and
  authenticates as garbage.

  ```
  secrets add certificate distribution dist.p12 --password-file pw
  secrets add profile ios_appstore app.mobileprovision
  secrets add api-key upload ~/Downloads/AuthKey_ZHGL57YJVC.p8
  secrets add token artifact --env ARTIFACT_TOKEN --value-file tok
  ```

  A name and an artifact, positionally. **No `--p12` / `--p8` / `--file`: the
  artifact is identified by its contents.** That names the real mistake rather
  than the wrong flag, and catches a correctly named file with the wrong thing
  inside — which happens, because people rename downloads. An api key's `id`
  and `kind` are read back out of Apple's `AuthKey_`/`ApiKey_` naming, so the
  two fields most often got wrong are two nobody types.

  Every field of a credential lands in **one** write, making the partial state
  `secrets exec` refuses unrepresentable rather than merely reported. Adding
  over an existing credential is refused; `--replace` is the rotation verb.
  Passwords and values are never arguments, because an argument is visible to
  `ps`; a certificate's password is checked against the `.p12` before anything
  is written.

- **`cux_ship secrets check`** decrypts and reports whether each credential
  actually works, as **verified**, **failed** or **opaque** — the last being one
  this tool can never authenticate, such as a token. Only `failed` colours the
  exit code; an opaque credential is not an error and must not read as one, or
  the check becomes something people learn to skip past.

  Its unique value is the **cross-checks**, which no single-artifact command can
  perform: above all whether a stored profile still embeds a certificate the
  file actually holds. That is not derivable from either artifact alone — a
  Developer ID profile can outlive the certificate inside it by a decade, so its
  expiry says nothing about whether it still holds a usable certificate, and
  replacing a certificate silently invalidates every profile issued against it.

- **`cux_ship secrets remove`** retires one. Doing it by hand was the same
  failure class as adding by hand, at the worst possible moment — having just
  decided something is compromised.

- **Replacing a certificate names the profiles it invalidates.** Every profile
  issued against a certificate stops working the moment that certificate is
  replaced, and no artifact says so — the profile keeps its own expiry date.
  Established *before* the write, while the outgoing certificate is still there
  to fingerprint; afterwards the evidence is gone. When it cannot be
  established it says so rather than reporting that none were affected, which
  is a different claim and the only reassuring one.

- **`secrets add certificate --from-keychain`** builds the `.p12` out of a
  macOS keychain, with a generated password, for onboarding a machine that has
  an identity but no file. Ported from a shell version in a sibling project,
  for three traps it already encodes — each of which produces a file that looks
  correct: pairing the certificate with its key on `localKeyID` rather than
  `friendlyName` (macOS names the two bags differently, so a friendlyName
  filter yields a `.p12` that imports cleanly and cannot sign); matching the
  certificate *kind* as well as the team, since Apple Development carries the
  same `OU=`; and checking expiry on every candidate, because a keychain never
  sheds the expired ones.

- **Renames.** `secrets keys` is now **`secrets list`**: the file holds
  `api_keys`, `ssh_keys` and `keystores`, so "keys" read as a category rather
  than as the credential names it actually prints. `appstore await` is now
  **`appstore wait`**, taking the build number positionally — it was required
  anyway, and `await`/`builds`/`build-number` shared tokens while meaning
  unrelated things. `appstore upload` takes **`--artifact`**, with `--ipa` and
  `--pkg` as accepted spellings: `--platform macos` is first-class, so a macOS
  release passing its `.pkg` to a flag called `--ipa` read as though macOS had
  been bolted onto an iOS-shaped command, and `--pkg` — what anyone tries first
  — was rejected outright.

- **`deps update` is hidden from `--help`.** It re-pins cux_ship's own sources
  and refuses to run outside a cux_ship checkout, so to every consuming project
  it was a documented way to get an error. Still runs when typed.

- **A failing `plutil` no longer reads as an absent key.** The per-key loop
  recorded a value only on exit 0, so a tool that could not do what was asked,
  a key that is genuinely missing, and a plist that would not parse all arrived
  at the same message — and the one it printed named the least likely cause.
  That cost a consuming project an afternoon bisecting macOS versions to learn
  `Platform` had been present all along. The same bug bit again while building
  the cross-check, where `plutil -extract … json` refuses a `<data>` array
  outright ("Invalid object in plist for JSON format") and the empty result
  silently checked nothing.

## 2.2.0

- **`cux_ship appstore await`** exposes the wait that `appstore upload` already
  did internally. Uploading and waiting can now run on different machines,
  which matters because the wait is a poll against a REST endpoint that needs
  no Xcode, no keychain and no signing material — only the API key — while the
  runner that built the artifact is billed at 10× for being macOS. It also
  finishes `--skip-waiting`, which until now said a caller would wait later and
  left nothing to wait with.

  `--build-number` is required rather than defaulting to the newest build: the
  point of waiting elsewhere is to wait for a *specific* build, and "newest"
  would succeed on somebody else's upload. The three outcomes keep the meanings
  `upload` gave them — success, the 422 for a build Apple refused, and the
  timeout that names where the reason actually is.

- **Every certificate's remaining life is reported at import**, by
  `keychain exec`, in the words the developer-account audit already uses.
  A profile carries its own expiry and a certificate carries `notAfter`; they
  are independent, and nothing read the second. A profile valid for a year that
  embeds a certificate dying next week passed every check and failed inside
  codesign — and a project on automatic signing had no profile to check at all.
  Reported for every certificate imported, not only the one that signs, because
  an installer certificate expiring is a `productbuild` failure at the end of a
  Mac App Store run. A warning, never a refusal.

## 2.1.0

- **The App Store review contact comes from the environment**, as
  `APPLE_REVIEW_CONTACT_FIRST_NAME`, `_LAST_NAME`, `_EMAIL` and `_PHONE`, and is
  sent with every review-notes write.

  **Not from the metadata tree, and the asymmetry is deliberate.** Every other
  listing field is a file beside `info/`; a name, an e-mail address and a mobile
  number are one person's, they are the same person's across every project using
  this package, and at least one of those projects is a public repository. A
  phone number in git history outlives whatever the repository's visibility was
  on the day it was committed, and unlike a leaked key it cannot be rotated. The
  environment keeps the choice with each project — a sops file, a CI secret, a
  shell — which is where every other credential here already lives.

  All four or none: a partial set is refused before anything is written, since
  Apple wants them together. The phone is checked against the format Apple's own
  rejection describes — `+` then the country code — because that refusal
  otherwise arrives mid-push with several fields already landed.

  Sent on create *and* update, which is the part that is not guessable: creating
  a review detail with notes alone succeeds, and updating one is then refused
  without the whole contact. So the second push of an unchanged file failed
  where the first had worked.

- **`appstore upload --metadata` now publishes review notes**, from
  `review-notes.md` beside `info/` and `listings/`, into
  `appStoreReviewDetails.notes` on the version.

  **This is the piece of a listing whose absence costs a review cycle rather
  than a rejection.** An app with no content of its own — anything that needs
  the user's own files before it shows anything — opens to an empty screen, and
  a reviewer with no sample data concludes it does nothing. That comes back days
  later as "we were unable to evaluate your app", with nothing to fix, and it is
  invisible beforehand because every other part of the listing uploaded fine.

  The notes are created where the version has none and patched where it has
  some — with the contact above sent alongside either way.

  Parsing, the marker that keeps internal checklists out of it, and the
  4000-character check are `cux_ship_verify` 1.8.0 — so `cux_ship verify` fails
  an over-long note with no network at all.

## 2.0.0

**The Play service account is passed as a path, not as JSON.** `secrets exec`
now writes the account to a file and exports
`GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH`. `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` is
**gone** — not deprecated, not exported alongside.

### Why

A Google private key reached four public CI logs. An xcode script build phase
writes its whole environment into the build log, and a public repository's
action logs are public, so a variable holding a key printed the key. It was the
only credential this package passed by value; every other one was already a
path, and no other one leaked. That is not a coincidence, and it is the rule
this release makes universal:

> A secret passed as a value can escape through anything that echoes its
> environment. A secret passed as a path cannot.

1.9.0 and 1.9.1 mitigated it by letting a caller withhold the credential from
commands that cannot need it. That was worth having and it is still here, but it
was never the fix: withholding is not compositional. Each layer can speak for its
own child and no further, so a `secrets exec` nested inside a `keychain exec`
reintroduced the value for its own subtree — and "build under `keychain exec`,
upload under `secrets exec`" is the natural shape, so the mitigation failed
exactly where the pattern was most idiomatic. A path cannot be reintroduced in a
form that matters, because what comes back is a filename in a temp directory
that has already been removed.

### Migrating

One line per consumer. Read the file instead of the variable:

```diff
- echo "$GOOGLE_PLAY_SERVICE_ACCOUNT_JSON" > /tmp/sa.json
- supply --json_key /tmp/sa.json
+ supply --json_key "$GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH"
```

**There is deliberately no window in which both are exported.** A window is the
only variant in which something can quietly keep using the by-value path: the
key stays in every consumer's environment for its whole duration while the
release notes claim it was removed, which converts a known problem into a
believed-solved one. It is less safe than either alternative, not a middle
course between them.

Not migrating is loud rather than silent. An unmigrated consumer finds the
variable unset and dies on its first line naming the cause — which is the
criterion this package already applies elsewhere, and the reason the new name is
`…_PATH` rather than the old name with new meaning. A consumer reading a path
from a variable still called `…_JSON` would post a filename to Google and fail
at the API, describing neither the file nor the script.

## 1.9.1

**Withholding did not survive being nested, which is the composition 1.9.0's own
notes recommend.** `cux_ship secrets exec -- cux_ship keychain exec -- build`
gave the build every credential the file holds, including the Play service
account private key by value — the exposure `keychain exec` was added to close,
reintroduced by the documented way of using it. Upgrade if you nest them. A
project with `keychain exec` outermost was never affected.

Two causes, and the second is the instructive one:

- Declining to *add* a variable does nothing when it is already there. The
  environment begins as a copy of this process's own, so under nesting the outer
  command has already placed every credential. Withheld families are now
  **removed**, however they arrived.
- Removing them from the map did not remove them from the child.
  `Process.start` merges the map into the parent's environment unless
  `includeParentEnvironment` is false, so every deletion was restored from this
  process's own environment — exactly the case that matters, since under nesting
  the parent is what holds the credential.

The second was invisible from inside: the `removed from the environment` line
printed the correct full list throughout, because it reports what this process
did to a map rather than what the child received. Only reading the child's own
environment showed otherwise.

### A limitation this does not fix

**Withholding does not propagate downward through a second `secrets exec`.** The
natural shape —

```
cux_ship keychain exec -- sh -c 'build && cux_ship secrets exec --api-key k -- upload'
```

— builds without a Play credential and then, for the duration of the upload
child, has one again: the inner call loads the file fresh and withholds nothing.
That is correct for an uploader that needs it, and it means the by-value private
key is present at exactly the moment most likely to be wrapped in CI logging.

This is not fixable by adding more withholding, and the attempt would be worse
than the disease — a `secrets exec` that withheld the Play account by default
would break every Android upload that does not know to ask, which is all of
them. **The fix is to stop passing it by value at all**, exporting a path like
every other credential here, and that changes the contract and belongs to the
next major version. Until then, an Apple build should not be wrapped around a
Play upload in a job whose log is public.

- The reserved-name collision guard is derived from the withholding table rather
  than listed beside it. They were the same nine names written twice, and drift
  is silent in both directions: a name missing from the guard lets a project
  token overwrite a real credential, and one missing from the table leaves a
  secret in a child's environment the caller believes it withheld.

## 1.9.0

**Purely additive.** Nothing in the 1.8.0 secrets contract moves, and a project
that does not sign Apple builds sees no difference.

- **`cux_ship keychain exec -- <command>`** runs a command with the project's
  Apple signing identity in a keychain that is created for it and destroyed
  however the run ends. macOS only, and it refuses rather than continuing
  anywhere else — a build that carries on without the keychain signs with
  whatever the machine happens to hold, and exits zero.

  **The login keychain is never read.** That is the point rather than a side
  effect: a signing identity that comes from installed machine state makes the
  same commit sign differently on two laptops, with nothing saying so.

  It consumes the 1.8.0 schema rather than extending it — `apple.certificates.*`
  and `apple.profiles.*` as `secrets exec` already materializes them. Reads them
  from the environment when they are already there, so `secrets exec -- keychain
  exec -- …` composes, and otherwise decrypts the file itself. Which of the two
  happened is printed, not inferred.

  The wrapped command gets `APPLE_KEYCHAIN`, and is expected to pass
  `OTHER_CODE_SIGN_FLAGS="--keychain $APPLE_KEYCHAIN"` to xcodebuild. Not
  optional: the login keychain cannot be removed from the search list — that
  would drop Apple's intermediates and leave the leaf chaining to nothing — so
  pinning is the only thing that makes *signed with the certificate we imported*
  true rather than likely. A stale identity of the same name in the login
  keychain is not hypothetical; there was one on the author's machine, three
  months old, while this was being written.

  It consolidates two implementations that had each found a different subset of
  this platform's sharp edges, and adds four things neither had:

  - **Garbage collection of keychains left by a killed run.** A trap covers a
    failed build, Ctrl-C and SIGTERM. It covers neither SIGKILL nor the power
    going out, and what survives those is a distribution private key in a
    keychain that stays unlocked for the rest of its timeout. The pid in the
    filename is what makes staleness checkable, and nothing was checking it.
  - **A refusal when a named provisioning profile has expired**, at import
    rather than inside codesign, which reports it without using the word. Only
    when named with `--profile`: the secrets file holds every profile a project
    has, so failing on any expired one would mean an unused Developer ID profile
    lapsing breaks every App Store release, naming a profile that build never
    touches.
  - **Quote-aware parsing of the keychain search list.** Both sources strip
    quotes with `tr` or `sed`, which corrupts the list for anyone whose home
    directory contains a space — the output is quote-delimited precisely to
    permit that.
  - **A diagnosis rather than an assertion** when there is no usable identity.
    `find-identity -v` alone cannot separate "the .p12 had no private key" from
    "the key is here and the certificate does not chain", and those need
    opposite fixes.

- **`loadSecrets` takes `withhold`**, naming credential families the caller
  declares it does not consume. Additive: the default withholds nothing, so
  `secrets exec` is unchanged.

  It exists because a caller that knows its child's platform knows more than
  this file can. `keychain exec` withholds all three it can, each for its own
  reason, and says so rather than going quiet:

  - **`android.keystores`** — an Apple signing command's child cannot sign an
    Android artifact. Refusing to start because the file held two keystores
    locked the first consumer out of the command entirely.
  - **`android.play_service_account`** — **the one credential this tool passes
    by value rather than as a path**, and therefore the one that can escape
    through anything that echoes its environment. An Xcode script build phase
    writes its whole environment into the build log; this variable reached a
    *public* CI log that way, in full, in a project that ships from one.

    Every other credential is a filename in a temp directory that no longer
    exists by the time anyone reads the log. **Withholding it here is a
    mitigation, not the fix** — the fix is to write it to a file and export a
    path like everything else, which changes the contract and so belongs to the
    next major version. A consumer still running an Apple build under plain
    `secrets exec` should unset the variable before invoking xcodebuild.
  - **`apple.api_keys`** — signing needs no App Store key. Nothing is placed
    unless `--api-key` names one: not the singular variables and not
    `API_PRIVATE_KEYS_DIR`, so the `.p8` is never written. A build step can
    deliberately hold no App Store credential — which is what lets CI sign
    without holding anything able to create or revoke signing material — and
    requiring a key to obtain a keychain would give that property away.

    The asymmetry with the keystore above is the argument, and it is worth
    keeping: a keystore that fails to arrive is *silent*, because Gradle falls
    through to the debug config and Play rejects the artifact after a full
    upload. An App Store key that fails to arrive is *loud*, because its
    consumer dies on the first line naming the cause.

  An unrecognized family name is refused rather than ignored, since one
  misspelled withholds nothing while reporting success — and for the Play
  account that means a private key in an environment the caller believes it
  excluded.

- **`ProjectContext.developmentTeam`** reads `DEVELOPMENT_TEAM` from whichever
  Xcode project has one, ignoring the empty assignment Xcode writes for a target
  without a team. It is what lets the identity check ask whether the certificate
  belongs to the account this project builds for — a certificate from another
  account imports perfectly and fails much later as a profile mismatch that
  never mentions certificates.

## 1.8.0

**A minor version that changes the secrets file's shape.** The number is
deliberate rather than an oversight: three projects use this, all owned by one
person and all checked out side by side, and none of them had a reason to
depend on 1.x meaning anything yet. A 2.0.0 two days after 1.0.0 would have
claimed a stability that never existed. Read this section as the breaking one it
is — the migration is at the end and takes about ten minutes per project.

- **The file's shape is now a schema, not a naming convention.** Credentials
  live at a position in a declared tree rather than being recognized by their
  name, and one walker reads that tree. `secrets keys` and `secrets exec` call
  it and differ only in whether they keep the values, so "is this recognized"
  has exactly one answer.

  This replaced six defects with one cause — three consumers each recovering
  structure from a string, slightly differently. Among them: a complete Android
  keystore that validated, reported nothing amiss, and **set no environment
  variables at all**; and `secrets keys` reporting a file as refused that
  `secrets exec` accepted, with the test meant to pin them comparing one set to
  itself and therefore unable to fail for any input.

- **Any credential can appear more than once, under a name.** An app that ships
  to the App Store, notarizes a direct download and signs a `.pkg` has three
  Apple certificates; one that keeps a scoped upload key alongside an Admin key
  for reading the portal has two API keys of different kinds. Previously the
  vocabulary could express one of each.

  Instance names never become variable names — uppercasing is not injective, so
  `dist` and `dist_p12` would mint the same variable. Selection fills the fixed
  names instead: exactly one instance is the default, two or more must be named
  with `--keystore` or `--api-key`, and a name that is not in the file is an
  error listing what is, rather than a fall back that would run an Admin-gated
  read with a scoped key.

- **Certificate kinds are a closed set** — `distribution`, `developer_id`,
  `mac_installer` — so `developr_id` is refused. Keystore, profile, token and
  ssh key names are the project's own, which is the one level no schema can
  police.

- **`api_private_key_filename` is replaced by `kind: team | individual`**, and
  the filename is derived from it and the id. The filename is the only signal of
  which claims Apple is sent; storing it as well meant a third copy that could
  disagree with the other two, which is why 1.7.2 had to cross-check them.

- **`tokens:` and `ssh_keys:`** hold what this tool will never understand — an
  artifact host, a deploy key. Each declares the variable it exports, validated
  as `[A-Z][A-Z0-9_]*` and refused if it collides with a name materialization
  sets, so a token cannot quietly redirect `ANDROID_KEYSTORE_PATH`.

- **`placed:` holds files the build reads from the working tree**, with
  `secrets place`, `secrets clean` and `secrets pack`. Some credentials are
  source — a compiler and an analyzer read them from fixed paths — so they
  cannot live in a temp directory and cannot vanish when a command exits.

  Their guarantee is a different one and weaker, and it is stated rather than
  implied: not *plaintext never outlives the run* but **plaintext never enters
  history**. A target is refused if it is not ignored, if git already tracks it
  (`.gitignore` does not apply to tracked files, so one `git add -f` makes a
  path publishable forever), if it crosses into a submodule, if it leaves the
  repository once symlinks are resolved, or if it is a symlink or a directory.
  All three verbs compare content: `place` refuses to overwrite an edited file,
  `clean` removes only what still matches, and `pack` re-encrypts an edit back.

- **`apple.profiles` is gone from `.cux-ship.yaml`.** The secrets file names the
  profiles; a second declaration of one fact is a second thing that can drift.
  `apple.signing: manual | automatic` stays, because it is a repository-level
  choice and not derivable from which blobs happen to be present — and it
  decides more than it sounds like: `-allowProvisioningUpdates` is a portal
  write and an individual key cannot read the portal at all, so automatic
  signing requires a team key that reaches every app in the team.

- **`path`, `env` and `kind` are stored in cleartext**, so `secrets keys` and
  the placement pre-flight work with no identity. That is a real disclosure — a
  path tells a reader where a project keeps things — and it buys a pre-flight
  that needs no key. Enforced both ways: the walker refuses an encrypted value
  in those fields and names the `unencrypted_regex` to add, and a schema whose
  secret-bearing field took one of those names fails the test suite.

### Migrating a project

Environment variables are unchanged, so **nothing that consumes credentials
needs editing** — `build.sh`, `upload.sh` and Gradle keep reading the same
names.

**The tool and the file have to move together, and no order avoids a window
where they disagree.** Both directions fail loudly, and the message says which
way round you are: an older version reading a new file complains that something
*"nests deeper than a credential goes"*, while this version reading an old file
reports unrecognized keys. Neither can mistake the other's file for a valid one,
so the window is an inconvenience rather than a hazard — but do these in one
sitting.

1. **Raise the constraint and upgrade.** A minor bump does not compel this the
   way a major one would: `^1.7.1` already permits 1.8.0, so a resolved
   `pubspec.lock` stays where it is and `dart pub get` alone will not move you
   onto the version that can read the new shape.

   ```sh
   dart pub upgrade cux_ship     # or raise the constraint to ^1.8.0
   ```

2. Add to `.sops.yaml`, under the rule that matches your secrets file:

   ```yaml
   unencrypted_regex: '^(path|env|kind)$'
   ```

   Inert until the file holds a `placed:`, `tokens:`, `ssh_keys:` or
   `apple.api_keys` entry, so a project with only a keystore and a service
   account needs nothing from it yet. Add it anyway: otherwise its absence
   surfaces months later, from a file that had been working, the first time
   somebody adds one of those.

3. Restructure the file. Needs the age identity, because sops binds each value
   to its key path — a textual rename fails authentication. Plaintext never
   touches disk:

   ```sh
   sops -d secrets/release.yaml \
     | <your restructuring> \
     | sops -e --filename-override secrets/release.yaml /dev/stdin \
     > secrets/release.yaml.new && mv secrets/release.yaml.new secrets/release.yaml
   ```

   | 1.7.x | 1.8.0 |
   | --- | --- |
   | `keystore_p12_base64`, `keystore_password`, `key_alias` | `android.keystores.<name>.{base64, password, key_alias}` |
   | `play_service_account_json_base64` | `android.play_service_account.json_base64` |
   | `api_key_id`, `api_private_key_base64`, `api_issuer_id` | `apple.api_keys.<name>.{id, private_key_base64, issuer_id}` |
   | `api_private_key_filename` | `apple.api_keys.<name>.kind: team \| individual` |
   | `distribution_p12_base64`, `distribution_p12_password` | `apple.certificates.distribution.{p12_base64, password}` |

4. Run `cux_ship secrets keys`. It needs no identity, reports every credential
   by path, and names anything half configured — so it will tell you whether the
   result is right before you try to build with it.

## 1.7.2

- **An individual App Store Connect key was classified as a team key.**
  `secrets exec` materialized every key as `AuthKey_<id>.p8`, and both `altool`
  and this tool's JWT builder read that prefix to decide which claims to send —
  Apple names an individual key `ApiKey_<id>.p8` and a team key `AuthKey_<id>.p8`.
  So an individual key routed through `secrets exec` was sent `iss` instead of
  `sub: user` and got a bare 401, after a full build.

  The issuer id cannot stand in for the prefix: `altool` documents
  `--api-issuer` as required alongside `--api-key`, so an individual key
  legitimately carries one too. The filename is the only signal, which is why
  inventing it destroyed the distinction.

  New optional `api_private_key_filename` carries the name Apple gave the key.
  **Absent, the behavior is exactly as before** — `AuthKey_<id>.p8` — so a
  project with a team key needs no change. A project with an individual key
  must now set it. The value is checked against `(ApiKey|AuthKey)_<id>.p8` and
  against `api_key_id`, because it becomes a filename in a directory `altool`
  searches, and a mismatched id produces a file `altool` looks straight past.

  Predates the Dart port — `with-secrets.sh` renamed identically. Found by the
  AuthPass maintainers while migrating onto `secrets exec`.

- `cux_ship_verify` is **not** released alongside this one. It has no changes,
  and the dependency on it now names the oldest version that works rather than
  the newest — bumping in lockstep made the repository unresolvable as a git
  dependency for the whole window between a commit and its publish.

## 1.7.1

From a security audit. No high-severity defects were found; these are the three
worth acting on.

- **A malformed decrypted secrets file could print its own contents.**
  `package:yaml` renders a parse error with the offending source line and a
  caret under it, and the whole exception was being interpolated into a message
  that goes to stderr — so a decrypted private key could land in a terminal or a
  CI log. It needs a hand-mangled file that still decrypts, which is why it is
  not higher, but it is the difference between an error and a disclosure. Both
  YAML error paths now print the bare reason and no source.
- **`deps update` now validates what it writes.** The version and hash come from
  GitHub over the network and were interpolated into generated Dart source
  inside single quotes, so a value carrying a quote could inject code that runs
  on the next analyze. Maintainer-only and behind a reviewed diff; two regexes
  are cheaper than relying on the review.
- **Pagination cannot carry the bearer token off-origin.** `getAll` followed
  `links.next` to whatever host it named, with the Authorization header
  attached. Reaching it would require Apple's own TLS response to be
  attacker-controlled — but "the token only goes to Apple" should be a property
  of this code rather than of Apple's response.

## 1.7.0

- **`cux_ship secrets keys`** — lists the credential names in a secrets file
  without decrypting it, says which heading each sits under, marks any name
  `secrets exec` would refuse, and ignores the `sops:` metadata block. Worth
  running before adopting a new version, since an unrecognized key stops
  `secrets exec` outright.
- **Fixes a wrong command in the bundled skill**, which is why this exists. It
  recommended `grep -oE '^[a-z_]+:|^[[:space:]]+[a-z_]+:'` for the same job, and
  that character class omits digits — so against a real file with nine
  credentials it reported four and hid five, including the entire Android
  keystore, the Play service account and the App Store private key. Every name
  it hid was one carrying key material, and the output read as a clean bill of
  health.

  The command replaces the advice rather than correcting it: it shares the
  key-walking with the parser that enforces the rules, so the two cannot drift.
  Reported by a consumer migrating from 1.5.1.

## 1.6.0

First release on pub.dev. Versions before this one were consumed as git refs;
they are in the git history and in this repository's tags.

- **Two packages instead of five.** The App Store and Play clients moved into
  `lib/src/appstore/` and `lib/src/play/` here, and the changelog parser and App
  Store metadata model moved into `cux_ship_verify`, which now has no
  dependencies at all. The split is about what a consumer's lockfile gets: a
  release machine wants googleapis and an image codec, a test suite does not.
- `lib/verify.dart` still re-exports `cux_ship_verify`, so nothing breaks — but
  a test suite should now depend on `cux_ship_verify` directly rather than
  reaching the checks through this package.
- Resolved as a pub workspace, so the repository has one lockfile and each
  package still declares ordinary hosted constraints.

## 1.5.1

- Read the headings a real secrets file groups its credentials under. `secrets
  exec` walked only top-level keys, so a file grouping values under `android:`
  and `apple:` — which is how they are actually written — was refused with none
  of its credentials found.

## 1.5.0

**Broken; use 1.5.1.** Its secrets parser refuses any grouped secrets file.

- `--app-dir` and `.cux-ship.yaml`, so a repository whose Flutter app is a
  subdirectory can use `release finish` at all. The repository owns
  `CHANGELOG.md` and `store/`; the app directory owns `pubspec.yaml`,
  `android/` and `ios/`.
- `cux_ship secrets exec` — decrypt a sops file, run a command with the
  credentials in its environment, remove them however the run ends.
- `cux_ship deps install` — fetch sops and age by pinned hash into `.bin/`.
- `api_issuer_id` is optional. An individual App Store Connect key has none,
  and requiring one ruled out the credential that scopes CI to a single app.
