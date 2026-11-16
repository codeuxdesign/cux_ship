# cux_train

Orders the steps of a release, and waits on the ones a person performs.

**One command runs, and it is the one that performs nothing.** `cux_train
status` prints the evidence grid for a release candidate and writes nothing
anywhere; the verbs that spend something — `ready`, `internal`, `beta`,
`production` — are still a plan, and the usage lists only what exists. This
package is the workspace member that How It Went's release train moves into,
created ahead of the move so that each step arrives as a commit against a
package CI already builds, formats, tests and runs a publish dry run over —
rather than as one commit that creates a package and fills it at the same time.

```console
$ cux_train status --build 2196 --release 1.9.13
1.9.13 — build 2196

destination  internal  beta  production
huawei       pending   n/a   2196 attested
flathub      n/a       n/a   n/a
```

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
them is the **record writer**, which is the only part that leaves a mark on
anything.

Nearly all of it parses and answers questions — no spawning, no store, no
credential — which is what lets every case be tested without either. The writer
is the exception and a narrow one: it names a tag and hands it to `cux_ship`'s
`recordUpload`, over a checkout root a caller supplies, so its tests point at a
temporary repository and get the real behaviour. `status` reads that same
checkout for the refs it renders, and takes the root the same way.

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

There is nothing to use yet. When there is, it will be launchable the way its
siblings are, without a consumer having to find the package in the pub cache:

```bash
dart --packages=<checkout>/.dart_tool/package_config.json \
     package:cux_train/cli.dart help
```

`bin/cux_train.dart` is a one-line export of that library, so `dart run
cux_train` and `dart pub global activate` work as usual.
