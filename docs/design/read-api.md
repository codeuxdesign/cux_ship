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

## Both the values and the store's own lines

Every result carries `lines` beside its fields, and the CLI prints those same
lines: `printBuilds` and `printVersions` render `AppStoreBuilds.lines` and
`AppStoreVersions.lines`, and `play tracks` renders `PlayTracks.lines`.

This is not a convenience. The consumer renders store output verbatim and
extracts only the build numbers, deliberately, because a `status` that
re-renders a store's table misreports the day the store changes the format and
does it silently. That only works if the lines it prints are the lines this
command prints — so there is one formatter, and the model is what feeds it.

## What the export fixed on the way

`appstore builds` sorted the way Apple returned, and Apple's `sort=-version` is
lexical: build 9 above build 10. `appstore build-number` has always sorted
numerically before answering, so the two commands could name different builds
from the same account. The listing now uses that comparator too. It is a change
to printed output, and it is the change that makes "newest first" true.

`AppStoreBuilds` answers two questions that were one: `newestBuildNumber` is
the highest build Apple holds, and `newestUsable` is the highest that is
processed and unexpired. A build uploaded four minutes ago is the first and not
the second, and "which build does the store hold" wants the first.

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
