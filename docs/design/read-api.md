# `package:cux_ship/read.dart` — the stores, as objects

Status: **decided**, 4 September 2026, at the moment a consumer's release train
was ported from shell to Dart.

A Dart consumer can ask the stores what they hold without spawning `cux_ship`
and matching regular expressions against what it printed. Three reads, plus the
wait: Play's tracks, and the App Store's builds and versions per platform.

## Why now, and why not earlier

`cux_ship`'s store clients are in `lib/src/` because being able to change them
fast is most of what this package is for. That is a real cost to give up, and
the request to give it up arrives as "I only need one method", which is how a
package ends up owing stability on its whole internals.

What changed is that a consumer's `status` stage was reading four regular
expressions off this command's stdout to answer "which build does each store
hold". That arrangement is worse than an exported API in both directions: the
consumer breaks silently when a listing's format shifts, and this package
cannot change a printed line without breaking a consumer it cannot see. The
export makes the promise explicit and small instead of implicit and total.

So it was taken deliberately, at the port, and not as a side effect of wanting
one method.

## The promise is `read.dart`, and it is thirteen names

Nine App Store, four Play. Every export carries a `show` clause and
`test/read_api_test.dart` fails if one does not, because an `export 'src/…';`
without one hands out the whole library and reads exactly like an export with
one. The same test holds the list of names, so growing the surface is an edit
somebody has to make on purpose.

Adding a name is cheap; removing one is a major version. The bar for adding is
that something outside this repository cannot be written without it.

## Reads only

Nothing exported uploads, promotes, publishes a listing or moves a build
between tracks — and the consumer that asked for this keeps its writes as
spawned commands on purpose. Two reasons, neither about how pleasant an API
would be:

- **The printed command line is what makes a failed release step resumable by
  hand.** A stage that failed after `upload.sh` prints the exact invocation
  somebody can re-run; an in-process call prints a stack trace.
- **Per-step `secrets exec --only …` is what keeps a credential out of a step
  that has no use for it.** An in-process write runs under whatever the host
  process holds, which is everything.

On the App Store side this is structural rather than a promise: every write in
this package goes through a `Writer`, and the one an `AppStoreReads` session
builds is a dry-run writer. On the Play side, reading tracks opens an *edit* —
Play offers no other way to list them — and the edit is deleted in a `finally`
rather than committed. Nothing exported calls `commit`.

That deletion is best-effort, inside its own `try`, and the reason is not
tidiness: awaiting a throwing call in a `finally` discards the exception already
in flight, so a cleanup that failed would replace the failure being reported —
which is usually the 403 saying the service account was never granted this app,
the only actionable message in the exchange. It was safe by accident before this
change, because the deletion sat in the same function as the `catch` and a
`catch` runs first; splitting the read out for `PlayReads` moved the `catch` to
the caller and took that ordering with it.

## Both the values and the rendered lines

Every result carries `lines` beside its fields, and the CLI prints those same
lines: `printBuilds` and `printVersions` render `AppStoreBuilds.lines` and
`AppStoreVersions.lines`, and `play tracks` renders `PlayTracks.lines`.

This is not a convenience. The consumer prints them verbatim and extracts only
the build numbers, deliberately, because a `status` that renders the same model
its own way reports something different from what this command reports, and
does it silently. That only works if the lines it prints are the lines this
command prints — so there is one formatter, and the model is what feeds it.

**They are this package's sentences, not the store's.** This section used to
say "the store's own lines", and the overstatement mattered later.
`AppStoreBuild.line` is `'  build $buildNumber  $processingState  uploaded
$uploadedDate'` — composed from parsed fields, exactly as
`lib/src/play/reads.dart` says at the top: "The printed lines are derived from
these objects, not the other way round." What `lines` buys is one formatter,
not fidelity to a store's format. Read the wrong way, it made carrying the
rendering inside a JSON document look like a contradiction rather than a
labelling problem — see [json-output.md](json-output.md).

## What the export fixed on the way

`appstore builds` sorted the way Apple returned, and Apple's `sort=-version` is
lexical: build 9 above build 10. `appstore build-number` has always sorted
numerically before answering, so the two commands could name different builds
from the same account. The listing now uses that comparator too. It is a change
to printed output, and it is the change that makes "newest first" true.

