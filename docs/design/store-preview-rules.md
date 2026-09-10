# App preview videos: what is refused, where the poster frame lives, and how long a wait is normal

Status: **built**, in `cux_ship_verify/lib/store_video.dart`,
`cux_ship_verify/lib/metadata.dart` and `AppStore.replacePreviews`. This is the
research and the decisions behind them. `store-image-rules.md` is the same
document for screenshots and this one deliberately does not repeat it; what is
here is what a *video* changes.

It exists for the reason that one does — these checks refuse a file somebody has
committed, offline, on a claim about what Apple would do — and for one more.
Every number below was read off Apple's pages in September 2026 rather than
inherited from a prompt, because the prompt that asked for this feature had the
resource names right and the delivery-state field wrong, and there was no way to
tell from inside the prompt which was which.

## Why a preview is not a large screenshot

Three differences, and every decision below is downstream of one of them.

**It is up to 500 MB.** So re-uploading to change an attribute is not the free
operation it is for a 2 MB PNG.

**Apple ingests it asynchronously and slowly.** Apple's own guidance is up to
twenty-four hours. Screenshots take seconds to minutes, which is why
`awaitScreenshotProcessing` can have a ten-minute timeout and treat reaching it
as an error worth reporting. The same reasoning applied here would tell a caller
their upload failed when it had not.

**It has an attribute nobody can see afterwards.** `previewFrameTimeCode` is the
frame the product page poses on before anybody presses play. It defaults to five
seconds, and — this is the part that decides the design — **after approval it
cannot be changed without a new version submission.** A wrong description is
embarrassing and editable. A wrong poster frame is neither.

## What Apple's API actually looks like

Verified against Apple's `AppPreview`, `AppPreviewSet`, `AppPreviewCreateRequest`
and `AppPreviewUpdateRequest` schemas and the *Uploading App Previews* sample,
September 2026.

| | |
|---|---|
| `appPreviewSets` | `previewType` (required), related to `appStoreVersionLocalization` — the same shape as `appScreenshotSets` |
| `appPreviews` create | `fileName` and `fileSize` required; `mimeType` and **`previewFrameTimeCode`** optional |
| `appPreviews` update | `uploaded`, `sourceFileChecksum`, **`previewFrameTimeCode`** |
| Read back | `videoDeliveryState`, `previewFrameImage`, `videoUrl`, `sourceFileChecksum`, `uploadOperations` |
| Per set | **up to three previews**, against ten screenshots |

Two of those are the ones that would have been got wrong by pattern-matching on
the screenshot code, and both are load-bearing.

**`assetDeliveryState` is deprecated on `appPreviews`.** Apple's schema marks it
so and names `videoDeliveryState` as the replacement. A reader that reused
`screenshotDeliveryState` would compile, run, and report a null state for every
preview — so nothing would ever equal `COMPLETE`, the unchanged-asset skip would
never fire, and every release would silently re-upload every video. That is
precisely the failure `PublishedScreenshot`'s doc comment records this package
having already paid for once, on the mirror-image mistake. The deprecated field
is still read as a fallback, because a deprecation notice describes an intention
and not the present.

**The poster frame is a second asset with a second verdict.** Apple cuts it out
of the video *after* ingesting the video, and reports it under
`previewFrameImage.state` — a whole separate `AppMediaPreviewFrameImageState`.
So `videoDeliveryState: COMPLETE` beside a failed frame is a real state, and it
is exactly the state a timecode naming no frame produces. A wait that watched
only the video would call that a success and submit it.

**`PreviewType` is a different enumeration from `ScreenshotDisplayType`**, and
the difference is one prefix: `IPHONE_67` against `APP_IPHONE_67`. There is no
mechanical way to notice this — both are plausible strings, and Apple's answer
to the wrong one is an error about an unrecognised value at upload time. It is
checked offline, and the message carries both spellings.

## The four rules, and why they are read out of the file

Apple states these as numbers and enforces them at ingestion:

