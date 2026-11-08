# The release train is a sibling member, not a library in `cux_ship`

Status: **proposed**, 8 November 2026. Not built. Everything in §3 and §4 marked
*verified* was run against this repository and against How It Went's
`tool/train/` on that date, with Dart 3.13.7; everything else is argument.

How It Went's release train — `tool/train.sh` plus `tool/train/`, a
`publish_to: none` Dart package of 7,509 lines of `lib/` and 10,718 lines of
tests across 19 files — orders the six audited release steps, wraps each in the
credentials it consumes, and spawns `cux_ship` for every store write. AuthPass
is now the second repository shipping an Apple platform and Play through this
tooling and has no equivalent. This proposes the train move here, as a fourth
workspace member beside `cux_ship_verify` and `cux_buildnumber`.

**This is not the proposal [read-api.md](read-api.md) declined**, and §2 is the
whole of why. That difference is narrow enough to be worth stating before
anything else, because the obvious reading of this document is that it reopens
a decision taken four weeks ago.

## 1. The question

> **Where does orchestration live when two repositories need the same of it?**

Not *should it be shared* — that is [SHIPPING.md](https://github.com/codeuxdesign/cycling_storyteller)
§2's rule and it answers itself: anything that would have to be fixed twice
belongs here. The question is *in which package*, and there are three answers,
only one of which has not already been tried and rejected.

## 2. Why not in `cux_ship`, and the distinction is narrow

[read-api.md](read-api.md) removed `lib/read.dart` and with it the in-process
`AppStoreReads` and `PlayReads` sessions, built for this very consumer at the
moment of its port to Dart. Its "Reads only" section states the rule that
governs any proposal to put a release step in this package:

> Nothing exported uploads, promotes, publishes a listing or moves a build
> between tracks — and the consumer that asked for this keeps its writes as
> spawned commands on purpose.

Two reasons, neither about how pleasant an API would be: **the printed command
line is what makes a failed release step re-runnable by hand**, and **per-step
`secrets exec --only …` is what keeps a credential out of a step that has no use
for it.** An in-process write runs under whatever the host process holds, which
is everything.

A train inside `cux_ship` is the maximal version of exactly that: one process
holding every credential for the length of a release.

**A sibling package gives up neither.** `cux_train` would depend on `cux_ship`
for `documents.dart` and `exit_codes.dart` — value types over what a command
printed — and reach every store by spawning the consumer's own `tool/ship` shim
under the `secrets exec --only` or `keychain exec --only` that step needs. The
credential narrowing is per step, as now; the command line is printed, as now.
Nothing in `read-api.md` argues against a separate package that spawns, and the
train is the living proof of that: it ported *off* `read.dart* onto `--json` and
the documents, output byte-identical, which is what left the library with no
caller.

So the third answer — a sibling — is the first one that does not trade away
something a previous decision was taken to protect.

## 3. What moves, and it is already liftable

**Verified: `tool/train/lib/` imports nothing outside this repository and two
pub packages.** The complete import closure:

```
dart:async  dart:convert  dart:io  dart:math
package:cux_ship/documents.dart
package:cux_ship/exit_codes.dart
package:io/ansi.dart
(and its own files)
```

`test/` adds `package:cux_ship_verify/cux_ship_verify.dart` and
`package:test/test.dart`. There is no import of the enclosing application
anywhere — the package was written self-contained, and `bin/train.dart` is where
the app's own constants enter, as environment reads with defaults.

**One external re-export travels with it**, and a new member would be
publishing it: `style.dart` has
`export 'package:io/ansi.dart' show AnsiCode, overrideAnsiOutput;`. That is
deliberate there — [`overrideAnsiOutput`](https://pub.dev/documentation/io/latest/ansi/overrideAnsiOutput.html)
puts the paint-or-not decision in a `Zone` so a test can assert the painted form
with no terminal to run on — and it is a surface this repository would owe
stability on.

## 4. What the monorepo asks, and the step I expected to break does not

**Verified: adding a member is one line.** Both `tool/check.sh` and
`.github/workflows/ci.yaml` derive their member list by `awk`-ing the root
pubspec's `workspace:` key, and both say in as many words why: `cux_buildnumber`
landed with format, analyze and 30 tests, and CI reported success without
running any of them. So a name added to `workspace:` is covered from the moment
it is added — format, analyze, test, the generated-code check, `publish
--dry-run` and `--docs-only`.

**Verified: `dart pub publish --dry-run` ignores `publish_to: none`.** This was
the one step expected to break, since `check.sh` runs it unconditionally per
member and has no skip. It does not break. A `publish_to: none` package with
complete metadata reports `Package has 0 warnings.` and exits 0; the same
package without a LICENSE or a `description` fails with exit 65 naming both.

```
publish_to: 'none', + LICENSE/description/repository/README/CHANGELOG
  → Package has 0 warnings.   exit 0
```

So **no change to `tool/check.sh` or `ci.yaml` is needed**, and the price of
that is the five files pub validates for. Worth recording as a fact about pub
rather than about this repository: `--dry-run` validates as though publishing
regardless of where the package says it publishes to.

**What it does cost, each of these read rather than measured here:**

- **About ninety-five seconds per push on the new member's `--docs-only`
  step.** `cux_train` depends on `cux_ship`, so it inherits googleapis, and
  `check.sh`'s header measures `dart doc` at roughly that on `cux_ship` for
  exactly that reason — 1.35 million precached elements — against ninety
  seconds for the whole five-step suite over three members. This member cannot
  be the light one; a release orchestrator has no reason to want to be.
- **A three-level internal chain**, `cux_ship_verify ← cux_ship ← cux_train`,
  where README.md's rule today is one edge and one direction. A `cux_ship`
  release then needs a `cux_train` bump before a consumer sees it through the
  train.
- **Full release discipline on a fourth member**: `## Unreleased` on feature
  branches only, a dedicated release commit, and a `cux_train-v…` tag prefix per
  [RELEASING.md](../RELEASING.md) — the bare `vX.Y.Z` series is `cux_ship`'s own.
- **[CONTRIBUTING.md](../CONTRIBUTING.md)'s *watch the test fail* over 10,718
  lines of tests that arrive already green.** They were written under another
  repository's rules and have never been observed failing with their guards
  removed. That is not a reason to refuse them and it is a reason not to call
  them covered: the honest position is that the suite is inherited, and the
  discipline starts at the first change made to it here.
- **The history should move `git log --follow`-able**, the way this repository's
  own code was extracted from Hold the Wheel with its history intact — a subtree
  or filter import rather than a copy. README.md says why that matters here:
  most comments in this code record a specific incident, and `git blame` is
  usually the only way to recover why a line exists. The train's comments are
  the same kind, and a copy throws every one of them away as evidence.
- **Relicensing to Apache-2.0**, with the NOTICE. Same author, so this is a
  line of paperwork rather than a question.

## 5. The app-specific surface, enumerated

The train is already parameterized on everything an app would obviously want to
supply: `Train` takes `options`, `runner`, `repo`, `toolDir`, `buildTokens`,
`betaGroup`, `appleBundleId`, `playPackageName`, two widget factories and a
`HookSet`. What is *not* parameterized, and is the whole of the work:

**Seven spawned paths, all relative to `toolDir`:**

```
ship   build.sh   upload.sh   promote.sh   finish.sh
corpus.sh   ci/release-inputs-check.sh      (+ train-hooks.d/)
```

**Three credential selectors**: `apple.api_keys.upload` and
`android.play_service_account` as `secrets exec --only` arguments, and
`${platform.name}_appstore` as the `keychain exec --profile`.

**One log directory**, `dist/`, via `_logPathFor`.

**The step argument conventions** each spawned script is assumed to
understand — `build.sh --release <platform>`, `upload.sh [--dry-run]
[--skip-waiting] --json <platform>`.

That is on the order of twenty-five values. It is a configuration object, not a
rewrite, and the smallness is worth stating plainly because the instinct on
reading "7,500 lines of another app's release tooling" is that the coupling must
be everywhere. It is not: it is concentrated in `train.dart` and `options.dart`,
and `bin/train.dart` already holds the rest.

### 5.1 Two of the seven are not steps

`corpus.sh` and `ci/release-inputs-check.sh` are How It Went's own preflights,
written into the core as though they were release steps. They want the seam that
already exists for this: `hooks.dart`'s header states the extraction line
outright —

> the train core is generic and app-specific behavior leaves it through
> `tool/train-hooks.d/`

— and the mechanism is built, with `post-upload` and `post-promote` collected
and fired after a stage. A `pre-build` and a `pre-release` hook absorb both, and
the core then spawns five things rather than seven. **The architecture already
anticipated this move**, one event short.

### 5.2 `enum Platform { ios, macos, android }` is the one type-level change

It lives in `options.dart`, every other file imports it, and `storeTable` is
four rows built on it. Both are deliberately narrow — `options.dart` says the
table is *deliberately not generalized further than this map*, on the grounds
that what is being bought is the word and not machinery.

AuthPass is what makes that cost real: six Android flavors (`playstore`,
`playstoredev`, `fdroid`, `sideload`, `amazon`, `huawei`, `samsungapps`), three
Windows variants, Linux and web. So the enum has to open and the table has to
generalize — and that is the one place where a second consumer forces a design
decision rather than a configuration value.

**The table's own comment names the shape the answer should take**: a row can
express a store that takes a differently-signed artifact, and a store that is
not an upload at all (F-Droid watches for a tag). Generalizing toward *that*
rather than toward "a platform string" is the difference between a table with
more rows and a table that can say what a destination is.

## 6. Two stages, and the split is where the parameterizing already stopped

**Stage 1 — 4,359 lines that need no contract design.** `pinned_block`, `style`,
`panel`, `status_block`, `runner`, `upload_progress`, `status`, `summary`. No
spawned paths, no credential selectors; `status.dart` is already behind a
`StoreReads` interface whose live implementation takes `runner`, `ship` and
`packageName` as arguments. This is also the half both repositories want first:
`status` answers *which build does each store actually hold, and can it be
released*, which is the question AuthPass's existing guards already ask one
store at a time.

**Stage 2 — 3,150 lines that are a release model.** `train.dart`, `options.dart`,
`repo.dart`, `hooks.dart`, behind the configuration object, with §5.1's two
preflights moved onto hooks. Do this when there is a second consumer whose shape
is known — which, per §7, means after AuthPass has decided something it has not
decided.

**The order is not "easy first".** Stage 1 is the part where the previous author
already finished the interface work, and Stage 2 is the part where
`SHIPPING.md` §2's warning applies: *generalizing it from one-and-a-half
examples would fix the abstraction before this project's own shape is proven.*
That warning is stronger here than it looks, because AuthPass's half is not a
smaller example of the same shape — it is a different shape, which is §7.

## 7. What this does not fix

Status: **open**, and it is open on a consumer rather than on this repository.

Moving the code changes where it lives, not whether a release is one event. The
train's three release words assume it is: one build, every store, then
`finish.sh` once — and `finish.sh`'s header is emphatic that running it after
the first store spends the version name on a release that is half out, which is
how `v1.1.1` through `v1.1.4` came to say "released to beta".

[release-check.md](release-check.md) §3 already recorded why AuthPass is not
that shape, and it is the same premise:

> AuthPass's release is per-destination, while its git record is deliberately
> one `uploaded/` tag per commit, so git *cannot express* which destinations
> hold what.

Concretely, as of 8 November 2026: AuthPass has no `promote.sh` and no
`finish.sh`, calls neither `play promote` nor `appstore promote` nor `release
finish`, uploads from GitHub Actions on a push to `stable` or `beta` rather than
from an operator's terminal, and declares no listing requirements in
`.cux-ship.yaml` — so the train's `store-verify` preflight and its `--prepare`
stop point have nothing to check. How It Went builds releases on a laptop;
AuthPass does not build them locally at all.

**So Stage 1 has a consumer today and Stage 2 does not.** That is the useful
form of this section: it is not an objection to the move, it is the reason the
move is staged, and the condition for Stage 2 is a decision in AuthPass about
whether its release should become a single event — which §3 of release-check.md
says is reopened by a per-store upload record, a capability
[upload-record-scope.md](upload-record-scope.md) files from the other end.

## 8. Open questions

Status: **open**.

- **Published, or `publish_to: none`?** §4 shows an unpublished member costs
  nothing in CI. Against that: AuthPass would then consume it as a git
  dependency, and its `_tools/cux_ship/pubspec.yaml` records that cux_ship *was*
  a git ref and that moving to a hosted constraint was an improvement worth
  keeping. The `consume` job proves the git path resolves; it does not make it
  the better one.
- **The name.** `cux_train` here, on the grounds that `cux_buildnumber` already
  broke the `cux_ship_` prefix and README.md's table is organized around which
  package you want rather than around names. `cux_ship_train` is the other
  reading.
- **Does the pinned terminal block belong in this repository at all?**
  `pinned_block.dart` and `style.dart` are 592 lines with no store knowledge of
  any kind, and the rules they encode — measure the plain text, paint the plain
  text, pad with plain spaces; never the alternate screen buffer, because
  scrollback *is* the record of a release — are about terminals. Inside
  `cux_train` they arrive with googleapis attached. A package of their own is
  the alternative, and nothing here needs that answered before Stage 1.
- **Where does the step contract get written down?** §5's argument conventions
  are today a shape two shell scripts happen to have. A member published from
  here owes a consumer a statement of what `build.sh` and `upload.sh` must
  accept, and the options are a dartdoc on the configuration object, a document
  in `docs/design/`, or a verifier in `cux_ship_verify` that reads the scripts
  and says whether they qualify.
