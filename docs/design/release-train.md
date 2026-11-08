# The release train is a sibling member, not a library in `cux_ship`

Status: **proposed**, second pass, with one adversarial and one consumer review
folded in, 8 November 2026. Not built. Everything marked *verified* was run on
this machine with Dart 3.13.7 and git 2.54.0; everything else is argument or is
marked as read rather than measured.

How It Went's release train — `tool/train.sh` plus `tool/train/`, a
`publish_to: none` Dart package of 7,509 lines of `lib/` and 10,718 lines of
tests across 18 `*_test.dart` files and a 520-line `fakes.dart` — orders the six
audited release steps, wraps each in the credentials it consumes, and spawns
`cux_ship` for every store write. AuthPass is the second repository shipping an
Apple platform and Play through this tooling. This proposes the train move here,
as a fourth workspace member beside `cux_ship_verify` and `cux_buildnumber`.

**The first pass of this document got three things wrong, and they are recorded
rather than quietly corrected**, because two of them were the document's own
load-bearing sentences:

- It claimed *nothing in `read-api.md` argues against a separate package*. That
  file has a section titled "Not split into its own package" and two of its
  three arguments transfer here. §2 now answers it.
- It claimed the sibling arrangement keeps credential narrowing *per step, as
  now*. Narrowing is per step on the Apple side and **absent on four of eleven
  `secrets exec` sites**, and in CI the train already holds `SOPS_AGE_KEY`
  in-process. §2.1 is that, and it is `open`.
- It staged the move into 4,359 lines needing "no contract design" and 3,150
  that are a release model. The boundary is one symbol short of real, and that
  symbol is the one §5.2 says a second consumer forces open. §6 withdraws the
  claim.

The conclusion — move it, as a sibling, in stages — survives all three. What
does not survive is the order of the stages, which §6 and §7 now reverse.

## 1. The question

> **Where does orchestration live when two repositories need the same of it?**

Not *should it be shared*: How It Went's `SHIPPING.md` §2 answers that — anything
that would have to be fixed twice belongs here. The question is *in which
package*, and there are three candidate answers. Two have already been tried in
this repository and reversed.

## 2. Why not in `cux_ship`

Two documents here bear on it and they point different ways.

[read-api.md](read-api.md)'s "Reads only" section states the rule that governs
any proposal to put a release *step* in this package: nothing exported uploads,
promotes, publishes a listing or moves a build between tracks, because an
in-process write runs under whatever the host process holds. That is an argument
about **behaviour**, and the first pass of this document treated it as an
argument about **location** — which it is not. A `lib/train.dart` inside
`cux_ship` that reached the stores by spawning the consumer's `tool/ship` would
hold exactly what a sibling holds. The train already takes the shim as a path
(`LiveStoreReads({required this.ship, …})`, `Train._ship`), so the two are
mechanically the same program. **Location is not the thing that preserves the
property; spawning is, and spawning is available either side of the boundary.**

And [read-api.md](read-api.md)'s "Not split into its own package" section argues
*against* a new member, quoting `e5e4647` — *"Split by what a lockfile gets, not
by how the extraction happened"*. Two of its three arguments transfer intact:

- **The lockfile test fails.** A consumer of `cux_train` resolves `cux_ship` and
  therefore googleapis, so the new package gives its lockfile nothing `cux_ship`
  does not. This is the same answer `cux_ship_play` got.
- **It would not narrow the semver promise.** The promise is the exported
  surface, and a `train.dart` with `show` clauses inside `cux_ship` is exactly as
  narrow as a fourth member's `lib/` — enforced by a test rather than by a
  directory, which `read_api_test.dart` already demonstrates is sufficient.

**The third argument inverts, and that inversion is the real case for a
sibling.** `read-api.md`'s was that a split cannot ship as a branch: `cux_ship`
would name the new packages as hosted constraints that do not exist on pub.dev,
which is the "unconsumable as a git dependency" state CI's `consume` job goes red
on. Here the edge runs the other way — `cux_train` depends on `cux_ship`, never
the reverse — so `cux_ship` names nothing new, stays consumable as a git ref
throughout, and the new member can be pinned before it is published. The
dependency direction is what makes this splittable where `cux_ship_play` was not.