| | |
|---|---|
| Duration | 15–30 s |
| Frame rate | 30 fps maximum |
| Codec | H.264 (up to High 4.0) or ProRes 422 HQ |
| Size | iPhone 886×1920, iPad 1200×1600, Mac and Apple TV 1920×1080 landscape only |
| File | ≤ 500 MB, `.mov` / `.m4v` / `.mp4` |

Apple's answer to any of them arrives from the twenty-four-hour queue. So they
are read from the container instead, by a hand-rolled ISO base media walk — the
same trade `store_image.dart` made, and for the same reason: `cux_ship_verify`
has no dependencies at all, and what is needed is a dozen integers four levels
down a documented box path, not a demuxer.

**The sizes are not device resolutions**, which is the thing worth writing down.
Every current iPhone slot publishes 886×1920 — a size no iPhone has. The
intuition that carries over from screenshots, *capture it at the device's size
and it will fit*, is false here in a way that produces a valid-looking file. So
the refusal states the number rather than only that the size is unacceptable.

**The rotation matrix is applied before the dimensions are judged.** A portrait
capture is routinely stored as a landscape frame with a quarter-turn matrix
beside it; reading `tkhd` and stopping would report 1920×886 for a file every
player and the App Store agree is 886×1920. That would refuse a preview that was
already correct, which is the one direction an offline check must not fail in —
it sends somebody to re-encode a file that was fine, and there is no error from
Apple to contradict it.

## Where the poster frame lives, and why it is a file

`<video filename>.timecode`, beside the video: `01-tour.mp4` is posed by
`01-tour.mp4.timecode`.

**A file rather than a flag**, because a set holds up to three previews and
there is no reason they share a frame; one `--preview-frame` would be wrong for
two of them. **A sidecar rather than a field in a shared file**, because the
whole tree already works this way — one file per value, present means owned —
and because it sorts against the video it belongs to. **Appended rather than
replacing the extension**, so it cannot collide with a second preview of the
same stem in another container.

Two checks the shape makes possible, and both are silent failures otherwise:

- **A frame past the end of the video.** Apple takes the string without
  complaint and the poster falls back. It surfaces as a product page posing on
  the wrong frame, after approval, when it cannot be changed in place.
- **An orphaned sidecar**, whose video was renamed or removed. Not an unused
  file: a deliberate choice of frame now applying to nothing, with the preview
  it was meant for going up at five seconds and nothing said.

**A tree that names no timecode leaves Apple's value alone** rather than
resetting it to the default — "present means owned" applied to an attribute. The
run still says which of the two happened, which is the next section.

### Decided: the frame is required by the consumer, not by the loader

Status: **decided**.

The one consumer asked for the timecode to be a *required* input rather than an
optional one with a default, on the argument that "an argument that must be
passed is the cheap way to make that state unreachable". The argument is right
about the danger and it was not adopted where it was proposed.

Making the sidecar mandatory in `loadMetadata` would break *present means owned*
for the one field where the rule is doing real work: a project that set its
poster in the console and does not want it reasserted has no way to say so, and
would have to duplicate a value it already chose elsewhere. That is a policy
some consumers have being imposed on all of them.

So it is `checkAppStoreTree(requirePreviewFrames: true)` — the shape this
package already uses for exactly this, and which `requireScreenshotTypes`
exists as the precedent for: *the store permits it and this project does not*.
It fails in the consumer's own test suite, on the push that introduces it,
which is earlier than a required argument would fail anyway — a required
argument fails at the release, and a test fails at the commit.

The guarantee the consumer wanted is intact; what changed is which layer holds
it and who can opt out.

## Saying what was uploaded and what it was told

The consuming project's convention is that a tool prints effective
configuration, not intent. This is the strongest case for it anywhere in this
package, because the default is invisible, plausible and permanent: a preview
silently posed at five seconds looks exactly like a preview posed deliberately.

So every run names the frame per video, and distinguishes the two cases —
`poster frame 00:00:02:06` against `poster frame 00:00:05:00 (Apple's default —
no .timecode file beside the video)`. Including on a run that uploaded nothing,
because that is the only place a reader sees what the *live* listing is posed at
without opening App Store Connect. And including under `--dry-run`, which is the
cheapest way to see the answer while it is still changeable.

