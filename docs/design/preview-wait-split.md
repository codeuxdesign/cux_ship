# Unwelding the preview wait, the way the build wait is already unwelded

Status: **built**. Everything proposed below shipped, in the shape argued for
except where *What shipped, and where it differed* says otherwise. The sizing of
the default timeout is still open and is argued in `store-preview-rules.md`,
not here.
`store-preview-rules.md` is the document for previews generally; this one exists
because the change has an interface, and an interface is worth arguing before it
is typed.

Asked for by the first consumer's owner, in the form *"not sure if waiting for
30 minutes is the right choice — maybe there should be another status/wait
command. How is this currently handled for the builds which also need
processing?"* The answer to the second half is the whole design: **builds
already solved this, and previews are the one asset that did not get it.**

## What builds have, and previews do not

| | build | screenshot | preview |
|---|---|---|---|
| Apple's documented tail | about an hour | — | **24 hours** |
| Default timeout | 45 min | 10 min | 30 min |
| `--timeout` / `--poll` | yes | no | no |
| A command that only waits | `appstore wait` | no | no |
| A way not to wait | `--skip-waiting` | no | no |
| Progress a caller can consume | `BuildProcessingProgress` | no | no |

The preview row is the wrong way round on every line. It has the longest
documented tail of the three and the fewest ways to manage it, and
`awaitPreviewProcessing`'s own doc comment notices the twenty-four hours and
then sizes its timeout against the *screenshot* — the sibling with the shortest
tail — rather than against the build.

**And `--skip-waiting` cannot rescue it even when reached for.** The flag is
declared on `upload` and read inside the artifact branch; a metadata-only run
has no artifact, so the one command that publishes a preview never consults it.
The escape hatch exists, is spelled correctly, and is unreachable.

## The principle is already written down

`cli.dart`'s header states it, about builds:

> An `upload` carrying an artifact is three phases, and each one can be run on
> its own. The transfer is exclusive and bounded — Apple accepts one
> CFBundleVersion once — the processing wait is shareable and takes five to
> fifteen minutes, and the writes that follow are exclusive again and take
> seconds. Welded together, the whole command inherits the worst of each.

Every clause is true of a preview upload, and more so. The transfer is exclusive
and bounded (Apple takes one set per type per locale), the wait is shareable and
takes minutes to hours, and the poster-frame assertion after it takes seconds.

**But the parallelism argument does not apply to the only real caller, and it
should not be used to justify this.** Answered directly: that project publishes
`store/appstore/ios` and `store/appstore/macos` from one commit, and **only iOS
has a `previews/` directory** — macOS has none and plausibly never will. So
there is one ingestion queue, nothing to overlap, and the split buys **ergonomics
rather than time** for the caller it was proposed for. Judge it on that. The
concurrency case is real for a project with previews on two platforms and no
such project exists yet.

## Proposed: one flag and one command

### `upload --metadata --skip-waiting`

Extends the existing flag rather than adding one. The upload publishes the
listing, uploads the previews, commits them, and **stops before
`awaitPreviewProcessing`** — printing the command that finishes the job, the
way the artifact path already prints `appstore wait N`.

Two consequences that have to be handled rather than discovered:

**The poster frame is asserted after ingestion**, so skipping the wait skips the
assertion, and the preview is left at Apple's default until the follow-up
command runs. This is the same shape as `--skip-waiting` skipping the TestFlight
notes, which `cli.dart` calls out as *"named, because skipping the wait skips the
notes with it"*. It is louder here: a default poster frame is invisible rather
than merely absent. So the printed follow-up is not optional advice, and the
line saying so is part of the change.

**`promote --metadata --skip-waiting` must be refused offline.** A promotion
submits for review, and Apple refuses a submission whose assets are in flight —
with an error naming the version rather than the assets, which is the failure
this whole feature exists to avoid. This is the exact analogue of the existing
`--skip-waiting` + `--beta-group` refusal: *"incompatible things: a build that
is not waited for, and a release that needs a processed one."*

### `appstore wait-previews`

A sibling to `appstore wait`, not a flag on it. The two wait for different
things with different required arguments, and `appstore wait` takes its build
number *positionally* — overloading that positional with a version name is how
a command becomes unreadable.

```
cux_ship appstore wait-previews \
  --bundle-id design.codeux.howitwent \
  --version-name 1.1.6 \
  [--platform ios] [--timeout 2h] [--poll 30s]
```

Mirroring `appstore wait` deliberately:

- **`--version-name` is required and not defaulted to the newest.** `appstore
  wait`'s help gives the reason and it transfers unchanged: *"the point of
  waiting on another machine is to wait for a specific build, and 'newest' would
  succeed on somebody else's upload."* A version is the same kind of thing.
- **`--timeout` and `--poll` with the same spelling** — `45m`, `90s` — parsed by
  the same `_duration`.