**So the honest case rests on cadence and direction rather than on lockfiles or
surface:**

- **Cadence.** `RELEASING.md` gives the version number to a dedicated release
  commit, one series per package. An orchestrator changes when a consumer's
  release process changes; store clients change when Apple or Google do. Folding
  the first into the second's series means every train edit spends a `cux_ship`
  version, and every `cux_ship` consumer sees churn from a package they do not
  resolve.
- **Direction, enforced by a directory.** README.md's rule today is one edge and
  one direction: `cux_ship` depends on `cux_ship_verify`, never the reverse.
  Inside `cux_ship`'s `lib/`, nothing stops a store client reaching into
  orchestration; a member boundary does, in the way `read-api.md` says a `show`
  clause and a test are equivalent to — except that here the thing being kept out
  is a dependency edge rather than a name.

A reviewer who reads `read-api.md` will reach the "Not split" section, so this
section exists to meet it rather than to be surprised by it.

### 2.1 The credential property the first pass claimed is not the state of the world

Status: **open**, and open on a `cux_ship` defect rather than on this proposal.

The first pass said the sibling arrangement keeps per-step narrowing *as now*.
Counted over `tool/train/lib/src/train.dart` — `'secrets', 'exec',` and the next
flag — **seven of eleven sites pass `--only` and four pass a bare `--`**: the
Android build (`:606`), the Android upload (`:684`) and both Play promotions
(`:1566`, `:2111`). Those four hand their child every credential in the
consumer's `release.yaml`. Narrowing is a property of the Apple lanes here, not
of the train.

**And the train already holds the master key in-process in CI.** How It Went's
`SHIPPING.md` §12.4 says so outright — in CI the identity travels as
`SOPS_AGE_KEY` and the train holds it before `tool/ship` runs, so an Android
build under `secrets exec` inherits it and only the Apple builds are covered,
because those go through `keychain exec`. That repository's `OPEN-QUESTIONS.md`
scopes the exposure as latent *there* and then says the decisive thing: the
defect is a fact about `cux_ship`, and it is live for any consumer that has
already wired CI up.

**Verified: AuthPass has wired CI up.** `SOPS_AGE_KEY` is set as a job or step
environment in ten of its workflows — `ios.yaml` (7 occurrences), `linux.yml`
(4), `main.yml`, `integration_test.yml` and `driver_test.yml` (3 each),
`windows.yaml` (3), and one each in `analyze.yaml`, `unit_test.yaml`,
`web-gh-pages.yaml` and `make_deb.yaml`.

So for the consumer this proposal exists to serve, `read-api.md`'s objection —
*an in-process write runs under whatever the host process holds, which is
everything* — already describes the world, and moving code into a sibling package
does not touch it. **This is not an argument against the move.** It is an
argument that the move must not be sold on a credential property it does not
deliver, and that `secrets exec` stripping `SOPS_AGE_KEY` is a separate piece of
work in `cux_ship` that the train's arrival makes more urgent rather than less.

## 3. What moves, and what cannot

**Verified: `tool/train/lib/` imports nothing outside two pub packages and this
repository.** The complete closure:

```
dart:async  dart:convert  dart:io  dart:math
package:cux_ship/documents.dart
package:cux_ship/exit_codes.dart
package:io/ansi.dart
(and its own files)
```

One external re-export travels with it and a new member would be publishing it:
`style.dart:45` is `export 'package:io/ansi.dart' show AnsiCode,
overrideAnsiOutput;`. That is deliberate there — `overrideAnsiOutput` puts the
paint-or-not decision in a `Zone` so a test can assert the painted form with no
terminal — and it is a surface this repository would owe stability on.

**The first pass concluded from that closure that "the package was written
self-contained". That is true of its `import` statements and false of the
package.** `test/fakes.dart:20` resolves the package's own URI and then walks up
two directories to reach the enclosing application:

```dart
final lib = await Isolate.resolvePackageUri(
  Uri.parse('package:cycling_storyteller_train/train.dart'),
);
return File.fromUri(lib.resolve('../../$name')).path;
```

In a `cux_ship` workspace `lib/../../` is the workspace root, where the scripts
it reaches for do not exist.