The value printed after an upload is the one Apple echoed back rather than the
one that was sent. The two differing is exactly the thing worth seeing.

## Three decisions that follow from the slowness

**The timecode goes in the reservation — and is asserted again after
ingestion, because Apple ignores the first one.**

The original reasoning was that sending it at reservation means the asset never
exists, even briefly, without the frame it was meant to have. That is correct in
intent and was wrong in fact, and the first real upload is what said so: the
create carried `00:00:02:06`, Apple accepted the request, and the poster came
back cut at Apple's own `00:00:05:01`. The attribute is presumably read while
the asset still has no bytes, so whatever ingestion derives overwrites it.

The consequence was as bad as it sounds. **A single run left every preview at
Apple's default and printed success.** The value arrived only on a *second* run,
through [PreviewPlan.retime], which needs a published preview to compare
against — so "run it twice" was the correct procedure and nothing said so.

So the timecode is asserted after both states report `COMPLETE`, where the asset
exists and Apple's answer is real, and the create keeps sending it because it
costs nothing and may be honoured for asset types that are not this one. What
changed is that it is no longer *trusted*.

**This is what the blank line was hiding**, and the two defects are worth
keeping together. Apple answers the commit with `previewFrameTimeCode: ""` — an
empty string, not a null, because the poster is not cut yet — and `''` survives
both a `??` and a null check, so the line whose entire job is to name the
effective poster frame printed `poster frame ` with nothing after it. The one
input that cannot be corrected after approval, unreported, at the one moment the
discrepancy was on screen.

**A moved poster frame is patched, not re-uploaded.** This is what
`PreviewPlan.retime` exists for. Folding it into `replace` would be *correct*,
and would cost half a gigabyte of upload and a second pass through the
twenty-four-hour queue every time somebody moved a frame by six frames.

**Previews publish after screenshots.** Everything cheap has landed before the
run starts waiting, and a wait that times out does not leave the screenshots
unwritten behind it.

## The timeout, and why reaching it is not a failure

Thirty minutes, against the screenshot path's ten.

The *reason* for waiting is identical and is the one `awaitScreenshotProcessing`
documents: a version whose assets are in flight is refused for review with an
error naming the version rather than the assets. What differs is that reaching
the timeout is **ordinary here** — Apple says up to twenty-four hours, and
nothing is going to wait that long inside a release script.

So the message carries that. A caller told "processing failed" after thirty
minutes goes looking for a broken upload that is not broken; the message says
the videos are uploaded, that the wait is what stopped, and that the submission
is the thing that has to wait rather than the upload being the thing to retry.

### Measured: 7m29s, once

Status: **decided**, and the sample size is one.

The first real ingestion, on an 886×1920 / 29.57 s / 20.4 MB stereo H.264
preview: **7 minutes 29 seconds** from commit to both `videoDeliveryState` and
`previewFrameImage.state` reporting `COMPLETE`. So the thirty-minute default was
never approached, and Apple's documented twenty-four hours is a ceiling rather
than a typical case.

Two things it did *not* settle. **Which asset finishes first is still
unknown** — the loop's only exit is both-`COMPLETE`, so a run that ends tells
you nothing about the order.

**Instrumenting it is not the same as measuring it, and this section read as
though it were.** dev.2 prints one line per state transition; that makes the
ordering *observable on the next upload that happens*, which is a different
claim from knowing it. The consumer made the correction and it is worth keeping
in these words, because the gap between "we can now see this" and "we now know
this" is exactly where a design document starts lying to its next reader.

Nor is the next upload cheap to summon: the one project running previews
declined to manufacture one, on the grounds that clearing a published set to
re-upload 20 MB puts a live App Store version through an ingestion cycle to
produce a log line. That is the right call. The number arrives with the next
re-cut, or the first preview on another platform or locale.

And **the hypothesis that Apple might never report `previewFrameImage` did not
fire on this file**, which is one file; the grace period stays.

