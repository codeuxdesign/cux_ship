# Unwelding the preview wait, the way the build wait is already unwelded

Status: **proposed**. Nothing here is built. `store-preview-rules.md` is the
document for previews generally; this one exists because the change has an
interface, and an interface is worth arguing before it is typed.

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
A caller publishing two platforms' listings from one commit serialises both
ingestion queues today for the sake of two transfers.

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
  [--platform ios] [--locale en-US] [--preview-type IPHONE_67] \
  [--timeout 2h] [--poll 30s]
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

`--locale` and `--preview-type` are optional narrowings, defaulting to every
preview the version holds. Unlike the build case there can legitimately be
several, and a caller waiting on one locale's set should not block on another's.

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

**Reaching the deadline should exit zero, and the build path does not.**

`appstore wait` raises `ProcessingTimeout` because a build that never becomes
visible has usually been *refused*, and Apple reports that only by e-mail — the
timeout is evidence of a problem. A preview at thirty minutes is evidence of
nothing at all: Apple documents twenty-four hours, and this document's own
measurement section records a real ingestion at 7m29s with no idea whether that
is typical.

So `wait-previews` reaching its deadline should print what is still pending, say
how to resume, and exit **zero**. An outcome the documentation calls *ordinary*
should not be an error, and the current 504 is worse than merely wrong: its text
tells the operator to re-run the upload, which is the loudest possible
instruction to do the thing that was, until dev.2, a silent defect.

`upload --metadata` without `--skip-waiting` keeps raising, because there the
deadline means "I cannot safely proceed to the next phase". Same condition, two
callers, two right answers — which is exactly why the wait wants to be a command
rather than a step.

## What is deliberately not proposed

**`appstore previews` as a read command.** `builds` and `versions` exist and a
preview listing would fit beside them, but nobody has asked for one, and this
repository has a rule about flags on commands with no consumer — *"a promise
made to nobody"*. The wait's progress lines report the same states.

**A `--json` document.** Same reason, and `appstore wait` does not have one
either: *"`wait` reports progress nobody decodes."* If a consumer wants to drive
this from a script, that is the moment to add it, and the consumer is the one
who should say so.

**Changing the 30-minute default.** It is sized against nothing and one
measurement is not a distribution. `--timeout` makes it a caller's problem
rather than a guess baked into a release, which is the useful half.

## Questions for the consumer, which this cannot answer alone

The one project running this in anger drives it from `tool/train.sh`, and the
shape above is worth nothing if it does not fit there:

1. **Does `train.sh` publish listings for more than one platform from one
   commit?** If it does, the parallelism argument is the whole point and
   `--skip-waiting` should come first. If it publishes one, the split is
   ergonomics rather than time.
2. **Would it call `wait-previews`, or would it rather the upload just did not
   wait and something later checked?** The build path assumes a caller that
   runs the follow-up; a CI job that ends may want a *status* it can poll from
   a later invocation instead.
3. **Is exit-zero-at-deadline right for it**, or does a script want a distinct
   exit code for "still pending" so it can branch without parsing text? The
   build path's non-zero is load-bearing for its caller; this one's may be too,
   in the other direction.
4. **`--locale` and `--preview-type` narrowing: needed, or noise?** They are
   cheap to add and cheap to regret.
5. **Does anything want `PreviewProcessingProgress` programmatically**, or is
   stdout enough? `BuildProcessingProgress` exists because a consumer asked;
   this one is proposed on the assumption that the same consumer will want the
   same thing, and that assumption is worth checking rather than inheriting.
