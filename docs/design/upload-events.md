# Watching an upload: `--json` as an event stream

Status: **built**, 14 September 2026 — `--json` on `play upload` and on
`appstore upload`, and nothing else. It is the first `--json` in this package
that is not one document, and most of what follows is about why that is a
different thing rather than a larger one.

**Tested by the first consumer against their release train before merge**, at
the branch commit: the stream decodes into the exported classes, the panel
renders a real progress cell from it, and — the check that mattered most —
`documents.dart` changing did not break their `status` command, which decodes
every store read through it. One finding came back and is
*100% is not finished* below.

Asked for by the first consumer, correcting their own earlier request. Their
release train (`tool/train/`) captures each build and upload to
`dist/train-*.log` and draws a pinned status grid above them; it gets a usable
picture of `tool/build.sh`, which marks four stages with `==> ` lines. **The
upload is the one step with nothing to show.** The resumable uploader prints
`uploading N bytes` once and then says nothing until the transfer ends, so a
three-minute upload and a wedged one are indistinguishable from outside for
their whole duration.

## Events, not progress lines, and the reason is what a quiet minute means

The first request was for plain progress lines — `45%` on stderr, parsed by a
regular expression. That was withdrawn before anything was typed, and the
argument for withdrawing it is the whole design:

> A percentage is only half of what a watcher needs. The states a long upload
> passes through are the other half, and they are what tell a reader whether a
> quiet minute is normal. A line saying `45%` cannot say that the transfer
> finished four minutes ago and the wait is now Apple's.

So a consumer renders a bar while the bytes are moving and a **state name**
otherwise. That is not a nicety on this tooling: on the App Store side the
transfer is a minority of the wall clock and Apple's processing — five to
fifteen minutes — is most of it, so a bar stuck at 100% would be the normal
state of an upload rather than the exceptional one.

## A stream is allowed to be written as it happens. A document is not.

`json-output.md` is explicit that a document is **built whole and written once,
at the end**, because `fail()` calls `exit()` and a document assembled onto
stdout as it is built leaves half an object there under an exit code that says
to trust it.

**That rule is kept, not bent, and this is not an instance of it.** Half an
object is unparseable and indistinguishable from a whole one until the parse
fails; half a *stream* is a sequence of whole lines that stopped. Each line
carries its own `schema` and `kind`, so a reader that joined late — or that is
reading the tail of a captured log — still holds something that says what it
is. There is no state carried between lines for a truncation to corrupt.

What replaces the guarantee, because something must:

> **A stream with no `result` line did not finish**, and stderr says why.

That is `json-output.md`'s "errors stay prose on stderr, and stdout stays
empty" said in a stream's vocabulary. The considered alternative was a terminal
event with an `ok: false` and a message, and it was rejected on the same
argument that rejected an error document: a parseable failure invites a
consumer to branch on it and treat the exit code as advisory. A *positive*
completion marker costs nothing and gives a reader more than the exit code
alone — the result carries what landed, so a caller does not have to parse the
exit code plus the last line of prose.

## Two kinds, because these are not the same stream

`play.upload` and `appstore.upload`, each with its own `schema` counter, on
`json-output.md`'s rule that a document nobody changed does not get a bump
because a sibling did.

Here that rule earns its keep immediately rather than eventually, because the
two streams genuinely differ:

| | `play.upload` | `appstore.upload` |
|---|---|---|
| byte progress | yes, per acknowledged chunk | **none, and no field for one** |
| `accepting` | the final chunk's response | never — altool is opaque |
| `processing` | never — a committed edit is live | Apple, 5–15 minutes |
| `committing` | the edit transaction | never — no edit to commit |
| result names | `versionCode`, `track`, `committed` | `buildNumber`, `platform`, `waitedForProcessing` |

`docs/CONTRIBUTING.md`'s first rule is that a sentence asserting what "the
stores" do is verified against both or split into one statement per store. Two
classes *are* that split: each one's dartdoc — which pub.dev renders and which
is the published statement of the format — says what its own store does, and
neither can quietly describe the other.

## Byte progress is the store's count, and it arrives per chunk

The requirement was precise and the reason for it is worth keeping:

> Emitted **per chunk the uploader actually completes and never on a timer**.
> The point of the signal is that it stops arriving when the transfer stops; a
> timer-driven tick turns at the same rate whether the socket is moving or
> dead, which is exactly the failure this is meant to make visible.

**The obvious implementation was rejected twice over.** Wrapping the artifact's
byte stream and counting what is read out of it is a two-line change and is
wrong in two ways: it measures bytes handed to the uploader rather than bytes
the store holds, and its offsets start at zero — so the first line after a
**resumed** upload would report a jump from zero rather than the offset the
store already has.