### Proposed: the wait is welded to the upload

Status: **proposed**, and argued at length in
[preview-wait-split.md](preview-wait-split.md), which is where the interface
lives. This section is the summary and the reason it is not built yet.

Raised by the first consumer's owner, in the form *"maybe there should be
another status/wait command — how is this handled for builds?"* The answer is
that builds already have it and previews are the one asset that did not get it:

| asset | worst case | timeout | `--timeout` / `--poll` | wait command | skip flag |
|---|---|---|---|---|---|
| build | about an hour | 45 min | yes | `appstore wait` | `--skip-waiting` |
| screenshot | seconds to minutes | 10 min | no | no | no |
| preview | **24 hours** | 30 min | no | no | no |

And `--skip-waiting` cannot help even if reached for: it is evaluated inside the
artifact branch, and a metadata-only run has no artifact. So the one command
that publishes a preview has no way not to wait.

The shape to copy is the build path's, and `cli.dart` already states the
principle — *"`upload --skip-waiting` does the transfer, `appstore wait` does the
poll"*. `upload --metadata --skip-waiting` would publish and stop, printing the
next command; `appstore wait` would learn previews, with `--timeout` and
`--poll`. Reaching the deadline then becomes a *resumable state* rather than a
non-zero exit.

**The cheap version, if the split is too much**, is to make the timeout and poll
configurable from the CLI and to exit zero at the deadline with "still
processing, here is how to check". An outcome this document calls *ordinary*
should not be an error.

Not done in dev.2 because the sharp edge that made it urgent is gone: the
timeout message told the operator to re-run, and re-running was the path into
the skip that ignored a rejected poster frame. That skip is fixed, so the
printed remedy is honest and the split is an improvement rather than a repair.

### Open: thirty minutes is a guess

Status: **open**, and now with one measurement against it.

Nothing here has watched a real preview through Apple's queue. Thirty minutes is
chosen as "long enough that the common case finishes, short enough that a CI job
does not hang" and neither half of that is measured. The number to want is the
distribution of real ingestion times, and the way to get it is to ship this and
record what the first few releases actually took.

**There is a specific measurement pending rather than a general hope.** The
first consumer has undertaken to time its first upload and write the result into
its own `docs/PROMO-VIDEO.md` §1: when the video reached `COMPLETE`, when the
poster frame did, **and which of the two happened first.**

Three findings rather than two durations, and the third is the one worth having.
[AppStore.awaitPreviewProcessing] waits on both states and assumes the frame
lands second — Apple's documented order, observed by nothing here. A measurement
taken as "video, then the frame after it" would replace the thirty-minute
default and leave that assumption exactly as unverified as it is today, because
the instruction would have been written in the terms of the thing it was meant
to test. The interesting case is the frame already reporting `COMPLETE` on the
first poll after the video: that would mean the second wait is dead weight and
this can be one state, not two.

Replace the default with what those numbers say, and this section with them.

Two things make the wrong value cheap rather than expensive, which is why this
did not block the work: the timeout is a parameter, and reaching it is
recoverable by re-running — the unchanged-asset skip means a second run uploads
nothing and only re-checks.

### Open: nothing requires a preview

Status: **open**.

`checkAppStoreTree` grew `requireScreenshotTypes` because Apple refuses a
*submission* from a universal app carrying no iPad screenshots, so an absent set
is invisible until review. There is no `requirePreviewTypes`, because previews
are optional to Apple and no consumer has yet said it wants one required.

The argument for adding it is not Apple's rules but the project's: a video app
that means to ship a preview and silently ships none has lost something it
cannot add until the next version. The argument against is that it is a
requirement nobody has stated, and this package has a rule about not inventing
those. Left open until a consumer asks.

### Open: the tree carries no `mimeType`

Status: **open**.

`appPreviews` accepts an optional `mimeType` at creation and nothing here sends
one. Apple infers it, and every upload this was written against is an `.mp4`. If
a ProRes `.mov` turns out to need it stated, this is where it goes — the
container is already parsed, so the value is in hand.
