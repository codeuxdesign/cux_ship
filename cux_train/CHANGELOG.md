# Changelog

## 0.1.0-dev.1

### Added

**`cux_train internal`, the verb with two lanes.** §5: a consumer whose builds
happen on other machines has nothing to *do* at most of its destinations, so
this verb spawns one dispatch — the push CI reacts to, declared top-level as
`dispatch:` — walks the rows this machine owns, and then reads the rest until
each holds the candidate. §3's order, and three of its four items are about
spending nothing you cannot get back: the gates first, then a confirmation
that names what the push makes public, then the dispatch, and only then is
there anything to wait for.

**A `wait` step kind, and a `read` contract for it.** A destination CI fills is
not `none` — something is certainly happening there — and not `manual`, since
nobody is being asked to act. A `wait` row declares how to read what the
destination holds: one build number on stdout, nothing on stdout for "no build
yet", a non-zero exit for "could not answer". A `wait` with no `read` is
refused, because the clock would then be its only exit, and a `wait` outside
`internal` is refused, because waiting for somebody else's bot at production
would hold the version tag open for days.

**`--wait-timeout`, which §3 says is not optional because the failure signal
is.** Without `gh` there is no way to observe that a CI job failed, so for a
destination whose build failed the only exit is the clock. It takes `90s`,
`45m` or `2h`; a bare number is refused rather than read as minutes, and the
default is an hour, so the normal path never types it. A timed-out row is
`pending` — §6.2's "no evidence either way" — and never `failed`: not hearing
back is not being told no, and the summary says so in as many words.

**Nothing the wait sees is recorded**, which keeps §6.2's *observed* and
*attested* apart rather than turning the stronger evidence into the weaker one
on the way past. It also makes a re-run free: everything that already arrived
answers at once, so `internal` resumes by looking rather than by remembering.

### Changed