**Verified by relocation: 62 of 416 tests fail on the move alone**, because six
files do not test this package at all. Copied to a scratch directory,
`dart pub get`, `dart test` → 354 passing, 62 failing.

| file | lines | what it tests |
|---|---|---|
| `dart_sdk_test.dart` | 175 | `tool/_dart_sdk.sh` |
| `resolution_test.dart` | 318 | `tool/_resolution.sh` |
| `ship_snapshot_test.dart` | 314 | `tool/_ship_snapshot.sh` |
| `record_test.dart` | 338 | `tool/record-promotion.sh`, the `train-hooks.d` wrappers |
| `promotions_test.dart` | 215 | `tool/render-promotions.py` |
| `release_inputs_test.dart` | 262 | How It Went's own tree (`../../store/`, `../../CHANGELOG.md`) |

**1,622 of the 10,718 lines — 15% — cover five shell scripts and one Python
script that stay behind.** Where their coverage lives afterwards is an open
question (§8); the two honest answers are "deleted" and "left in a package that
no longer exists", and neither is free. The `cux_ship_verify` dev dependency the
train declares exists for two of those six files, so after the move the member
declares a dev dependency with no remaining user.

**The sharpest single failure is in the set §6 used to call Stage 1.**
`status_test.dart`'s *"every flag these reads pass is one the real CLI accepts"*
spawns `tool/ship play tracks --help` against the real shim. The comment it
answers (`status.dart:1363`) says why it exists: a `--package-name`/`--package`
mix-up shipped because *"A `FakeRunner` records argv and judges none of it, so
every test passed."* It is the only guard on the CLI contract and it is
location-coupled.

## 4. What the monorepo asks

**Verified: adding a member to the matrix is one line.** Both `tool/check.sh` and
`.github/workflows/ci.yaml` derive their member list by `awk`-ing the root
pubspec's `workspace:` key, and both carry the reason: `cux_buildnumber` landed
with format, analyze and 30 tests and CI reported success without running any of
them.

**Verified: `dart pub publish --dry-run` ignores `publish_to: none`.** This was
the step expected to break, since `check.sh` runs it unconditionally per member
with no skip. A `publish_to: none` package with complete metadata reports
`Package has 0 warnings.` and exits 0; the archive listing even says it is
publishing to pub.dev. Without a LICENSE or a `description` it exits 65 naming
both. So the member checks need no edit — and that is a fact about pub rather
than about this repository.

**But the first pass priced that at "the five files pub validates for", and the
gate is tighter than that: a warning alone exits 65.** Three further warnings
bite a member built out of this package, each verified:

1. **The entry library must be named after the package.** `lib/train.dart` in a
   package called anything else:
   `* The name of "lib/train.dart", "train", should match the name of the
   package, "zz_train_probe".` → `Package has 1 warning.` → **exit 65**. So the
   barrel must become `lib/cux_train.dart`, which changes the import for every
   consumer and `bin/train.dart`'s own `import 'package:…/train.dart' hide
   Platform;`. `cux_ship` escapes this only because it has four top-level
   libraries and the check fires on a single one. **This is why §8's naming
   question is not presentational.**
2. **`CHANGELOG.md` must mention the current version** — on every push, not only
   at release.
3. **A member naming a prerelease of `cux_ship` must itself be a prerelease.**
   `cux_ship` is on `4.5.0-dev.8` and `cux_ship_verify` on `1.11.0-dev.4`, and
   the train pins `cux_ship: 4.5.0-dev.8` exactly. So the new member's version is
   coupled to whether `cux_ship` is mid-prerelease, which — judging by the branch
   list — is most of the time.

**Verified: the workspace SDK floor moves silently.** A synthetic workspace with
root `^3.12.2` and members `^3.12.2` and `^3.13.0` resolves with no message, and
the lockfile reads `sdks: dart: ">=3.13.0 <4.0.0"`. The train declares
`^3.13.0`; every `cux_ship` member and the root declare `^3.12.2`. So adding it
raises the whole repository's floor to 3.13.0 while `cux_ship/pubspec.yaml` goes
on promising `^3.12.2` to consumers, and the dependency set CI tests is then
chosen under a floor a 3.12.x consumer never sees. `check.sh`'s SDK warning does
not cover this: it compares the local `dart` against the CI pin, not member
constraints against each other. Either the train's floor drops to `^3.12.2`
(untested) or both published members raise theirs (a minor on each, and
consumer-visible).

**`ci.yaml` does need one edit after all, and §8 depends on it.** The `consume`
job is not derived from anything: it names `cux_ship` in the probe pubspec, in
the `path:`, in the `grep -q cux_ship_verify pubspec.lock` assertion and in some
twenty hardcoded `--help` probes. A fourth member gets no consume coverage — and
that is the one job `RELEASING.md` says catches a failure invisible locally,
*"breaks only for someone cloning fresh"*. Its probe pubspec also declares
`sdk: ^3.12.2`, which the train's `^3.13.0` would not satisfy.

**Corrected by measurement: `dart doc` costs 34 s, not the ~95 s the first pass
estimated.** Run on the relocated copy: exit 0, 34 s, no unresolved references
and none of the "ambiguous reexport" noise `check.sh`'s comment reports for
`cux_ship`. The mechanism was right — googleapis is in the train's resolution —
and the magnitude was out by 3×. Worth recording as a lesson about this document
rather than about the train: it was the one cost on the list a single command
settles, and it was the one stated most confidently. The same run found the train
clean under this repository's `analysis_options.yaml`: `dart analyze
--fatal-infos` → no issues, `dart format --set-exit-if-changed` → 0 of 33 files
changed.

**The remaining costs, read rather than measured:**

- **A diamond, not a chain.** The first pass called it `cux_ship_verify ←
  cux_ship ← cux_train`; the train also declares `cux_buildnumber: ^0.1.0`, which
  is pre-1.0, so any minor bump there is breaking for the new member. And
  `RELEASING.md`'s "publish the dependency first, then wait" makes a release
  across that shape three serialized publishes with a resolver-liveness probe
  between each.
- **Release discipline on a fourth member**: `## Unreleased` on feature branches
  only, a dedicated release commit, a `cux_train-v…` tag prefix. `tool/release.sh`
  is already member-generic, so this needs no script change.
- **`CONTRIBUTING.md`'s rule that actually bites is the fake rule, not the
  watch-it-fail rule.** *"A fake must carry the semantics the tested branch
  selects on"* — and the 520-line `fakes.dart` the member would inherit documents
  its own instance of that failure at `status.dart:1363`, whose compensating
  control is the one test §3 shows breaks on relocation. `SHIPPING.md` §12.4
  records a second for the `StoreReads` fake: a hand-built fixture can say
  `serving: true` beside `status: halted`, a state no store produces. Both are
  more actionable than listing mutations in a PR body, and the 10,718 inherited
  lines have never been observed failing with their guards removed.
- **README.md is already one member stale** — its table has two rows and omits
  `cux_buildnumber`, and the prose still says "Two published packages" and "both
  packages". A fourth makes it two stale. Updating it is part of the move.
- **The history import is lossier than it sounds.** 118 commits touch
  `tool/train` and **67 of them also touch paths outside it**, so a path-filtered
  import keeps each message while dropping the other half of the change it
  describes. That is weaker than this repository's own extraction claim, where
  `git log --follow` reaches back past the extraction intact. And
  `cycling_storyteller` carries no LICENSE, so the import publishes a private
  repository's 118 commit messages into a public Apache-2.0 one. Relicensing
  itself is paperwork: same author, and `NOTICE` is the template.

## 5. The app-specific surface

The train is already parameterized on most of what an app would supply: `Train`
takes `options`, `runner`, `repo`, `toolDir`, `buildTokens`, `betaGroup`,
`appleBundleId`, `playPackageName`, two widget factories and a `HookSet`. What is
not parameterized:

**Seven spawned paths**, relative to `toolDir`: `ship`, `build.sh`, `upload.sh`,
`promote.sh`, `finish.sh`, `corpus.sh`, `ci/release-inputs-check.sh`, plus
`train-hooks.d/`.

