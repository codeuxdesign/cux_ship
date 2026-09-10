# Changelog

## 1.11.0-dev.2

**A preview with no stereo audio track is refused offline.** Apple rejects one
with `MOV_RESAVE_STEREO` — a *channel-layout* code, reported even for a file
carrying no audio stream at all — after the upload and a round trip through an
ingestion queue it documents in hours. Observed on a real release, on a silent
cut published by mistake. `VideoInfo` gains `audioChannels` and `VideoRules`
gains `requiredAudioChannels`, nullable because a second store may state no
rule and a check that invented one would refuse a file nobody refuses.

The message says what the file actually has — "has no audio track", "has 1
audio channel" — rather than repeating Apple's word for something it is not,
and names `MOV_RESAVE_STEREO` so somebody who has already had the 422 can
connect the two.

**`defaultPreviewFrameTimeCode` is documented as approximate.** Apple states
five seconds and was observed cutting at `00:00:05:01`, so a run decides whether
anybody chose a frame by asking the tree, never by comparing Apple's value
against this constant — which would not have matched even once.

Six further defects in 1.11.0-dev.1, found by a code review of the change that
introduced it. Two are in the offline checks and cost a day each when they fire;
four are the parser reading something other than what it claims to.

**A timecode's frame field was never range-checked.** `00:00:02:99` passed every
offline check on a 30 fps video — minutes and seconds were bounded and the field
the format is named for was not — and because it resolves to 5.3 s it is inside
the file, so the past-the-end check did not fire either. Apple takes it and
rejects the poster frame a day later, which is exactly the cost these checks
exist to avoid. `previewFrameTimeCodeProblem` now takes an optional `frameRate`.

**A sidecar was matched case-sensitively where videos are not.** The video
filter lowercases, so `RIDE.MP4` is a preview; the sidecar lookup built an exact
path and the orphan check compared exactly. On a case-sensitive filesystem —
Linux CI — `01-ride.mp4.TIMECODE` was neither found nor reported as an orphan,
so the preview shipped at Apple's five-second default and the one guard against
that said nothing.

**`_readCodec` bounded against the file rather than the box**, so an `stsd`
declaring no entries (16 bytes, and legal) read straight into the next sibling's
header and reported *its* four-character type as the codec — observed refusing a
file with `is stts; the App Store takes H.264 or ProRes 422 HQ`.

**A 64-bit box size could overflow the bounds check.** `offset + size > to`
wraps negative near 2^63, so the guard passed, `offset += size` went negative,
and the next read threw a `RangeError` out of a metadata loader instead of
returning null. Now `size > to - offset`, which cannot overflow.

**A negative frame rate passed every rule.** `stts` products can overflow int64;
the guard only rejected zero. A negative rate slips under a `> 30` ceiling and
then becomes a divisor.

**A video with more than one `vide` track gave up at the first unreadable one**
rather than trying the next.

Two message defects: a file in the first 50 kB above the cap was refused for
exceeding a number that rendered identically to its own size, and the sentence
about Apple's ambiguous "500MB" was printed for whatever `VideoRules` it was
handed. The ambiguity is now a field on the rules, so a second store's cap is
its own.

## 1.11.0-dev.1

**App preview videos are part of the tree, and are checked offline.**
`listings/<locale>/previews/<PreviewType>/` loads into
`LocaleMetadata.previews`, with `<video>.timecode` beside each video carrying
the poster frame.

`store_video.dart` is new and reads an MP4 or QuickTime container the way
`store_image.dart` reads a PNG: a hand-rolled walk to a dozen integers, no
dependency, no frame decoded. It answers the four things Apple enforces —
dimensions, duration, frame rate, codec — plus the file size, and
`videoEncodingProblem` names the one that is wrong rather than reporting an
invalid file.

That matters more here than for an image. Apple validates a preview *after* it
has been uploaded, from a queue it documents as taking up to 24 hours, and the
version the preview hangs off cannot be submitted while it is in flight. A
refused screenshot costs a re-upload; a refused preview costs a day.

Three checks are specific to previews and are worth naming, because each is
something Apple accepts quietly and gets wrong later:

- **A poster frame past the end of the video** is taken without complaint and
  then silently falls back, surfacing as a product page posing on the wrong
  frame — after approval, when it can no longer be changed in place.
- **An orphaned `.timecode`** — one whose video was renamed — is refused rather
  than ignored. It is somebody's deliberate choice of frame now applying to
  nothing, and the preview it was meant for would go up at Apple's default.