**`gates:` is keyed by the stage that runs them.** It was a flat list, on the
argument that `production` runs every gate it has so a key would be
documentation the parser enforced without reading — true of one verb and false
of two. §3 gives `internal` a `pre-build` gate and `production` a
`pre-release` one, and one list would hand each verb the other's: `release
finish --dry-run`, which refuses anywhere but the release branch, would have
run in front of the dispatch that creates the build it checks. A table written
the old way is refused with the new shape named. Within a stage it is still a
list, because the order there is the consumer's.

**`beta` runs the gates its stage declares.** The keys are stages, so the
schema accepts `gates: {beta: […]}` — and `beta` was the one spending verb
that never asked, so a gate on the verb that reaches public testers parsed,
was believed by whoever wrote it, and ran nowhere. §3 gives `beta` no gate
today; that is a fact about the tables rather than a licence for the verb to
skip the question.

**A walk that is one pass of several says so in its verdict.** "Every
destination this run covers is recorded" printed above two pending rows — true
of the walk, and read as the verdict on the release. It is "this pass" where
the verb has more than one, which `production`'s second pass has wanted since
it existed.

**A top-level `gates:` list, run before `production` spends anything.** §3
step 1: the `pre-release` hook and `release finish --dry-run` open the verb so
that a refusal — the wrong branch, a changelog with no section for this
version — arrives while it is still free, rather than from the finish step
after a person has visited every console. They run in declaration order, each
must exit 0, and the first failure stops the run.

The bodies are the consumer's and the contract is not: `HOOK_STORES` names the
destinations the run will act on, which §7 records as the half of the donor's
hook contract that is already generic. `{destination}` is not offered to a
gate, since a gate is about the release rather than one row. A gate must
spawn — `manual` would ask a person to assert what the train can check, and
`none` would pass by being empty — and an empty `gates:` list is refused for
the same reason, while an absent key means what it says.

**A dry run runs the gates**, because they spend nothing by contract and a dry
run that skipped them could not answer whether the release is ready.

**`StepSpawn` takes an environment**, added to the child's rather than
replacing it, so a hook body still gets the PATH it expected.

**`cux_train production`, the verb that finishes a release.** The production
stage walked as `beta` walks its own, then §3 step 5: the version tag is spent
once every declared destination with a production step is recorded, and the
destinations declared `after-finish` are walked afterwards in a second pass
the report labels. They are not touched while the tag is held, because
`fdroid-vX.Y.Z` pushed early would annotate a release that may never be
finished.

**The finish step is recorded, so it is spent once.** It writes
`finished/vX.Y.Z+N` and a later run that finds that ref says so rather than
spawning the command again. Until this the one irreversible step in the
package was the only one with no record, and a `production` re-run on a
finished release tagged a second commit — or failed on the taken name and
reported that the version tag was not spent when it had been.

**`--dry-run` reaches the end of the release again.** Recording nothing meant
the finish rule always said the tag was held, so the checklist stopped before
"create tag" and before every after-finish destination — which is most of what
§8 step 1 wants a dry run for. A dry run now subtracts what it has just said
it would do; a destination it would not reach still holds the tag.

**Everything the second half needs is resolved before the first half spends.**
A bad placeholder in an after-finish command, or in the `finish` template, was
refused only after every store had been handed over.

**A top-level `finish:` step in the destination table.** The command that
spends the version tag, spawned like any other. Composing `v{version}` here
would be inventing the consumer's convention and being silently wrong wherever
they spell it differently, so a table without one says so instead of treating
a fully recorded release as finished, and a `finish` that is `manual` or
`none` is refused when the table is read.

**The finish rule is asked of a freshly read ledger**, because the walk above
it has just written records and the question is what the repository holds now.

**`PromotingCommand`, extracted on the second verb that acts** — `--store`,
`--dry-run`, `--yes`, `--uploaded-tag` and the construction of a promotion
run. The walk itself is deliberately not hoisted: `production` making two
passes around the version tag is the one interesting difference between the
two verbs, and a template method with hooks would make it the hardest thing
here to read. `PromotionIncomplete` moved from `beta_command.dart` to
`promotion_run.dart` for the same reason it was declared there: it is about a
run, and now two verbs raise it.

**A destination with no step at a stage is no longer called an audience
everywhere.** "No beta audience" is §3's wording for `beta`, where sixteen of
nineteen rows have none; at production it said something untrue of `web`,
which reaches users at `internal` and has nothing left to do later.

**`cux_train beta`, the first verb that spends something.** §3's beta stage,
walked once: every destination with a beta step is performed and recorded —
`ship` and `run` by spawning the command the table declares, `manual` through
§6.1's instruction, wait and record. It is resumable because the record is a
tag rather than because of a flag, so a re-run names what is already recorded
and stops at the same destinations; and one destination refusing never stops
the others. Every command is resolved and the `uploaded/` tag is looked for
before the first destination is touched, so a mistake in the table's last row
or an unfetched tag is a refusal rather than a release half performed.

**A declared `command` is split into arguments and never handed to a shell.**
That field has been a string nothing read since it was written; this gives it
a meaning. Interpolation of `{version}`, `{build}`, `{destination}` and
`{stage}` happens *after* the split, so a value containing a space lands in
exactly one argument instead of becoming two, and a value carrying shell
punctuation is an argument rather than a second command. A placeholder the
package does not define is refused rather than reaching the command as itself.

**A template that reads as shell is refused rather than run as not-shell.**
`make build && ./upload.sh` would otherwise run `make` with three arguments
and be recorded as having done the upload. Unquoted `&&`, `||`, `|`, `;`,
`>`, `<`, `$`, a backtick, a `*` glob and a leading `~` are refused, and
quoting or escaping one says it was meant literally. A backslash keeps its
character unless there is a reason to escape it, so `C:\tools\ship.exe`
survives where a shell would leave `C:toolsship.exe`.

**`d` over a destination that already refused this build does not finish it.**
A refusal outranks a later hand-over and nothing clears one, so the hand-over
is recorded and the destination stays outstanding — reported as `handed over,
but the refusal stands` rather than as done. The refusal is named above the
keys, before the operator decides whether to resubmit, and the closing verdict
no longer tells them to re-run something a re-run cannot settle.

**A second refusal says the note is the first one.** `recordUpload` reports
the name as taken rather than replacing the annotation, so the new reason
existed only in that run's output while the tag kept the old one.

**A step whose command fails is reported and not recorded.** A `refused/` tag
for a non-zero exit would be permanent — nothing clears a refusal, and a
refusal beats a later hand-over on purpose — so a network timeout would mark
that destination refused for the life of the build. A refusal is a judgement
about the artifact; a failed command is an incident.

**`--dry-run`, `--yes`, `--store` and `--uploaded-tag` arrive with the verb
that acts**, which is where `runner.dart` said they would. `--yes` does not
answer a manual step, and off a terminal a manual destination is reported
pending while everything else is still performed.

**`incompleteExit`, a 2 for a stage a run did not finish.** The number the
removed `notReadyExit` was reaching for, now that there is a half of the train
with states that mean no: refused, failed, skipped, pending, or a dry run
that found work it did not do. A dry run that finds the stage already recorded
exits 0, because the code answers whether the build is at the stage.

**`cux_train ready`, which reads the record for a purpose.** §3's verb, with
the half of it that needs nothing but the destination table and the promotion
refs: what `production` would act on, who acts at each one, what the version
tag is still waiting for, and what an operator should take with them. A
destination that refused this build is called out rather than left as a row,
because a resumable `production` walks back into a refusal and an operator who
reads that as an ordinary queue entry resubmits the same binary.

**It reports and does not refuse, which is a correction to how it was first
written.** The first draft treated a refusal as a veto and exited non-zero.
§6.1 records a refusal so that the next `production` run returns to that
destination, so the veto was backwards — and because nothing clears a refusal
and a refusal wins over a later hand-over, it never lifted: with `ready &&
production`, one rejection stopped that build's release permanently, the
untouched consoles included. The `notReadyExit` the draft added went with it;
an exit code nothing can produce is the dropped flag in another spelling, and
the number returns with the reads that can refuse.

**A record for a destination the table does not declare is refused.** The
table says where a release goes and the records say where it has been, and one
naming a place the other does not know is the two disagreeing about the
release. Dropped quietly, the destination simply would not appear — a
rejection left out of the answer is the failure the record exists to prevent.

**What `ready` does not check, printed on every run.** §3's verb is four
bullets and this is one of them — an artifact for the candidate at every
CI-built destination, anything built outside CI, and the repository's
pre-release gate are reads this package does not have yet. An operator who
reads "production could run" as the whole check is the failure the verb exists
to prevent, so the output says what it did not look at every time. It names
those by category rather than by one consumer's rows, for the same reason the
destination table exists.

**`CandidateCommand`, the shared base for a verb about one build.** `--build`,
`--release`, `--table`, the stray-argument refusal, the hex-build refusal and
the table lookup move there from `status`. The one that matters is the ledger:
it is keyed on the build *and* the version, and a second verb building its own
would have reopened the hole the previous release closed — the grid would still
render, and the header would still name a release nothing had verified.

**`cux_train status`, which is the first verb that runs.** A `CommandRunner`
tree in place of the hand-rolled help-or-refuse entry, and one command on it:
read the destination table, read the promotion refs out of the checkout, build
the grid, write it to stdout. Reads only — every other verb in the plan spends
something, and the one that reports state is the one worth trusting first.

**Both halves of the candidate are required, and the refusals say what would
replace them.** `--build N` and `--release X.Y.Z`. The plan allows deriving the
build from `refs/buildnumbers` for the tip of `stable`, and that is not wired;
the release is not read from the `uploaded/` tag for the build, because that
tag's name is the consumer's convention rather than this package's to parse. A
grid that inferred either would be confidently about the wrong release, which
is the failure §2 spends its length on.

**`PromotionLedger.forBuild` takes the version too, and a record that collides
on the build is refused.** The build alone was the key, and it is not one: a
build number is allocated once from a single monotonic counter, so 2196
belongs to exactly one release. Until now `--release` was a label — a record
for build 2196 of 1.9.13 rendered happily under `--release 1.9.99`, header and
all, exit 0 — so requiring the flag bought nothing, which is the same "wrong
release, confidently" the paragraph above claims it prevents. A collision is
now an error naming both versions. A record at *another* build under another
version is filtered as it always was; only the number that cannot be in two
places is a collision.

**The table is `.cux-train.yaml` unless `--table` says otherwise**, resolved
against the same root the refs are read from — the two coming from different
places would report one repository's progress against another's destinations,
and nothing in the output would say so.

**The namespaces it reads come from `PromotionOutcome`, not from two literals.**
A namespace the reader forgets is not a missing row in a report: the finish
rule counts over these refs, so it would be a destination the rule stops
waiting on and a version tag spent early.

**No global flags yet.** §3 lists `--build`, `--dry-run`, `--yes` and
`--verbose` as carrying over from the donor, and two of those are about
spending something. On a verb that writes nothing they would be flags that do
nothing, which the donor's rule (§3 and §4 both apply it) refuses rather than
drops; they arrive with the verbs that act. An option nobody declared is one
the parser refuses with a 64, `--store` included — `status` does not narrow.

**`status` refuses what it would otherwise have ignored or misread.** A word
after the flags (`status … production`), which `package:args` hands a leaf
command without checking it was read; a `--build 0x10`, which `int.tryParse`
reads as sixteen; a `--table` that names a directory, which `File.existsSync`
reports as missing and the missing-table message would answer with "write it
there"; and a table that exists and cannot be read, whose `FileSystemException`
the entry point has no clause for.

**The grid `status` prints, which is where §6.2's rule is kept or lost.** One
row per destination, one column per audience, and in every cell a build number
with the evidence class behind it. The evidence model decides every mark;
`status_grid.dart` decides only layout — and layout is the whole of "the grid
says so in the cell and never promotes it to *holds*", because a renderer that
prints a read and a record as the same bare number passes every test the
evidence model has. So every mark is spelled out: `2196 observed` beside
`2196 attested`, and never `2196` beside `2196 attested`, where the shorter cell
would read as the stronger claim for being shorter.

**Keyed by version, with the build in the cell.** §3's reason is that AuthPass's
1.9.13 exists as two dozen builds and its destinations hold different ones, so a
grid keyed by build renders one release as two dozen near-empty grids. A cell
holding something else names it — `1940 disagreed` against a candidate of
2196 — and a note under the grid says what disagrees with what. The candidate is
handed in, never guessed: `--build N`, or what `refs/buildnumbers` allocated for
the tip of `stable`, and expressly not the newest `uploaded/` tag, which §2
shows is routinely a pull request's.

**Nothing is collapsed away.** A stage no destination declares still gets its
column, because dropping it would report the absence of a column as the absence
of an audience. A destination nobody acts at still gets its row, because §4's
finish rule is satisfied vacuously by `none` and never asked about a destination
that is not there. Rows stay in declaration order, since a consumer groups its
own destinations by writing them together.

**§6.2's one annotation rides the `internal` cell**, which is the stage it makes
a claim about — on the row's name it would read as a claim about all three. It
needs no case for a cell nobody acts at: the table already refuses
`public-at-internal` on a destination with no internal step, and a test holds
that refusal, so the branch missing here surfaces if it is ever relaxed.

**The record writer, and §9 item 4 answered as neither of the two things it
asked.** The question was whether writing a promotion belongs in `cux_train` or
in a `cux_ship release record` command beside `release finish`. `cux_ship`
already had the writer — `recordUpload`, whose `UploadRecord` has said since it
was written that *"the caller owns the convention, because what a released tag
is called differs per repository and this must never assume a shape"*. So no
verb was added anywhere. `promotion_record.dart` names the tag, a new
`package:cux_ship/provenance.dart` export writes it, and `record_writer.dart`
is the forty lines between them.

What that seam avoids reimplementing: the refusal when a name already points at
a different commit, the refusal when something else left a lightweight tag under
it, the retry that tells a rejected push apart from a collision, and the check
against `origin` rather than against this clone. How It Went already
reimplemented that once, in 125 lines of bash whose header says it "refuses,
like cux_ship" — and `recordUploadIfConfigured`'s doc calls exactly that shape
"one guarantee implemented twice, in two languages".

**One behavioural change was needed, and it is the useful finding.**
`recordUpload` fails the caller when the push fails, because an upload record is
written *before* the store is contacted and an unpushed tag protects nothing. A
promotion record is written *after* a person pressed the button in a console, so
failing there does not un-promote anything — it costs the operator the step they
just finished and sends the next run back to the same console. `cux_ship` gained
`failedPushIsFatal` for that, and this package passes `false`.

**The commit comes from the `uploaded/` tag, never from a search.** That tag is
the one thing in the repository that already knows which commit the artifact was
built from, because `cux_ship` wrote it from the build manifest's `gitSha`. The
tag's *name* is the caller's, since `tag.upload.format` is configurable —
composing it here would send a consumer that changed it looking for a tag nobody
writes. With no such tag there is no commit and the write is refused rather than
guessed at.

**A refusal with no reason is refused.** §6.1 gives the operator `s` as well as
`f`: skipping leaves the cell unrecorded so the next run stops at it again,
while `f` records that it was attempted and refused *with a line of why*. An
unexplained refusal is a permanent, pushed tag saying no more than skipping
already said, about a step only a person can repeat.

**This is the first thing in the package that touches git**, and the property it
cost is worth naming: everything else here parses and answers questions, which
is what lets it be tested with no credential and no network. That is preserved
rather than abandoned — the git this runs is `cux_ship`'s `Git` handle over a
checkout root, so the tests point it at a temporary repository and exercise the
real behaviour, including a push to a bare origin that is not there.

**The evidence model: §6.2's six marks, and what each one rests on.** `status`
has to say *which kind of evidence it has* and never render two kinds the same
way — "submitted to Huawei" and "Play production holds 2196" are different
facts, and a grid that shows them identically is the failure the record exists
to fix. `evidenceFor` answers one cell from the table, the record and a read
that somebody else made.

- **`observed`** — the destination was read and holds the build in the cell.
- **`attested`** — a record says a person or a script did it, and nothing
  independent confirms it. Never promoted to "holds".
- **`disagreed`** — a read and a record name different builds. Snap `stable`
  recorded at 2196 while `api.snapcraft.io` answers 1940.
- **`failed`** — a step ran or was attempted and did not land.
- **`pending`** — no evidence either way.
- **`n/a`** — nobody acts at this stage, which is twenty-four of AuthPass's
  fifty-seven cells. It is decided before anything else, because a grid where
  twenty-four cells say "pending" has buried the four that matter.

**A read that cannot answer is not a failed step**, which is the distinction
the mark set would most easily lose: an endpoint that times out says nothing
about whether the build is there, so the cell falls back to the record and
carries the reason rather than claiming failure. `Observation` is sealed for
this reason — "the store answered 1940", "the CI job failed" and "the endpoint
timed out" lead to three different marks, and a nullable build number could
only have expressed the first.

**A cell names the build it found, not the candidate.** §3 is explicit that a
destination holding something else is named as such and "never normalised away,
because that difference is the thing worth seeing".

**`public-at-internal`** is a new table key carrying §6.2's one annotation,
which rides beside the mark rather than among them: `web`, `packagecloud` and
the snap's `edge` channel reach users the moment the release is pushed. Like
`after-finish` it is refused where nobody acts at the stage it annotates —
both now go through one helper, since both are flags about a stage and both
say nothing on a row with no step there.

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

**The usage text is the command tree's rather than this package's.**
`usageText()` is gone — `CommandRunner` composes the text from the verbs and
their flags, so a verb added without its help appearing is not a thing that can
happen. `usageExit` stays, because a consumer branches on the number and nobody
branches on a paragraph. The refusal for an unknown command is now worded by
`package:args` (`Could not find a command named "x"`), which is the cost of
that; the exit code, the stream and the empty stdout are unchanged, and those
are what `usage_test.dart` says the contract is.

**`usageExit`'s note was wrong about its own future.** It said `cux_ship` owned
this vocabulary and that this package would import the constant once it
depended on `cux_ship` for anything else. It now does depend on it, and there
is nothing to import: `exit_codes.dart`'s own header says 64 "comes from the
argument parser rather than from any of these". Both take it from `sysexits.h`,
and a constant in each is the right amount of coupling to a number fixed by
convention.

**The Dart floor for the whole repository is unchanged, and that is a finding
rather than a default.** The donor package declares `sdk: ^3.13.0`, which
`release-train.md` §7 priced as forcing a Flutter bump on AuthPass — whose
pinned Flutter 3.44.7 bundles Dart 3.12.2. The constraint turned out to be
incidental: declared at `^3.12.2`, a copy of that package analyzes with no
issues, so it uses no 3.13 language feature. This member therefore sits at
`^3.12.2` with its three siblings and the workspace root, and the ordering
stage costs the consumer no SDK move. The design document records what was run.