- **It carries only its own arguments.** No artifact, no changelog, no metadata
  tree: it publishes nothing and waits for what is already there. `appstore
  wait` and `beta-release` both say this about themselves.
- **It asserts the poster frames when the wait ends**, which is the phase
  `--skip-waiting` deferred. That makes the pair complete: `upload
  --skip-waiting` transfers, `wait-previews` finishes.

~~`--locale` and `--preview-type` are optional narrowings~~ — **dropped.** The
only caller has one locale, one preview type and one video, and said plainly
they would not use them. They stay in this paragraph as a record of having been
considered: a project with several locales' previews in flight would want them,
and adding them then is cheap. Adding them now would be a flag with no consumer,
which this repository has a rule about.

### `PreviewProcessingProgress`, and a callback

`BuildProcessingProgress` exists because *"a consumer streaming that to a log
wants a heartbeat with its own timestamps and its own destination — which it
cannot have if the only report is a line on this process's stdout."* A
twenty-four-hour tail makes that argument harder, not softer.

The shape mirrors it, with the one structural difference previews have — **two
states, not one**:

```dart
class PreviewProcessingProgress {
  final String previewId;
  final String? fileName;
  final String? videoState;      // null: Apple reported none
  final String? frameState;      // null: Apple reported none
  final Duration waited;
  final Duration timeout;
  bool get done => videoState == 'COMPLETE' && frameState == 'COMPLETE';
}
```

The default `onProgress` prints the line `awaitPreviewProcessing` already prints
per transition, so nothing changes for a caller who passes nothing.

## The one decision that is not a mirror

**Reaching the deadline is not a failure, and the build path treats it as
one.**

`appstore wait` raises `ProcessingTimeout` because a build that never becomes
visible has usually been *refused*, and Apple reports that only by e-mail — the
timeout is evidence of a problem. A preview at thirty minutes is evidence of
nothing at all: Apple documents twenty-four hours, and this document's own
measurement section records a real ingestion at 7m29s with no idea whether that
is typical.

So `wait-previews` reaching its deadline should print what is still pending, say
how to resume, and **not fail**. An outcome the documentation calls *ordinary*
should not be an error, and the current 504 is worse than merely wrong: its text
tells the operator to re-run the upload, which is the loudest possible
instruction to do the thing that was, until dev.2, a silent defect.

**"Not a failure" is not the same as exit zero, and the first draft of this
conflated them.** The consumer's runner branches on exit status and never on
text — deliberately, because their SHIPPING §12.2 records a status escaping from
four regular expressions matched against stdout. Exiting zero at the deadline
makes "all complete" and "still pending" indistinguishable to exactly the caller
this is for, and sends it back to parsing prose.

So: **0 when everything reached `COMPLETE`, and a distinct non-zero code for
"reached the deadline, still pending"** — distinct from the code a real failure
uses, so a script can branch on three outcomes without reading a word. This
repository already treats exit codes as a vocabulary rather than a boolean;
`screenshots flatten --check` exits 2 for "would change", and `provenance`
records choosing 3 *because* 2 was taken. The pending code is the same kind of
statement.

`upload --metadata` without `--skip-waiting` keeps raising, because there the
deadline means "I cannot safely proceed to the next phase".

Same condition, three outcomes, two callers — which is exactly why the wait
wants to be a command rather than a step.

## Also proposed, because they acquired a consumer

Both of these were in a "deliberately not proposed" section, on the grounds that
nobody had asked. Somebody asked, in the same message that answered the
questions above, and **they arrive together for one reason: the new caller is a
reader where everything before it was a doer.** That is worth weighing as a
single change of shape rather than as two feature requests.

**`appstore previews` — a read command.** The consumer is building
`tool/train.sh ready`, which answers *"can production run, and is the store
showing the repo's listing?"* **without waiting for anything**. That wants a
listing, not a wait. Without it, `ready` has to run `upload --metadata
--dry-run` and read prose — which is the thing this package exists to stop
people doing. It sits beside `builds` and `versions`, which is where a reader
belongs.

**`--json` on it.** Same consumer, and their reason is structural rather than
convenient: `tool/train/lib/src/status.dart` already spawns reads with `--json`,
and their pubspec states the property that makes it safe — reads are spawned
children under one credential, and the train only ever holds *decoded
documents*, never a store client. `ready` needs to print `preview apple30.mp4
COMPLETE, poster frame 00:00:02:06`, which is a document rather than a line of
output.

Note this weakens the `appstore wait` precedent rather than following it: that
command has no `--json` because *"`wait` reports progress nobody decodes."* The
sentence was true when written and is now false for previews, which is the
ordinary way a rule like that expires. `docs/design/json-output.md` governs the
document's shape.

## What shipped, and where it differed

Four differences, none of them large, all of them found by writing the thing
rather than by arguing about it — which is the usual ratio and the reason this
section exists instead of a claim that the proposal was right.

