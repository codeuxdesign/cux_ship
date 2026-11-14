# Changelog

## 0.1.0-dev.1

### Added

**The promotion record, and the two questions a run asks of it.** What a
release has already reached, as `promoted/<destination>/<stage>/v<version>+N`
refs — the donor's existing tag shape — plus `refused/…` for a step that was
attempted and turned down. `PromotionRecord` owns the grammar, `PromotionLedger`
reads a build's worth of them, and `finishRule` says whether the bare version
tag may be spent. Still no git, no store and no credential: a caller hands over
ref names.

**A `family:member` destination cannot go in a ref, and nothing had noticed.**
`git check-ref-format` refuses a colon — verified, not assumed — and six of
AuthPass's nineteen destinations have one. The design document writes the shape
as `promoted/<dest>/<stage>/v…+N` throughout; the donor never hit it because it
only ever recorded `play`. The colon travels as a slash, so `appstore:ios`
records at `promoted/appstore/ios/production/v1.9.13+2196` and the destination
is read back by parsing from the right, where the shape is known.

**A refusal is filed under its own namespace rather than as a flag inside the
ref**, because the existence of a ref is what everything else reads — a refusal
under `promoted/` would be counted as a promotion by any `git for-each-ref`
one-liner that globs and does not parse. Where both exist for one cell, the
refusal wins: ref names carry no time, so guessing which is newer would be a
worse answer than stopping the run and showing a human both.

**The finish rule is keyed on the record, not on how the run was narrowed.**
The donor asks whether `--store` named every store, which a `production` that
spans days can never satisfy — the operator finishing the last console with
`--store ppa production` would never be allowed to spend the tag. Both of §3's
exclusions are here: a destination nobody acts at is satisfied vacuously, and
one declared `after-finish` is skipped because its step annotates the tag it
would otherwise precede. `after-finish` is a new table key, refused on a
destination with no production step, where it would silently do nothing.

**The destination table, and `--store` resolved over it.** The first piece of
step 1 in
[docs/design/authpass-on-the-train.md](../docs/design/authpass-on-the-train.md),
and the one the rest of that step keys off: `--store`, `status`, the promotion
record and the finish rule all name destinations, so the table comes first.
`DestinationTable.parse` reads a consumer's declaration; `resolveStores`
answers what one invocation acts on. Nothing here contacts a store or spawns
anything — step execution needs the record and the evidence model, and keeping
them apart is what lets this be tested with no credential and no network.

A destination declares, per stage, one of four step kinds — `ship` (the train
spawns `cux_ship`), `run` (a consumer script), `manual` (a person acts; the
train instructs, waits and records) and `none` (nobody acts, which is a fact
about the destination rather than a gap). It may also declare how to be read,
and its own identity: a `package` or `bundle-id` per destination, because the
donor's singular `appleBundleId` cannot express a consumer with two App Store
records and two Play packages. The `family:member` name form is the donor's own
`appstore:ios`, generalized — `--store appstore` is both members, `--store
direct` is every direct download.

**A flag that would do nothing is refused rather than dropped**, which is the
donor's rule applied to a table: `--store amazon beta` refuses and names the
stages Amazon does have. A family with some members staged acts on those and
reports the ones it skipped, so a narrowed run never reads as broader than it
was. An unknown value is refused with the declared names, and a bad member of a
real family is answered with that family's members rather than the whole list.

An unknown key is an error, as in `cux_ship`'s `.cux-ship.yaml` and for the
same reason: a misspelt `prodution:` that is quietly skipped is
indistinguishable from a destination that deliberately has no production step.
A missing stage is the one exception and is read as `none`, because fifty-seven
cells, twenty-four of them nobody-acts, is a table whose rows get copied
instead of read. A stage *written and left empty* is still refused — absent and
explicit-null are different acts — but a stage whose key is simply gone is only
caught at the stage it was needed for, as a refusal when the run names that
destination and as a skip when it does not. That is weaker than a refusal and
it is what the default costs.

**Two guards in the first draft were dead, and the mutation run is what said
so.** A second condition in `coversEveryDestination` that could never be false,
and a `seen` set deduplicating names that the final rebuild already
deduplicated. Both survived their mutations with every test green, both read as
load-bearing, and both are gone — the behaviour they appeared to guarantee is
held by one line each.

**The package, as the fourth workspace member**, ahead of the release train
that `docs/design/release-train.md` plans to move into it. It has an entry
point and a usage text; no release command exists yet, and the usage says so.

`package:cux_train/cli.dart` is launchable from the start, the way `cux_ship`
and `cux_buildnumber` became launchable in their last release, so no consumer
ever has to recover this package's path out of `package_config.json`:

```bash
dart --packages=<checkout>/.dart_tool/package_config.json \
     package:cux_train/cli.dart help
```

An invocation the command cannot run exits **64** — `EX_USAGE`, the code
`cux_ship` gives a `UsageException` — and writes the message and the usage to
stderr, leaving stdout empty. Both halves are tested: a release step driven
from a shell script treats a misspelled command that exits 0 as a step that
silently did not run, and a consumer capturing stdout for a step's result
should not find help text in it.

### Changed

**The Dart floor for the whole repository is unchanged, and that is a finding
rather than a default.** The donor package declares `sdk: ^3.13.0`, which
`release-train.md` §7 priced as forcing a Flutter bump on AuthPass — whose
pinned Flutter 3.44.7 bundles Dart 3.12.2. The constraint turned out to be
incidental: declared at `^3.12.2`, a copy of that package analyzes with no
issues, so it uses no 3.13 language feature. This member therefore sits at
`^3.12.2` with its three siblings and the workspace root, and the ordering
stage costs the consumer no SDK move. The design document records what was run.