`AppStoreBuilds` answers two questions that were one: `newest` is the highest
build Apple holds, and `newestUsable` is the highest that is processed and
unexpired. A build uploaded four minutes ago is the first and not the second,
and "which build does the store hold" wants the first.

**And the same lexical mistake turned out to be waiting one layer up.** A build
number is a `String` here because `CFBundleVersion` is one and Apple accepts
`1.2.3`. The first consumer's `status` compared what this command printed
against an integer out of a git tag — correct only while every build number has
the same width, which that account's did, and wrong at 1000. It was found by
reviewing this export rather than by either suite, because both sides' fixtures
were equal-width; the consumer had already merged it.

So `AppStoreBuild.buildNumberAsInt` exists, null rather than zero for a version
string that is not a single integer, and `_byBuildNumberDescending` reads
through it. One parsing rule, and the rule this package orders by is the rule it
hands a caller — which is the same argument that made the listing share
`build-number`'s comparator, applied across the package boundary instead of
within it. A doc comment alone would have been the weaker half: this repository
keeps a rule in prose only while it cannot be a check.

## Not split into its own package

The workspace root has `cux_ship_appstore/`, `cux_ship_play/` and
`cux_ship_notes/` directories holding nothing but a stale `.dart_tool/`. They
are not reserved names for a planned split — they are the residue of a split
that was performed and then **deliberately reversed** in `e5e4647`, "Split by
what a lockfile gets, not by how the extraction happened":

> The old boundaries were a record of how the extraction was performed rather
> than of anything a consumer cares about. Nothing outside `cux_ship` ever
> imported the two clients, and pub forbids a path dependency in a published
> package — so publishing five would have meant five versions, five changelogs
> and a lockstep release, entirely to preserve internal structure.

Re-creating them for this would fail the same test. The boundary that commit
kept is what a consumer's lockfile gets, and a caller reading Play tracks needs
googleapis whichever package the client lives in — so a `cux_ship_play` would
give its lockfile nothing that `cux_ship` does not.

It also would not narrow the semver promise, which is the argument for
splitting. The promise is the exported surface, and `read.dart` with `show`
clauses is exactly as narrow as a separate package's `lib/` — enforced by a
test rather than by a directory.

And it could not ship as a branch. `cux_ship` would name the new packages as
hosted constraints that do not exist on pub.dev, which is precisely the
"unconsumable as a git dependency" state `e5e4647` recorded and CI's consumer
probe goes red on. The work has to be pinnable before it is published.

If the split is ever right again, the reason will be a consumer that wants one
store's client *without* the other's dependencies. Nothing has asked for that.

## Credentials move into the calling process

Both sessions read the environment `cux_ship secrets exec` sets up, so an
in-process read needs those variables in the *caller*. A stage making both a
Play and an App Store read therefore runs under one `secrets exec` carrying
both, instead of a per-call `--only`. That is a real widening of what each call
can reach, and it is the trade a consumer accepts when it stops spawning: named
here so it is a decision rather than a discovery.

## `appstore wait` reports rather than prints

The wait polls for up to forty-five minutes and used to report only by writing
two lines to this process's stdout, which is unusable in-process. It now calls
`onProgress` once per poll — including the poll that ends the wait, so a log
records *how* it ended and not merely that it stopped — and the printing is one
caller of that callback. Existing behaviour is unchanged because
`printProcessingProgress` is the default.

## Was a library the right answer, or would `--json` have been?

Status: **open**, 10 September 2026. Raised by the consumer this API was built
for, after living with it, and recorded a day before it was acted on. The
transport half is decided and specified in [json-output.md](json-output.md) —
`--json`, carrying the rendered lines. What this status names is the half that
stays open: whether `read.dart` should have existed at all. The sections below
are unchanged, because nothing about that was settled.

### The gap in the decision above

Read §"Why now, and why not earlier". It compares the library against exactly
one alternative: **matching regular expressions against printed prose**. The
whole argument is that the old arrangement "breaks silently when a listing's
format shifts" and that "the export makes the promise explicit and small
instead of implicit and total".

Every word of that is equally an argument for a JSON schema. A schema is also
explicit, also small, also versioned, and also stops a format shift breaking a
consumer silently. **This document never distinguishes the two, because it
never had the second one in front of it.** So the decision was not "library
over JSON"; it was "library over the status quo", and `--json` was not on the
table.

