# cux_train

Orders the steps of a release, and waits on the ones a person performs.

**Five commands run, and three of them spend something.** `cux_train status`
prints the evidence grid for a release candidate and `cux_train ready` says
what `production` has left to do against it; both write nothing anywhere.
`cux_train internal` sets the build going — one dispatch, the steps this
machine owns, and a wait for the destinations somebody else fills.
`cux_train beta` performs the beta step at every destination that has one and
records each. `cux_train production` does the same at production and then
spends the version tag, once every destination that has a production step is
recorded. That is the whole of the donor's surface.
This package is the workspace
member that How It Went's release train moves into, created ahead of the move
so that each step arrives as a commit against a package CI already builds,
formats, tests and runs a publish dry run over — rather than as one commit that
creates a package and fills it at the same time.

```console
$ cux_train status --build 2196 --release 1.9.13
1.9.13 — build 2196

destination  internal  beta  production
huawei       pending   n/a   2196 failed
flathub      n/a       n/a   n/a

huawei production — attempted and refused

$ cux_train ready --build 2196 --release 1.9.13
1.9.13 — build 2196

production could run.

one thing to take with you:

  huawei turned this build down
    `refused/huawei/production/v1.9.13+2196` records that huawei was offered
    build 2196 of 1.9.13 at production and refused it. `production` is how
    that is retried: the destination is outstanding rather than finished, so
    a re-run stops there again and asks. …

it would act on 1, in table order:
  huawei  manual  https://developer.huawei.com

the version tag waits on 1: huawei.
```

**The difference between the two is a picture and a reading of it.** The grid
shows every cell and leaves the sense of it to somebody who knows the evidence
model; `ready` says what `production` would do next, what the version tag is
waiting for, and what to take to the console — without the reader having to
know what `attested` means.

**It is not a gate, and an earlier draft of it was.** That draft refused when a
destination had turned the build down. §6.1 of the plan records a refusal
precisely so that the next `production` run returns to that destination, which
makes a refusal a reason to run rather than a veto — and since nothing clears
one, the veto never lifted: `train ready && train production` stopped that
build's release for good, the untouched consoles included. The exit code that
could say no went with it. One comes back with the reads, where §3's refusals
actually live.

`ready` is §3's verb with those reads not yet wired: an artifact for the
candidate at every CI-built destination, anything built outside CI, and the
`pre-release` gate are all still unchecked, and the report says so on every run
rather than letting a clean answer read as the whole check.

## `internal`, the verb with two lanes

```console
$ cux_train internal --build 2196 --release 1.9.13 --yes

gate  ./pre-build.sh 1.9.13
pre-build: a changelog section for 1.9.13; HOOK_STORES=[play web direct:macos]

dispatch  ./dispatch.sh 2196
dispatch: pushed HEAD:stable for build 2196

── direct:macos · internal · build 2196 ────────────────────────────────
  run  ./notarize.sh 2196
  recorded promoted/direct/macos/internal/v1.9.13+2196

1.9.13 — build 2196 — internal — the local lane

  direct:macos  handed over

  no internal step: huawei

Every destination this pass covers is recorded at internal.

waiting for play, web — up to 1h
  play  nothing there yet
  web   nothing there yet
  waiting on 2: play, web — 0s elapsed of 1h
  play  holds 2196
  web   holds 2196

1.9.13 — build 2196 — internal — the remote lane

  play  observed
  web   observed

Every destination this run waits on holds build 2196.
```

**Most of a consumer's destinations are filled by somebody else**, and that is
what makes this verb different from the other two that act. §5: AuthPass's CI
builds and uploads fifteen of its nineteen rows, so there is nothing for the
train to *do* at them — it spawns one dispatch, the push CI reacts to, and
then reads each of them until the build turns up. Beside that runs the one step
no CI can take, the notarized macOS build on the laptop. §5 calls the two
lanes "remote" and "local".

```yaml
dispatch: {kind: run, command: "git push origin HEAD:stable"}

gates:
  internal:
    - {kind: run, command: "_tools/pre-build.sh"}

destinations:
  play:
    internal: wait
    read: "_tools/read-play.sh"
  web:
    internal: wait
    public-at-internal: true
    read: "_tools/read-web.sh"
  "direct:macos":
    internal: {kind: run, command: "_tools/notarize.sh {build}"}
```