What is implemented instead observes the protocol googleapis speaks and this
package does not. A resumable upload is one `PUT` per chunk carrying
`Content-Range: bytes <start>-<end>/<total>`, answered `308` while there is
more to come and `200`/`201` for the last. `ResumableChunkObserver` is an
`http.Client` wrapper that reads the range off the request and writes a line
when the response accepts it. The number is therefore Google's, arriving when
Google says so, and it is absolute because it was read off the wire.

**The coalescing is the protocol's too.** `ResumableUploadOptions.chunkSize`
defaults to 1 MiB, so a 68 MB bundle is about sixty-eight lines — tens rather
than thousands, with no threshold of this package's own to pick, tune or get
wrong. That is measured in `test/upload_events_test.dart` rather than asserted
here, and it is the number that moves if anybody ever reaches for a smaller
chunk to get a smoother bar.

**`accepting` is written before the final chunk is sent, not after it is
answered.** Play validates the artifact inside the response to the last chunk,
so a state written after that response would name a wait that was already over.
Read back from a finished stream the two orderings look identical, because
nothing else is written between them — the first version of the test for it
was green against both, and the fix was to have the fake transport report what
the sink held at the moment the request arrived.

### 100% is not finished, and a consumer will compute it that way

**Found by the first consumer, on a real run against these events**, before
anything here had a second reader. Their panel did the obvious thing —
`(sent * 100 / total).round()` — and printed `100%` with four kibibytes still
in flight, because the last-but-one line of a 2 101 248-byte artifact is
2 097 152, which is 99.805%. A finished cell and an almost-finished one then
look identical, which is the confusion this whole stream exists to remove.

**The fix is the consumer's and the guidance is ours.** Nothing here can check
a rendering in a tree this package cannot see, so the rule lives where the
format is published — `PlayUploadEvent.bytesTotal`'s dartdoc, and the README —
and it is two rules rather than one:

- **Floor the fraction.** An artifact is not a whole number of 1 MiB chunks, so
  a rounded one reaches 100 before the transfer does.
- **Do not read 100% as finished however it is computed.** `bytesSent ==
  bytesTotal` means the store has the bytes and nothing more: Play has still to
  reach `committing`, and the App Store has still to reach `processing`, which
  is five to fifteen minutes long. `result` is the line that says the run
  finished, and it is the only one that does.

The wording that invited it is worth recording, because it was written here in
good faith: *"neither is rounded for you"* was meant as "the precision is
yours" and reads as "go ahead and round". Both rules above are the same one
this document already applies to the App Store half one section down — **a
display must not imply a state the data does not support** — so the failure was
not a missing principle but a principle applied to one store and not to the
consumer's arithmetic.

`play_upload_events_test.dart` pins the premise rather than the remedy: its
artifact is deliberately *not* a whole number of chunks, and a case asserts
that the last-but-one line rounds to 100 and floors to 99. Sized to an exact
multiple that case disappears, silently, and the warning above loses its worked
example — which is what that test watches for.

### And the App Store carries none of it, deliberately

App Store Connect has no endpoint that accepts a binary, so the transfer is
`xcrun altool --upload-package` — a subprocess speaking a transport Apple
documents nowhere, whose output this package captures whole. **There is no
per-chunk signal to report.** The alternative is a tick on a timer, which is
the one thing the requirement forbids and for the right reason.

So `AppStoreUploadEvent` has no `bytesSent` field at all, rather than a field
that is null on every line ever emitted — a format with a permanently empty key
is a format lying about itself, and a consumer would reasonably write code
waiting for it. What it carries instead is `bytesTotal` on the `transferring`
line: "sending 28 MB" beside a spinner tells a reader something true, where a
bar that cannot fill does not.

## No `display`, which is a departure and is the point of one

Every other kind here carries the rendered lines under `display`, because
`--json` **suppresses** the prose rendering: `printBuilds` returns the moment
it has written the document, so a consumer with no `display` would have to
re-render from the fields, and two renderings of one model drift.

An upload suppresses nothing. Every `==> ` line it has ever printed still goes
to stderr, in full and in order, because that stream is a log somebody reads
after a failure — the consumer's whole workflow is `dist/train-*.log` plus a
grid drawn above it. Carrying those lines in the events as well would deliver
each of them twice on two streams, and a consumer showing both would print
them twice.

The stream split is therefore the same contract with a different emphasis:
stdout carries the events and nothing else, **and** stderr carries everything
it always did.