**Credential selectors.** `apple.api_keys.upload` and
`android.play_service_account` as `secrets exec --only` arguments — **and both of
those are in `status.dart`** (`:1358`, `:1474`), not in the files §6 called the
release model. The keychain selector is **not** the `${platform.name}_appstore`
template the first pass described: AuthPass names four profiles in one call —
`ios_appstore`, `ios_appstore_autofill`, `macos_appstore`, `macos_developerid`
(`ios.yaml:82–85`) — of which the autofill-extension profile has no
platform-derived name and `macos_developerid` belongs to notarization rather than
to the store. It is a list, not a template.

**A fourth credential input, and it is a regex over the consumer's shell
script.** `bin/train.dart`'s `_buildTokens` reads `$toolDir/build.sh` as text and
extracts `RegExp(r'--only (tokens\.[a-z_,.]*)')`, exiting 1 if it does not match.
So `build.sh` must contain a literal `--only tokens.…` string *in its source*.
The first pass said `bin/train.dart` holds the app's constants "as environment
reads with defaults" — true of three of the four, and false of this one, which is
fatal rather than defaulted. It is also prose-parsing of a sibling artefact,
which is the coupling class `read-api.md` and `SHIPPING.md` §12.4 exist to kill.

**`.cux-ship.yaml` and the `uploaded/` tag namespace, parsed by hand.**
`repo.dart:102–120` opens `$root/.cux-ship.yaml`, scans for `app-dir:`, then
scans `$root/$appDir/pubspec.yaml` for `version:` — a parse of this repository's
own config format, not through `cux_ship`. `repo.dart` hardcodes
`uploaded/v$version+$build` and `+refs/tags/uploaded/*`, and `status.dart:518`
builds the same string.

**`dist/` is not one choke point.** `_logPathFor` is bypassed by
`train.dart:1619` and `:1632`, which write `dist/train-wait-<platform>.log`
directly, and the directory appears in user-facing prose at `options.dart:172`
and `train.dart:957`.

**And `repo.dart:71`/`:84` call `Process.run`/`runSync('git', …)` directly**
rather than through `ProcessRunner`, so those invocations sit outside the
mechanism §2 rests on. The printed-command-line property survives them, but
through `StepFailure`'s argv rather than through the runner.

**So the surface is spread over five files — `train.dart`, `options.dart`,
`status.dart`, `repo.dart`, `hooks.dart` — two of which §6 assigned to the stage
that was supposed to need no contract design.** The first pass's "concentrated in
`train.dart` and `options.dart`" is the sentence that was wrong, and it is wrong
in the direction that mattered: it made the staging look cleaner than it is.

### 5.1 Two of the seven spawned paths are not steps

`corpus.sh` and `ci/release-inputs-check.sh` are How It Went's own preflights,
written into the core as though they were release steps. The seam for them
already exists: `hooks.dart`'s header states the extraction line outright —

> the train core is generic and app-specific behavior leaves it through
> `tool/train-hooks.d/`

— and the mechanism is built, with `post-upload` and `post-promote` collected and
fired after a stage (`hooks.dart:164`, `:240`). A `pre-build` and a `pre-release`
hook absorb both, and the core then spawns five things rather than seven.

**Both reviews independently called this the strongest section, and §7 now turns
on it**: the same seam is what lets a destination be declared *manual*.

### 5.2 The pressing change is identity, not the `Platform` enum

The first pass named `enum Platform { ios, macos, android }` and the four-row
`storeTable` as the one type-level change, on the strength of AuthPass's
destination list. Two corrections.

**The flavor count was wrong: AuthPass has seven, not six** —
`authpass/android/app/build.gradle:74–118`, dimension `hpdist`: `samsungapps`,
`huawei`, `amazon`, `playstore`, `playstoredev`, `fdroid`, `sideload`. Three
Windows variants, Linux and web were right.

**But flavors are the wrong unit, and the enum is less pressing than it looked.**
Of the seven, exactly two reach a store API: `playstore` and `playstoredev`.
`fdroid` has no branch in `release.sh` at all and nulls its signing config —
F-Droid builds from source off a tag. `amazon`, `huawei`, `samsungapps` and
`sideload` build an APK, go to the artifact server and the GitHub release, and the
submission is a human in a web console. So the enum only has to open for
destinations that have *no read API*, where `status` cannot answer anyway — and
`Holdings` is already keyed `(String, String)` (`summary.dart:74`), so the grid
takes a `Microsoft Store` or `Snap` column with no type change.