**`wait` is a kind, not an absence.** A destination CI fills is not `none` —
something is certainly happening there — and not `manual`, since nobody is
being asked to act. Its `read` answers with one build number on stdout, with
nothing for "no build yet", and with a non-zero exit for "could not answer",
which is a reason to keep looking rather than a verdict on the step. A `wait`
with no `read` is refused, and so is a `wait` at any stage but this one.

**`--store` narrows the dispatch too, and only `--store` does.** The dispatch
is the stage's step rather than any one destination's, so a full run spawns it
whether or not a row waits on it — a consumer may dispatch and leave the
evidence to `status`. But `--store direct:macos` asks for the local half, and
pushing `HEAD:stable` as well would be a no-op only while `HEAD` has not
moved: once `main` is ahead of the commit the candidate was cut from, that
push sets going a different commit than `--build` names. A narrowed run that
reaches no waiting row says what it is not dispatching instead.

**Nothing the wait sees is recorded.** A read says the destination holds the
build; a `promoted/` tag would say somebody claims to have put it there, and
writing one for something this process merely saw would turn the stronger
evidence into the weaker on the way past. It also makes a re-run free:
everything that already arrived answers at once.

**The timeout is not optional, because the failure signal is.** Without `gh`
there is no way to observe that a CI job failed, so for a destination whose
build failed the only exit is the clock. `--wait-timeout` takes `90s`, `45m`
or `2h` — a bare number is refused rather than read as minutes — and the
default is an hour, so the normal path never types it. A timed-out row is
`pending`, never `failed`: not hearing back is not being told no, and the
summary says which destinations and for how long.

**The confirmation names what the push makes public.** For AuthPass's `web`,
`packagecloud` and the snap on `edge`, `internal` reaches users rather than
testers — a fact about those workflows rather than something the train causes,
and a verb whose help says "testers have it" must not hide it. The rows marked
`public-at-internal` are named in the prompt, while it is still a question.

## `beta`, the first verb that acts

```console
$ cux_train beta --build 2196 --release 1.9.13 --yes
── play · beta · build 2196 ────────────────────────────────────────────
  run  echo uploading play 1.9.13 build 2196
uploading play 1.9.13 build 2196
  recorded promoted/play/beta/v1.9.13+2196

── huawei · beta · build 2196 ──────────────────────────────────────────
  where    https://developer.huawei.com
  notes    CHANGELOG.md § 1.9.13, rendered for this store

  [d]one   [s]kip for now   [f]ailed   [q]uit — nothing after this is lost
  > f
  why — one line, which is what makes the record usable:
  > 64-bit libs missing from the apk
  recorded refused/huawei/beta/v1.9.13+2196

1.9.13 — build 2196 — beta

  play    handed over
  huawei  refused  — 64-bit libs missing from the apk

  no beta audience: web

1 destination is still outstanding. Run beta again — what is recorded is
skipped, so it picks up where this stopped.
```

**It is resumable because of the record and not because of a flag.** A re-run
names what is already recorded, walks what is not, and stops at the same
destinations — which is why there is no `--resume`: resuming is what a re-run
*is* when the state is a tag.

**A destination that has refused this build says so before it asks.** A
refusal outranks a later hand-over on purpose, and nothing here clears one, so
answering `d` over a refusal records the hand-over and still leaves the
destination unsettled: the report says `handed over, but the refusal stands`
and the run does not claim the stage is finished. The warning is printed above
the keys rather than after the answer, because the moment it can change
anything is while the operator is deciding whether to resubmit.

**A step whose command fails is not recorded, and that is a decision rather
than an omission.** Writing a `refused/` tag for a script that exited non-zero
would be the obvious thing, and it would be permanent: nothing here clears a
refusal, and a refusal beats a later hand-over on purpose, so a five-second
network timeout would mark that destination refused for the life of the build.
A refusal is a judgement about the artifact; a failed command is an incident.
It is reported, the destination stays outstanding, and the next run tries
again.

**`--yes` does not answer a manual step.** It means "do not ask me before
doing what you were going to do", and a console submission is not something
the train does. Off a terminal a manual destination is reported pending and
the run exits non-zero *having done everything else*, so an unattended beta
still ships what it can.

**`--dry-run` prints every instruction and command and records nothing**,
which is the release checklist generated for this build. It exits non-zero
while there is anything left to do, because what it printed it did not
perform — but it exits zero when it finds the stage already recorded, since
the exit code answers *is this build at beta* rather than *did this process
do the work*.