### What that cost, in lines moved rather than in design

Thirty `stdout.writeln` calls in `appstore/cli.dart`, nineteen in
`play/cli.dart` across the command and three helpers, altool's relayed output
in `uploadPackage`, the processing wait's two lines in
`printProcessingProgress`, and the confirmation prompt in `confirm.dart` —
which is the *first* thing a run prints, before any credential, so left on
stdout it would have made every stream unreadable from its first byte.

All of it is routed through one function per file rather than branched per call
site, which is the lesson `publishListing`'s `out:` parameter already records
after three rounds of getting it wrong: each round covered what was reachable
then, and the next flag to reach a new block undid it.

## `--json` on `appstore upload` was refused, and the refusal was right

`dry-run-json.md` declined this in as many words:

> **`--json` on a real `upload`.** See the refusal above. If somebody wants a
> receipt of what a publish did, that is a different document — it has to
> describe partial success, which an intention never does.

Every clause of that is still true, and it is the argument *for* a stream
rather than against one: **a partial upload is exactly what an event stream is
for.** What could not be a document is a document; it is a sequence.

So the flag stays one flag and the mode chooses the format:

- `upload --dry-run --json` prints one `appstore.listing-diff` document, as
  before, byte for byte. A dry run transfers nothing and waits on nothing, so
  an event stream of it would report states nothing entered.
- `upload --json` writes the `appstore.upload` stream.

One stdout, one format on it, in both cases. The two carry different `kind`s,
so a consumer that reads `kind` first — which the format says to — can never
take one for the other.

**Play is not symmetric here, and that is the stores again.** `play upload
--dry-run` opens a real edit, transfers the real bundle, and then discards the
edit rather than committing it. The bytes move; the progress lines are genuine.
So `play upload --dry-run --json` streams like any other run, and
`PlayUploadResult.committed` is the field — the only one in the stream — that
says the last step did not happen.

## What this does not decide

**Whether `appstore wait` grows a stream of its own.** `json-output.md` refused
events for it, and measured rather than deferred: the consumer spawns it under
`secrets exec --only`, streams stdout to a log, heartbeats on the last line,
and **consumes only the exit code**. That is still true of `wait` invoked on its
own. What changed is that the same wait, reached *through* `upload`, is now
inside a stream that has a consumer — so the states are named there and the
standalone command is untouched. If `wait` is ever asked for, it is a third
kind with a counter of its own, not a widening of this one.

That the room existed at all is `json-output.md`'s doing, and it said so:
*"'no events for `appstore wait`' must not be generalized into 'no wait ever
needs typed progress'."*

**Whether a failure ever becomes structured.** Today a failed run ends the
stream and reports prose on stderr under a non-zero exit. The case that would
change it is Play's 403 — the one failure with an actionable cause the prose
already names — and nobody has asked to branch on it. Strings on stderr answer
today's question and leave a structured failure as an addition rather than a
replacement, which is the shape `dry-run-json.md` took for `problems` and for
the same reason.

**Whether `--json` reaches `promote`.** It is declared on `upload` alone. A
promotion transfers nothing and holds no artifact, so most of this vocabulary
would be states it never enters — and a flag on a command with no consumer is a
promise made to nobody, which is the rule this package already applies to
`play listing` and `appstore beta-groups`.

## Where the seam is, and the one line no test reaches

`ResumableChunkObserver` wraps the HTTP client `_openPlay` builds, because the
chunk acknowledgements it reads are the transport's and the generated API
neither exposes nor knows about them.

**A supplied `androidPublisher` is not wrapped and cannot be** — the seam
`play_upload_reuse_test.dart` uses hands `runPlay` an API object holding a
client nothing can get at. `play_upload_events_test.dart` therefore builds a
real `AndroidPublisherApi` over a fake `http.Client`, wrapping it exactly as
`_openPlay` does, which runs googleapis' chunking and retry policy for real and
fakes only the network. What no test covers is the one line in `_openPlay` that
composes those two calls, because reaching it needs a service-account
credential.

The App Store side has a second hole and it is worth naming: `transferring` is
announced immediately before `uploadPackage`, which shells out to `xcrun
altool`, so a case reaching it would hand a real artifact to a real Apple
endpoint on any machine that has altool. Every case in
`appstore/upload_events_test.dart` takes the branch where Apple already holds
the build. The line's *shape* is covered against the emitter; that the CLI
calls it at the right moment is not covered at all.

Both are written down rather than papered over, which is what
`upload_phases_test.dart` does with the same shape of hole.