**What actually breaks first is identity, and it breaks in Stage 1.**
`LiveStoreReads` takes four arguments, not the three the first pass reported:
`runner`, `ship`, `packageName`, **`bundleId`** (`status.dart:1336–1341`). All
three identity scalars are singular where AuthPass is plural:

- **Two App Store app records, not one app with two platforms.** iOS is
  `design.codeux.authpass.ios`; macOS is `design.codeux.authpass`, and
  `upload-macos.sh` says outright that this is "not the iOS bundle id with a
  suffix, it is a different app record entirely". `_appstore()` builds
  `--platform <p> --bundle-id <scalar>`, so for AuthPass the bundle id is a
  function of platform.
- **`storefrontReleased()` takes no platform**, and its own dartdoc explains why:
  How It Went is a universal purchase, so "a caller that wanted two per-platform
  answers has nothing to key them on". That caller is AuthPass, and
  `StorefrontReleasedDocument` carries no platform — so this one is a `cux_ship`
  document-level assumption, not fixable inside the train.
- **Two Play destinations.** `playstore` → `design.codeux.authpass`;
  `playstoredev` → `design.codeux.authpass.dev`, which `upload-android.sh` calls
  "a separate listing, not a track of the main one". One `packageName` holds
  neither both, nor does a `(StoreId, List<Platform>)` row: `StoreId.play`
  carries no package identity.

`storeTable`'s own comment names the right axis — a row can express a store that
takes a differently-signed artifact, and a destination that is not an upload at
all. Two cases to add to it, both *several destinations sharing one platform*
rather than a platform-string problem: **a per-destination app record**, and **a
destination whose credential is out of band and whose step is operator-only** —
AuthPass's notarized macOS download needs a *team* App Store Connect key that
cannot be scoped to one app and is deliberately kept off CI.

## 6. What the donor loses

Status: **open**, and it is the gap the first pass missed entirely.

`tool/train` **is** How It Went's release pin, and that is not incidental.
`SHIPPING.md` §12.3 is the decision: three structures were compared and B — fold
the pin into `tool/train` — was taken, so that `tool/ship` execs
`bin/cux_ship.dart` out of the same `package_config.json` the train imports from
and *"the two cannot resolve to different builds however stale a checkout gets"*.

The incident behind it: a worktree resolved on 31 August kept answering with
`cux_ship-3.6.1` after the lockfile beside it said 4.0.1, through two builds and
two uploads, until a log line 4.0.1 no longer prints gave it away. Two of
thirty-one worktrees on that desk were already in the stale state when it was
written.

**Consume the train from here instead and How It Went has two pins of `cux_ship`
again** — the one inside the pinned `cux_train` and the one `tool/ship` resolves
locally — and `tool/ship` compares one lockfile against one resolution, so the
second is invisible to it. That is the bad state B was chosen to make
unrepresentable.

This is also why the train declares `cux_buildnumber: ^0.1.0` while importing it
nowhere: the package is doing double duty as the repository's tooling pin, and
that role has no home after the move. **Where the donor's pin lives afterwards
has to be answered before the move, not after it.** It is the one cost on this
list that falls entirely on the repository giving the code away.

## 7. The staging, and the first pass had it backwards

The first pass split the move at the point where the previous author's
parameterizing stopped: 4,359 lines needing "no contract design", and 3,150 that
are a release model. **That boundary does not hold, and the readiness was
assigned to the wrong half.**

**The boundary is one symbol short.** `status.dart:67` is `import
'options.dart'`, and `Platform` appears 17 times in that file — including in the
`StoreReads` interface signature itself (`:82`, `:84`, `:98`, `:121`). It is the
only cross-stage edge: `Stage`, `StoreId`, `storeTable`, `StoreSelection`,
`Options` and `UsageException` appear nowhere in `status.dart`. So there are two
ways out and the first pass took neither:

- move `Platform` and `storeTable` into the first stage, which drags the one
  design decision §5.2 identifies into the stage that was defined by not having
  one; or
- ship the first stage with the closed three-value enum, which gives AuthPass a
  `status` that cannot name `fdroid`, `amazon`, `huawei`, `samsungapps`, Windows,
  Linux or web.

**This document now takes the first, and withdraws "needs no contract design".**
Per §5.2 the decision is smaller than it looked — identity scalars first, the
enum only for destinations with no read API — but it is a decision, and the stage
contains it. The two credential selectors in `status.dart` (§5) and the
`UploadRecord` supplier it needs from `repo.dart` move with it.

**And the readiness is reversed.** The first pass concluded *"Stage 1 has a
consumer today and Stage 2 does not"*. Both halves are wrong:

- **The reads stage has no consumer today.** `StoreReads` includes
  `appStorePreviews` (which needs `noSuchVersionExit`, 4.5.0-dev.3),
  `appStoreListingDiff` (`appstore upload --dry-run --metadata --json`,
  4.5.0-dev.4) and `storefrontReleased` (4.5.0-dev.6). AuthPass pins `cux_ship:
  ^3.6.0`. No stable release serves that set, so adopting it means pinning a
  prerelease two majors up — and the train declares `sdk: ^3.13.0` while AuthPass
  pins Flutter 3.44.7, whose bundled Dart is below that floor (`ci.yaml`'s own
  comment: 3.13.0 is what Flutter 3.47 bundles). That is a Flutter bump as well.
- **`status` does not answer the question AuthPass's guards ask.** Those guards
  ask *is the build number I am about to upload strictly greater than the newest
  this store holds* — `play version-code` in `upload-android.sh` and `appstore
  build-number` in `upload-ios.sh`/`upload-macos.sh`, neither of which is in
  `StoreReads`, and both of which exist in 3.6.0. `status`'s baseline is instead
  the newest `uploaded/` tag, so it cannot be a pre-upload gate: the thing it
  compares against is a record of what already went up. The failure policies are
  opposite too — AuthPass's guards swallow an unreadable store and are escapable
  by an environment variable, while a read that threw lands in
  `StatusReport.failed`, which is what makes the command exit non-zero. An
  AuthPass `status` is a new human-facing report, which is worth having; it is
  not a consolidation of anything.

**The stage that has a consumer today is the ordering one**, and §5.1 is why. See
§8.

## 8. What this does not fix — reversed

Status: **open**.

The first pass concluded that AuthPass's release is not a single event, citing
[release-check.md](release-check.md) §3, and that the condition for the second
stage is a decision AuthPass has not taken. **The five facts it listed are all
accurate** — no `promote.sh`, no `finish.sh`, no `play promote` / `appstore
promote` / `release finish` anywhere, CI-driven uploads, no listing requirements
in `.cux-ship.yaml`. The conclusion drawn from them is wrong, and two of the
supporting claims are too.

**"AuthPass does not build them locally at all" is false.** Its macOS direct
download is built, signed and notarized on a laptop, deliberately:
`_tools/notarize-macos.sh` is "not on CI on purpose" because notarization needs a
team key that cannot be limited to one app, read from `~/.appstoreconnect` and
never from the repository. `_tools/release/github-release.sh` and
`fosshub-release.sh` are operator steps too. The operator's terminal is already
part of that release.

**And the decision the first pass says AuthPass has not taken is written down.**
`authpass/README.md`'s "## Releasing" section opens *"One day I have to automate
this..."* and is an ordered, single-event checklist: write the CHANGELOG, push
`stable`, wait for CI, notarize locally, cut `v1.2.3` **and** `fdroid-v1.2.3`,
update `stable.txt`, generate the Windows appcast, make the GitHub release,
upload to FossHub, then "Submit release to" eight consoles — Play, App Store
Connect, Samsung, Huawei, Amazon, Microsoft Store, the Debian PPA, and snap
edge→stable. **That final list is promotion, and the single version tag at the
end is what `finish.sh` does.**

So AuthPass is not a different shape from the train. It is the same shape with
the steps performed by hand, and what it lacks is not a decision but ordering, a
status block, and a record of which steps were done. `release-check.md` §3 is
still right about the *git record* — one `uploaded/` tag per commit, so git
cannot express which destinations hold what — and that remains a real limit on
any verdict `status` prints. It is not evidence that the release is not one
event.