## `production`, the verb that finishes

Everything `beta` does, at the production stage, plus the three things that
are about the version tag.

```console
$ cux_train production --build 2196 --release 1.9.13 --yes
…
1.9.13 — build 2196 — production

  play    handed over
  huawei  handed over

  no production step: web

Every destination this run covers is recorded at production.

finish  release-finish 1.9.13

── fdroid · production · build 2196 ────────────────────────────────────
  run  fdroid-tag 1.9.13
  recorded promoted/fdroid/production/v1.9.13+2196

1.9.13 — build 2196 — production — after the version tag

  fdroid  handed over
```

**Gates run before anything is spent.** §3 opens `production` with the
`pre-release` hook and `release finish --dry-run`, and the placement is the
whole value: a wrong branch, or a changelog with no section for this version,
refuses while it is still free — rather than from the finish step, after
somebody has already stood at eleven consoles. The table declares them:

```yaml
gates:
  production:
    - {kind: run, command: "_tools/pre-release.sh"}
    - {kind: run, command: "_tools/ship.sh release finish --dry-run"}
```

**Keyed by the stage that runs them**, and it was one flat list until there
were two verbs with gates. `internal` opens with the `pre-build` hook and
`production` with `pre-release`; one list would have run `release finish
--dry-run` in front of the dispatch that creates the build it is checking.
Within a stage it stays a list, because the order there is the consumer's: the
two above go in whichever order refuses soonest.

Any of the three verbs that spend something — `internal`, `beta`,
`production` — runs the gates under its own key and no others. `beta` has none
in §3, but the key is accepted and honoured, because a gate that parses and
never runs is worse than one that was never written: it is believed.

They run in order, each must exit 0, and the first failure stops the run with
nothing spent. The bodies are the consumer's; the contract is not.
`HOOK_STORES` carries the destinations this run will act on, so a gate that
cares whether the run was narrowed can read it — and `{destination}` is
deliberately **not** offered, because a gate is about the release rather than
about one row.

**A dry run runs them too.** They spend nothing by contract, and a dry run
that skipped them could not answer whether the release is ready, which is most
of what a dry run is for. `release finish --dry-run` is itself a gate of
exactly that shape.

**The finish rule asks the record, never the invocation.** `vX.Y.Z` is spent
once every declared destination with a production step is *recorded* at
production. A destination whose production kind is `none` is satisfied
vacuously — nobody acts, so nothing writes a record, and waiting for one would
hold the tag forever. The rule is deliberately not keyed on `--store`: a
`production` that spans days ends with somebody typing `--store ppa
production`, and a rule about narrowing could never let that run finish the
release.

**A destination declared `after-finish` runs after the tag, not with the
rest.** AuthPass's `fdroid` pushes `fdroid-vX.Y.Z`, which annotates the
version tag and so cannot precede it. Those destinations are excluded from the
rule and walked in a second pass, which the report labels — and they are not
touched at all while the tag is held, because pushing them early would
annotate a release that may never be finished.

**The tag is written by a command the consumer declares**, as a top-level
`finish:` step in the table:

```yaml
finish:
  kind: run
  command: "cux_ship release finish --version {version} --build-number {build}"
```

**Two things that command has to get right, because nothing here checks
either.** It has to name the commit: `production` spans days, so `HEAD` when
the last destination is recorded is rarely the commit the build was made
from, and `release finish` given only `--version` tags `HEAD`. With
`--build-number` and `tag.upload.enabled` in `.cux-ship.yaml` it resolves the
commit through the `uploaded/` record instead. And it has to be safe to
repeat: nothing records that the finish ran, so every `production` for this
build after the rule is met spawns it again — including the re-run that picks
up an `after-finish` destination which failed. `release finish` resolved that
way is: it finds the tag already at that commit and the branch already
bumped.

Composing `v$version` here would be inventing somebody else's convention — the
same mistake as reading a release out of an `uploaded/` tag — and being
silently wrong wherever they spell it differently. A table with no `finish`
says so rather than treating a fully recorded release as finished, and a
`finish` that is `manual` or `none` is refused when the table is read.

**The finish is recorded, like every other step.** It writes
`finished/vX.Y.Z+N`, and a later run that finds it says so and does not spawn
the command again. Without that the one irreversible step was the only one
with no record, so a re-run of a finished release spent the tag a second time.