**`--json` splits by stream, not by flag.** Proposed as "a document instead of
the report"; built as *progress on stderr always, document on stdout under
`--json`*. The consumer suggested it and it is better: a read has one answer, but
a wait has progress **and then** an answer, and one document at the end cannot be
rendered as progress. Splitting by stream gives a person the live report and a
program a clean document without either having to choose, and it sidesteps
NDJSON — streaming progress as data later becomes a compatible addition rather
than a redesign.

**The document carries Apple's field names.** `videoDeliveryState`,
`previewFrameImageState`, `previewFrameTimeCode` — asked for explicitly, and
right: a reader can hold the document beside the App Store Connect reference
without a translation table. Where this package has an opinion — `done`, meaning
both assets finished — it says so in a field of its own rather than by renaming
Apple's, which is the split the build documents already make between
`processingState` and `processingStateRaw`.

**There is no "no such version" message, in either command.** Both were written
with one, and neither could ever print it: `ensureVersion(create: false)` throws
a 404 naming the version, and returns null only on the create path. The refusal
was always Apple's; the branches were dead and are gone.

**The `--version-name` refusals have no tests.** `fail` calls `exit(1)` by
design, so an in-process test takes the whole run down rather than failing one
case, and a subprocess cannot reach the check without credentials. Recorded in
the test file too, because it is a property of every `fail` in `cli.dart` and
not of these two.

**`wait-previews` takes a `--metadata` tree, which §"`appstore wait-previews`"
above says it would not.** That bullet — *"it carries only its own arguments.
No artifact, no changelog, no metadata tree: it publishes nothing and waits for
what is already there"* — was wrong about what the command has to do, not about
what is tidy. Apple discards `previewFrameTimeCode` sent at reservation, so the
poster frame must be asserted *after* ingestion; that is the phase `upload
--skip-waiting` defers, and asserting it needs the tree that names the frames.
A `wait-previews` that could not finish that job would leave the pair
incomplete, which is the one thing the split was for. So the command publishes
nothing and *does* write one attribute, and the flag is optional: without it
this only waits.

**The `promote --metadata --skip-waiting` refusal was not built, and did not
need to be.** §"`upload --metadata --skip-waiting`" argued for an offline
refusal on the grounds that submitting with assets in flight is refused by
Apple with an error naming the version rather than the assets. The flag is
declared only under `case AscCommand.upload`, so `promote --skip-waiting` is
rejected by the argument parser as an unknown option and the state is
unreachable rather than refused. Better than what was proposed — an
unrepresentable state needs no check, and no check can drift from it — but it
is not the shape this document argued for, and a reader looking for the refusal
would otherwise go hunting for something that was never written.

## What is still deliberately not built

**`PreviewProcessingProgress` as a public Dart API.** The consumer's answer to
"do you want this programmatically" was *yes, via `--json`* — which is a
different thing, and the cheaper one. The class stays internal to shape the
callback and the document; nothing needs to import it.

## The timeout question is not here

**Thirty minutes is still a guess, and this document is not where that is
argued.** `store-preview-rules.md` §*Open: thirty minutes is a guess* holds it,
including the measurement the first consumer has undertaken to take and the
reason the third finding — which of the two assets Apple finishes first — matters
more than either duration. Restating it here would be a second copy of an open
question, which is the specific way an index of open questions goes stale.

What this change did was make the guess cheap rather than correct: `--timeout`
makes the number a caller's, `wait-previews` makes the wait re-enterable from
anywhere, and `previewsPendingExit` makes running out of time distinguishable
from failing without reading a word. That is why the number was not worth
blocking on, and it is recorded over there too.

## Answered by the consumer, and what each answer changed

The five questions this document opened with were put to the one project
running previews in anger. Every answer moved something, and three of them moved
a decision rather than a detail — which is the argument for having asked before
writing code rather than after.

| asked | answered | what changed |
|---|---|---|
| More than one platform per commit? | Yes, but **only iOS has previews** | The parallelism justification is withdrawn; this is ergonomics |
| Call `wait-previews`, or poll later? | **Both, and they are different commands** | `appstore previews` promoted from not-proposed |
| Exit zero at the deadline? | Not sufficient — **they branch on status, never text** | A distinct pending exit code, not plain zero |
| `--locale` / `--preview-type`? | **Noise** for them | Dropped |
| `PreviewProcessingProgress` programmatically? | **Yes, as `--json`** | `--json` promoted from not-proposed |

Two of those overturned things this document had already decided, and one —
the exit code — overturned a decision it had argued for at length. The reasoning
that produced it was not wrong about *failure*; it was wrong about conflating
"not a failure" with "exit zero", which only a caller that branches on status
would notice.

**One premise was also corrected on their side rather than mine**: they had told
me the train never publishes the App Store listing, and on reading the source
found `metadataPath` defaults from the project, so it has been publishing all
along. The thing that was missing was only ever a pause. Recorded because this
document's first draft was written against the wrong picture of the caller and
came out substantially the same, which is luck rather than method.