**The cheaper path, and it is the one to price.** §5.1's hook seam already is it:
let a destination be declared **manual** — a step the train orders, names and
waits on rather than spawns. AuthPass then gets ordering, the pinned status
block, and `--prepare` over the checklist it already follows, with no change to
who performs any step, no `promote.sh` and no `finish.sh`. That is the ordering
stage minus the two scripts AuthPass does not have, and it has a consumer today.

It also makes §1's argument stronger rather than weaker. `SHIPPING.md` §2 warns
against generalizing from one-and-a-half examples; a `HookSet` plus a `manual`
destination kind *is* the generalization from a second real example, and the
second example is the one that needed it.

Two smaller corrections in the same section. AuthPass's release triggers are
wider than "a push to `stable` or `beta`": also `macos-stable`, `linux**`,
`windows**`, `web-beta` and `tags: v*` — per-destination across five branch
patterns and a tag. And "nothing to check" is overstated:
`store/appstore/listings/en-US/beta_description.txt` exists, and both Apple
uploaders pass `--no-metadata` specifically because it does, so a `store-verify`
preflight has something to verify the day AuthPass declares requirements.

## 9. Open questions

Status: **open**.

- **Where does the donor's `cux_ship` pin live after the move?** §6. This one
  gates the move rather than following it.
- **Where does the coverage of the five shell scripts and the Python script go?**
  §3. "Deleted" and "left in a package that no longer exists" are the two honest
  answers.
- **Published, or `publish_to: none`?** §4 shows an unpublished member costs
  nothing in this repository's CI. It is not free at the consumer, and the first
  pass called this open when this repository had already answered it:
  [publishing-from-a-workspace.md](publishing-from-a-workspace.md) records that a
  git dependency on a member needs
  `dart --packages=<checkout>/.dart_tool/package_config.json
  <checkout>/<member>/bin/…`, because `pub get` writes no config beside the
  member — found "9 September 2026 by a consumer pinning a branch of this
  repository as a git dependency". AuthPass's `ship.sh` ends in `exec "$dart" run
  cux_ship "$@"`, the exact invocation that warns. So a `publish_to: none`
  `cux_train` is materially worse for the second consumer, not merely "not the
  better one".
- **The name is a filename, not a label.** §4 — pub ties the entry library to
  the package name on pain of exit 65, so choosing `cux_train` renames
  `lib/train.dart` to `lib/cux_train.dart` and every consumer's import with it.
  `cux_ship_train` is the other reading and costs the same rename.
- **Does the pinned terminal block belong in this repository at all?** Promoted
  from a note to a finding, because the second consumer settles it: every AuthPass
  upload runs on a GitHub runner with no TTY, and **1,399 of the reads stage's
  4,359 lines are pinned-terminal presentation** — `pinned_block` 221, `style`
  371, `panel` 442, `status_block` 143, `upload_progress` 222 — which degrade to
  null off a terminal. What AuthPass would use in CI is none of it. A package of
  their own, with no googleapis attached, is the alternative.
- **What is the Dart floor, against Flutter 3.44.7?** §7 asserts AuthPass's
  bundled Dart is below `^3.13.0` from `ci.yaml`'s comment about Flutter 3.47.
  Not verified against the SDK itself, and it should be before §7 is relied on.
- **Does the train replace AuthPass's build matrix, run inside one cell, or watch
  it?** Its Android release is a six-way matrix with `fail-fast: true`, each cell
  allocating its own build number by pushing a ref, while `Train` takes a
  `List<Platform>` and assumes one process orders every destination. And its Apple
  path is deliberately two CI *steps* with a build number handed between them
  through a file, so the build step never holds a decryption key — the split that
  made `cux_ship` 3.0.0 adoptable there. Whether a `RELEASE_PHASE`-style split
  survives the train is unanswered, and AuthPass will not give it up.
- **Should `secrets exec` strip `SOPS_AGE_KEY`?** §2.1. Not this document's
  question, but this document is the reason it stops being latent.