- **A rotation matrix is applied before the dimensions are judged.** A portrait
  capture is routinely stored as a landscape frame with a quarter turn beside
  it, and reading `tkhd` alone would refuse a file that was already correct.

**`checkAppStoreTree(requirePreviewFrames: true)`** refuses a preview that names
no poster frame. Off by default, because the tree's rule is *present means
owned* and a missing sidecar means "leave the poster Apple holds" — which is
right for a project that set one in the console. On, it is the project saying
the store permits something it does not, which is what `requireScreenshotTypes`
already is.

`previewSpecs` is a separate table from `screenshotSpecs` rather than the same
one with different numbers: Apple's two enumerations are spelled differently
(`IPHONE_67` against `APP_IPHONE_67`), the sizes are not device resolutions,
and the transpose is not always legal — Mac and Apple TV are landscape only.

## 1.10.0

**The Play tree is checked for the alpha channel it was already measuring.**
`readImageInfo` has computed `hasAlpha` since the App Store tree was first
checked, and `checkPlayTree` called it, used `width` and `height` for the
320/3840 edge bounds, and dropped the rest. So a Play listing whose screenshots
carried transparency passed every offline check here and was refused during
ingestion — after the upload and after the processing wait. Play states the
same rule Apple does, *"JPEG or 24-bit PNG (no alpha)"*, for every slot this
package checks but the app icon, which is specified as *"32-bit PNG (with
alpha)"* and is the one image in either store that wants one.

That the capability was present, correct, and enforced on one of two paths is
the part worth naming. It is not a missing check; it is a check written at a
call site instead of beside the thing it checks. So both trees now call
`imageEncodingProblem` in the new `store_image.dart`, under a `StoreImageRules`
naming the store and quoting its words — a third store path gets the rules by
saying whose it publishes under, rather than by remembering.

**`ImageInfo` carries `bitDepth`, and both stores refuse more than 8.** Play
asks for a 24-bit PNG; a 16-bit-per-channel PNG is 48-bit and every check in
this package accepted it, for both stores. Not hypothetical: a consuming
project's macOS capture fallback writes depth 16 and Apple refuses the set at
ingestion, so the remedy documented for one failure produced a set the store
rejects. `cux_ship screenshots flatten` preserved the depth too, and is fixed
alongside this — the message names it because it now reaches that state.

The two rules have different provenance and the messages say which. Play's is
Play's, quoted. Apple publishes no bit depth for screenshots at all, so that one
is this package's, resting on a set Apple actually refused — deliberately the
same evidence bar the aspect-ratio rule fails and is still left unchecked for.

Fewer than 8 bits is *not* refused: a greyscale or palettised PNG has 8-bit
palette entries, no store has been seen to refuse one, and failing it would be
this package inventing a rule.

**And the depth rule is PNG-only**, which it was not when first written. Every
justification under it is PNG's: in *"JPEG or 24-bit PNG (no alpha)"* the
`24-bit` modifies the PNG, so Play states no JPEG depth; the set Apple was
observed refusing was a PNG; and `screenshots flatten` cannot open a JPEG —
it throws, and through the CLI it walks `.png`, so it would skip the file, exit
0, and leave the refusal standing. Applied to a JPEG the check quoted Play for
a rule Play does not state and named a remedy that loops. A >8-bit JPEG is
legal under the extended sequential and progressive frames and essentially
unproducible — baseline SOF0 is 8-bit by definition, and reading 12 needs
libjpeg's separate 12-bit entry points, which browsers do not call — so it is
accepted, and `ImageInfo` carries `format` so the check can tell. `bitDepth` is
still read for a JPEG, because it is what the file says.

**`ImageInfo` gained two required fields**, `bitDepth` and `format`, so a
caller that constructed one itself no longer compiles. **Strictly that is
breaking, and this is a minor release anyway** — said plainly rather than left
for a reader to notice.

The reasoning: `ImageInfo` is what `readImageInfo` returns, not something a
consumer builds, and nothing here or in `cux_ship` constructs one. The
exception is a test that mocks one, which is the case this release argues
against anyway — the fixtures here are real PNG and JPEG headers precisely
because a mocked `ImageInfo` cannot be wrong in the way a real file is. If that
breaks a suite, add the two fields; there is no behaviour to migrate.

Defaulting them was the alternative and is worse: a default lets a caller
construct an `ImageInfo` that lies about the file it claims to describe, which
is the failure this whole release is about.

**The stores' published rules, the three decisions and the research under each
are in `docs/design/store-image-rules.md`** — including what is deliberately
not checked, and what would bring the JPEG half back.