**`--dry-run` reaches the end of the release.** It records nothing, so the
finish rule would always say the tag is held — which left the checklist
without "create tag" and without the after-finish destinations, the part §8
step 1 wants it for. A dry run therefore subtracts what it has just said it
would do and goes on; a destination it would *not* reach still holds the tag.

**What the train does not check is the order between destinations.** §3 step 5
orders the script group — the artifact-server index first, then GitHub and
FossHub, which read it — and that is the table's declaration order, which a
run follows. What declaration order does not express is *dependency*: a step
that fails does not stop the ones after it, so an index step that exits 1
still lets GitHub and FossHub run against the stale index and be recorded as
handed over. Narrowing with `--store github` does the same. Until a row can
say what it depends on, that ordering is a convention the table author keeps,
not one the train enforces.

The destination table it reads is `.cux-train.yaml` in the directory it is run
from — the repository root, where the launcher sits — or wherever `--table`
names. A sibling file rather than a `train:` block in
`.cux-ship.yaml`, which is the arrangement worth having and is not available:
an unknown key there is an error by design, and that file is read before every
`cux_ship` command, so the block would fail every upload until a release that
knows the word — a release with no date yet.

What exists today is the **destination table** and the **promotion record**. A
consumer declares where a release has to go and who acts at each stage, and
`--store` resolves against that declaration rather than against a list compiled
into the tool. The record says what the release has already reached, read from
git refs a caller hands over; from it come the two questions a resumable run
asks — what is still outstanding, and whether the version tag may be spent.
Over both sits the **evidence model**, which decides what `status` is allowed
to claim about a cell: read, recorded, contradicted, failed, unknown, or
nobody's job. Over that sits the **status grid**, which is the shape all of it
is read in: one row per destination, one column per audience, and in every cell
a build number with the evidence behind it, never a build number alone. Beside
the grid is the **readiness answer**, which reads the same two things and
reduces them to a yes or a no: what `production` would act on, what the version
tag is waiting for, and what has to change first. Beside them all is the
**record writer**, which is the only part that leaves a mark on anything.

Nearly all of it parses and answers questions — no store, no credential —
which is what lets every case be tested without either. Two parts are the
exception and both are narrow. The **record writer** names a tag and hands it
to `cux_ship`'s `recordUpload` over a checkout root a caller supplies, so its
tests point at a temporary repository and get the real behaviour. The
**promotion run** spawns a destination's declared command and asks the
operator about a manual one, and takes both as arguments — a test hands it a
recorder and a scripted console, so every decision about what to write is
asserted without a child process or a terminal. `status` reads that same
checkout for the refs it renders, and takes the root the same way.

**A declared command is split into arguments here and never handed to a
shell.** `sh -c` would buy pipes for free and make every interpolated value
shell source — a version named `1.9.13; rm -rf ~` would be two commands. The
split happens before interpolation, too, so a value containing a space lands
in exactly one argument instead of becoming two.

**And a template that reads as shell is refused rather than run as not-shell.**
`make build && ./upload.sh` has no meaning here, and the dangerous half is
that it has no *error* either: it would run `make` with `build`, `&&` and
`./upload.sh` as three arguments, and a program that ignores what it does not
recognise would then be recorded as having done the upload. Unquoted `&&`,
`||`, `|`, `;`, `>`, `<`, `$`, a backtick, a `*` glob and a leading `~` all
refuse with the same advice: put it in a script and name the script, or quote
the character if you meant it literally.

A backslash keeps its character unless there is a reason to escape it, which
is a deliberate difference from a shell: `C:\tools\ship.exe` stays that path
instead of becoming `C:toolsship.exe`, while `one\ two` is still one argument.

**The candidate is named, never guessed**, which is why both `--build` and
`--release` are required rather than defaulted. A build number does not say
which release it belongs to — one version is two dozen builds — and the newest
`uploaded/` tag is routinely a pull request's, so a grid that inferred either
would be confidently about the wrong thing. The plan allows reading the build
from `refs/buildnumbers` for the tip of `stable`; that is not wired yet, and
the refusal says so rather than letting the omission read as the design.

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

Five verbs, two of them read-only, and it is launchable the way its siblings
are — without a consumer having to find the package in the pub cache:

```bash
dart --packages=<checkout>/.dart_tool/package_config.json \
     package:cux_train/cli.dart ready --build 2196 --release 1.9.13
```

`bin/cux_train.dart` is a one-line export of that library, so `dart run
cux_train` and `dart pub global activate` work as usual.