### And the precondition it states is false for the consumer it was written for

§"Credentials move into the calling process" is honest about the trade — "a
real widening of what each call can reach, and it is the trade a consumer
accepts **when it stops spawning**".

That consumer never stopped spawning. Its release train spawns Gradle and
Xcode, so putting credentials in the reading process would hand them to every
build by inheritance — the regression 3.0.0 was cut to prevent. It therefore
had to split the read into a second entrypoint that spawns nothing, wrapped in
`secrets exec`, which exists solely to work around the interface and which
introduced a defect of its own: an exception from one store's read discarded
every line collected before it, so a run that read Play and then met a 401 from
Apple printed nothing at all. Spawn-and-parse has no such shape.

A `--json` consumer pays none of that: the child holds the credentials, the
orchestrator holds none, and there is no second program.

### What a library still buys, and it is thinner than it looks

The first draft of this section kept `awaitBuild` as the surviving
justification — a forty-five-minute poll reporting each attempt to a callback
is not a document, and line-delimited events were "possible and worse".

**That does not survive contact with the consumer's code.** Its runner already
spawns a child and calls back per line, heartbeating on the most recent one; it
is what drives two concurrent `appstore wait` calls today. So a per-poll
callback is not something a library provides and a command cannot — it is
something that consumer already does against a command, and prose versus JSON
is the only variable. NDJSON out of a long-running command is the ordinary
pattern rather than an exotic one.

What is genuinely left is typed progress and typed terminal exceptions against
a decoded map and an exit code — which is the same "rules not data" argument,
and that one is not durable either: `newestVersionCode` and `newestBuildNumber`
can be *emitted* as computed fields rather than exposed as accessors, and a
schema that carries them protects a shell caller too, which a Dart library
structurally cannot.

### So the question is bigger than the one first asked

Not "`--json` for the reads, keep the library for the wait". It is **`--json`
for everything, and does `read.dart` still earn its semver weight at all**.

Two constraints on answering it, neither of which is about which interface is
better:

- **`read.dart` is published, and removing an export is a major version.** The
  live question is whether the surface should have existed, not whether to
  break the consumer using it.
- **Sequencing.** `--json` does not exist. A consumer reverting to
  spawn-and-parse today gets prose-parsing, which is the defect this API was
  built to fix. So `--json` lands first, and reverting onto it is a second
  decision.

### Why this is recorded now rather than when somebody wants it

**Every consumer `read.dart` gains makes the surface harder to narrow**, and
the argument is cheapest to write while the evidence is fresh. Today there is
exactly one Dart consumer and it is the one that asked the question. That is
the widest the door will ever be.

The condition that would settle it in favour of `--json` is a consumer that
cannot call a Dart library at all — a shell `status`, `jq` at a terminal, a CI
step reading one number. Those are the majority shape for release tooling and
none of them exists yet *here*, which is the honest reason this is open rather
than decided.

### What the consumer answered, and it was not that condition

Asked directly, the day after this was written. Recorded because the answers
narrowed the work more than the argument above did, and because one of them
falsifies the paragraph it follows.

**There is still no shell consumer, and `--json` was decided anyway.** Nothing
greps a number out of this command for a shell comparison; that path is gone.
The single consumer is one Dart program making at most five reads, and it wants
each result *twice* — as a number compared against a git tag, and as lines
printed verbatim. So the settling condition was not the one predicted above. It
was whether a JSON document carries the rendered lines, because without them
that consumer would have to re-render and would not port at all.

**`appstore wait` needs no event schema, measured at the call site.** It is
spawned, its stdout goes to a log a human reads after a failure, and the only
thing consumed is the exit code. Not one field is decoded. That kills the
line-delimited progress shape the first draft of this section treated as the
library's surviving justification — and it kills it on evidence rather than on
the argument, which had reached the same place by reasoning.

**No field is missing.** Four already-shipped fields go unread by that consumer
— `processingState`, `uploadedDate`, `expired` and `PlayTrackRelease.status` —
which is a gap on its side and not a request on this one. Worth recording
because "what does a consumer need" and "what does a consumer use" came back as
different lists, and only the first one would have been guessed.