## 1.9.0

**`checkPlayTree`** — the Play listing tree, offline. Text limits, the two
images Play requires at exact sizes, screenshot edge bounds and counts, and the
distinguished locale in `details/default_language.txt`, which the App Store has
no equivalent of. Play was covered for release-note length and nothing else.

The icon and feature graphic are checked unconditionally rather than being
things a caller asks for. They are Play's rules rather than a project's choice,
and a caller that could omit them would let a missing icon pass.

**`checkDataSafetyFile`** — the data safety CSV, **structure only**. Whether the
answers are true is a question about a particular app and this cannot answer it.
Nothing to specify either: the file is Play's own export and every row carries
its own answer requirement, so it is validated against itself rather than
against a copy of Play's rules that would rot.

Includes an RFC 4180 subset reader, because this package has no dependencies and
is not getting one for this. It refuses what it cannot parse — an unterminated
quote swallows every row after it, and a parser that shrugged would report a
truncated file as a complete one.

**`ReleaseProblem` moves to its own file** so a checker can sit beside the model
it checks without the import becoming a cycle. It is still exported from
`cux_ship_verify.dart`; no consumer changes.

### What is not covered, said plainly

**Localized graphics fall back to the default language**, so only the locale
others fall back to is required to carry the icon, the feature graphic and the
declared screenshot types. That behaviour is documented by Play and was
confirmed from the documentation independently of the author's reading — but
**every repository that reviewed this release publishes a single locale**, so no
real listing has ever exercised it. The synthetic trees in
`play_metadata_test.dart` are the whole of the evidence.

This is recorded rather than left implicit because "reviewed by three projects"
would otherwise read as covering it. It does not. The first consumer to publish
a second locale is the first real test of that rule.

### On numbers, and whose they are

Both kinds appear in `play_metadata.dart` and they are labelled: Play's limits
are cited as Play's, and this package's policy floors say so. A hardcoded value
nobody can change needs provenance *more* than a configured one — the first
project that legitimately disagrees will file it as a bug, and a number with no
source can be neither defended nor dropped.

Two checks were written, run against a real store-accepted listing, and deleted
before shipping, along with Play's published aspect-ratio rule. Each would have
failed a listing the store is serving. See cux_ship's 3.2.0 entry.

## 1.8.0

- **`review-notes.md` is read from the metadata tree**, as
  `AppStoreMetadata.reviewNotes`, and checked against Apple's 4000-character
  limit here rather than at upload — the same reason release-note length is
  checked here: Apple refuses an over-long note *after* an archive has been
  transferred.

  Two things it does that a plain read would not, both because the file is
  written for two audiences:

  - **Everything after `<!-- not for Apple -->` is cut.** A review-notes file
    accumulates checklists and reasoning belonging to whoever maintains it, and
    uploading it wholesale sends Apple an internal to-do list. A marker makes
    the split structural rather than something the next person has to remember,
    and an HTML comment is invisible wherever the file is rendered.
  - **The markdown is flattened to plain text**, because Apple's field is plain
    text and a reviewer seeing literal `##` and `**` reads carelessness in the
    one document whose job is to argue the opposite. Deliberately three
    substitutions rather than a renderer: heading hashes, bold markers, and the
    angle brackets that stop a bare URL being auto-linked.

  A file that is entirely below the marker is an error rather than an empty
  note, because that is a mistake in the file rather than a decision.

## 1.7.1

No changes. Released alongside `cux_ship` 1.7.1, which the two packages move in
step with.

## 1.7.0

No changes. Released alongside `cux_ship` 1.7.0, which the two packages move in
step with.

## 1.6.0

First release on pub.dev, and the first version of this package that is worth
depending on directly. Earlier versions were consumed as git refs and only
reachable through `package:cux_ship/verify.dart`, which meant a test suite
pulled the whole release CLI — googleapis included — to check the length of a
release note.

- **No dependencies at all.** The `CHANGELOG.md` parser (previously
  `cux_ship_notes`) and the App Store metadata tree loader (previously
  `cux_ship_appstore/metadata.dart`) moved here. Both are pure `dart:io` and
  `dart:convert`, both are the model of a store input rather than a client for
  one, and having them here is what lets the CLI depend on this package instead
  of the other way round.
- New public libraries: `package:cux_ship_verify/release_notes.dart` and
  `package:cux_ship_verify/metadata.dart`. The checks stay at
  `package:cux_ship_verify/cux_ship_verify.dart`.
