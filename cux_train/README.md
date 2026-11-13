# cux_train

Orders the steps of a release, and waits on the ones a person performs.

**No command runs a release yet.** This package is the workspace member that
How It Went's release train moves into, created ahead of the move so that each
step arrives as a commit against a package CI already builds, formats, tests
and runs a publish dry run over — rather than as one commit that creates a
package and fills it at the same time.

What exists today is the **destination table** and the **promotion record**. A
consumer declares where a release has to go and who acts at each stage, and
`--store` resolves against that declaration rather than against a list compiled
into the tool. The record says what the release has already reached, read from
git refs a caller hands over; from it come the two questions a resumable run
asks — what is still outstanding, and whether the version tag may be spent.
Over both sits the **evidence model**, which decides what `status` is allowed
to claim about a cell: read, recorded, contradicted, failed, unknown, or
nobody's job.

All of it parses and answers questions. It spawns nothing, runs no git and
contacts no store, which is what lets every case be tested with no credential
and no network. The entry point still says there are no release commands,
because there are none.

The plan, the measurements behind it and the questions still open are in
[docs/design/release-train.md](../docs/design/release-train.md); what a second
consumer needs, and the staging this is step 1 of, are in
[docs/design/authpass-on-the-train.md](../docs/design/authpass-on-the-train.md).

## What it is for

`cux_ship` acts on an artifact that exists: upload it, publish the listing,
promote what is already up. A release has a step before that — allocate the
build number — and steps after it that are not store writes at all, and
something has to put them in order, carry each one's credentials, and record
which of them have been done.

That ordering is the train. It spawns `cux_ship` for every store write rather
than importing its clients, which is why it is a sibling member here and not a
library inside `cux_ship`: a printed command line somebody can re-run by hand,
and per-step credential narrowing, both survive the arrangement.
[§2 of the design document](../docs/design/release-train.md) is the argument,
including why this is not the proposal `read-api.md` declined.

## What a second consumer changed about it

The train was written for one repository and AuthPass is the second, which is
what turned "extract it" into a design question rather than a move. The useful
finding is in §8: AuthPass performs most of its release by hand — its macOS
build is notarized on a laptop on purpose, and its README's "Releasing" section
is an ordered checklist ending in eight store consoles — so what it needs is
not automation of those steps but **ordering** of them. A destination the train
names and waits on, rather than spawns, gives it the order, the status block
and a preflight with nobody's workflow changed.

## Using it

There is nothing to use yet. When there is, it will be launchable the way its
siblings are, without a consumer having to find the package in the pub cache:

```bash
dart --packages=<checkout>/.dart_tool/package_config.json \
     package:cux_train/cli.dart help
```

`bin/cux_train.dart` is a one-line export of that library, so `dart run
cux_train` and `dart pub global activate` work as usual.
