# The release train is a sibling member, not a library in `cux_ship`

Status: **decided**, second pass, with one adversarial and one consumer review
folded in, 8 November 2026. Everything marked *verified* was run on this
machine with Dart 3.13.7 and git 2.54.0; everything else is argument or is
marked as read rather than measured.

**Taken, and begun, 10 November 2026.** `cux_train` exists as the fourth
workspace member — an entry point, a usage text and the tests that hold both,
with no train in it. The move itself is still ahead, and §7's staging is the
order it goes in: the **ordering** stage first, because §8 is right that it is
the one with a consumer today. The status is `decided` rather than `built`
because the subject of this document is the move, and the move has not
happened; §7, §8 and §9 stay `open` where they say so.

**And §7's Dart floor is wrong in the consumer's favour — measured 10 November
2026.** §7 asserts that the donor declaring `sdk: ^3.13.0` makes the move "a
Flutter bump as well" for AuthPass, whose pinned Flutter 3.44.7 bundles Dart
**3.12.2** (confirmed from Flutter's release index; the `ci.yaml` comment §7
cites is right that 3.13.0 is what Flutter 3.47.0 bundles, and 3.47.7 bundles
3.13.5). The constraint turned out to be incidental rather than required. Its
line in `tool/train/pubspec.yaml` carries no reason — unlike every dependency
constraint around it, each of which records "the floor it names and why" — only
`TO BUMP: widen the constraint and run dart pub get here`. The analyzer gates
language features on the *declared* constraint, so a copy of that package with
the constraint lowered reports anything needing a newer language version
without an older SDK being installed. On a copy, leaving the repository's
lockfile untouched:

```
constraint now: 89:  sdk: ^3.12.2
dart pub get  → Changed 68 dependencies!   exit 0
dart analyze  → No issues found!           exit 0
```

So the train uses nothing from Dart 3.13, `cux_train` declares `^3.12.2` with
its three siblings and the workspace root, and the SDK move drops out of the
ordering stage's price. The dependency side agrees, which is what makes it safe
rather than merely convenient: `cux_ship` 4.5.0-dev.8 itself declares
`^3.12.2`, and of the six resolved packages whose floors exceed 3.12 every one
is test tooling or a leaf parser with older compatible versions
(`analyzer`, `_fe_analyzer_shared`, `frontend_server_client`, `petitparser`,
`web`, `xml`). **The other half of §7's objection is untouched** and is the
half that was load-bearing: the *reads* stage still needs a 4.5.0-dev pin two
majors above AuthPass's `^3.6.0`, and `status` still does not answer the
question AuthPass's guards ask.

**§6.4 was amended 9 November 2026**, while this was open for review, because
the fix it recommended turned out to belong in this repository rather than at
the consumer. That fix was
[#85](https://github.com/codeuxdesign/cux_ship/pull/85), **merged 10 November
2026** — before this document itself landed — so §6.4 is true of `main`. It is
still in **no release**: it sits under `## Unreleased`, and the donor's pin is
`4.5.0-dev.8`, which predates it. This sentence read *"not merged, and not in
any release"* until 12 November 2026, which was half true from the day the
document landed. The old recommendation is recorded in place rather than
removed. The same review turned up a knock-on in §4 and §9 that §6.4 had
silently invalidated, and a figure in §6.4 that had been revised without being
recorded; both are fixed and marked.

**And a third review took out a premise this document inherited.** The
`resolution: workspace` warning — the reason a consumer invokes an entry
instead of `dart run`, and so the reason any of §6.4 exists — **does not print
on Dart 3.13.7**. Measured 9 November 2026 on hosted `cux_ship 3.4.1`, the
version [publishing-from-a-workspace.md](publishing-from-a-workspace.md) says it
verified: zero bytes of stderr from `pub get` and from `dart run`. That document
now carries the correction. Nothing here is withdrawn — naming the entry still
earns its keep for a cached kernel snapshot, and this repository's CI pins
3.13.0, so older pins may still be noisy — but §9's `publish_to: none` bullet
rested on the message and is marked for re-pricing rather than quietly adjusted.

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
  symbol is the one §5.2 says a second consumer forces open. §7 withdraws the
  claim.

The conclusion — move it, as a sibling, in stages — survives all three. What
does not survive is the order of the stages, which §7 and §8 now reverse.

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

**The sharpest single failure is in the set §7 used to call Stage 1.**
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
   libraries — five once §6.4's `lib/cli.dart` lands — and the check fires on a
   single one.

   **And §6.4 hands `cux_train` that same escape, which was not noticed when
   §6.4 was written.** Its rule is that a published member with an executable
   declares it in `lib/cli.dart`; a `cux_train` carrying one has two top-level
   libraries, and the check stops firing. Re-probed on the same
   `zz_train_probe`, 9 November: the `should match` line above is present with
   `lib/train.dart` alone and **gone** once a `lib/cli.dart` sits beside it,
   with the warning count dropping by exactly one. So the barrel rename may
   still be *wanted* for legibility, but **it is no longer forced**, and the
   naming question in §9 is presentational after all. Anyone who priced a barrel
   rename plus every consumer's import off this warning was pricing something
   that will not fire. §9's bullet is corrected to match. (This sentence pointed
   at §8 before; the naming question has always been in §9.)
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
those are in `status.dart`** (`:1358`, `:1474`), not in the files §7 called the
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
`status.dart`, `repo.dart`, `hooks.dart` — two of which §7 assigned to the stage
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

## 6. What the donor keeps

Status: **proposed**, worked out 8 November 2026. This section was `open` an
hour earlier, as *"where does the donor's `cux_ship` pin live after the move?"*,
and it was the question said to gate everything else. The answer is that the pin
does not move at all, and the reason it looked like it must is worth more than
the conclusion.

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

### 6.1 "Two pins again" is wrong, and the reason is the useful part

The objection was that consuming the train from here gives How It Went two pins
of `cux_ship` — the one inside the pinned `cux_train` and the one `tool/ship`
resolves locally — re-creating the state B was chosen to forbid.

**A dependency's lockfile is not shipped to its consumers; pub ignores it.**
`cux_train` would declare a *constraint*, and the donor's single `pub get`
resolves one `cux_ship` into one lockfile. **Two pins requires two lockfiles,
and the move does not add one.**

So B's property was never "the library and the pin sit in one directory". It was
**one lockfile that both the in-process import and the spawned CLI resolve
from** — and emptying `lib/` does not add a lockfile. Stated that way the
property is obviously preserved, which is why the first pass's framing of this
as the gating cost was wrong: it read B as being about *co-location* when §12.3
argues it as being about *arity*.

### 6.2 The donor's wrapper needs no change, verified three ways

**Read §6.4 first if you are here for the mechanism.** The two bullets below
describe how the wrapper read `rootUri` with a comma-anchored `sed` when this
was measured, and that is the very read §6.4 replaces — kept in the present
tense here it would tell you the launcher still works a way it no longer does.
The conclusion of this section survives intact: the wrapper needs no change
*for the extraction*, whichever way it finds the entry.

- **`ship` finds a transitive `cux_ship`.** It read the `rootUri` beside
  `"name": "cux_ship",` out of `package_config.json`, and that file lists every
  package in the resolution, direct or transitive. Measured on a three-level
  path-dependency probe: the leaf appears with a `rootUri` although nothing
  depends on it directly.
- **A hosted entry carries the URI form `ship`'s `sed` expected.** The donor's
  own config today reads
  `file:///Users/…/.pub-cache/hosted/pub.dev/cux_ship-4.5.0-dev.8`, absolute and
  `file://`-prefixed, and `cux_ship_verify` — already transitive-adjacent — has
  the same shape.
- **A transitive executable runs both ways.** `dart --packages=<config>
  <path/to/bin.dart>` → exit 0, and `dart run <transitive-package>` → exit 0
  with no warning. The second was the risk worth checking, because AuthPass's
  `ship.sh` ends in `exec "$dart" run cux_ship "$@"`; it survives `cux_ship`
  becoming transitive.

And `require_current_resolution` in `_resolution.sh` already compares **every**
package in the lockfile against the config — hosted by `version`, git by
`resolved-ref` — so `cux_train` is covered the day it appears, with no edit. The
guard was generalized away from `cux_ship` specifically when `tool/train.sh`
needed the same question asked about a different failure, and that generalization
is what pays here.

### 6.3 What the donor's package becomes

```yaml
# tool/train/pubspec.yaml — How It Went
name: cycling_storyteller_train
publish_to: 'none'
dependencies:
  cux_train: ^1.0.0
  cux_ship: 4.5.0-dev.8      # kept direct: see below
  cux_buildnumber: ^0.1.0
```

`lib/` empties; `bin/train.dart` stays, because §3 and §5 establish it cannot
move — it holds the bundle identifier, the TestFlight group, the sibling checks
and the `--only tokens.…` regex over `build.sh`. `RELEASE_PACKAGE=train` in
`_release_pkg.sh` does not change, so none of the five callers it exists to keep
in step move either.

**Keep `cux_ship` a direct dependency even though it would resolve
transitively.** Not for `dart run` — §6.2 shows that works regardless — but
because the pin is a thing this repository states on purpose. `_release_pkg.sh`
says five things find it through one name; a constraint that exists only inside
someone else's pubspec is not a pin the donor can read or bump. Declaring it
direct also turns a disagreement between the donor's intent and `cux_train`'s cap
into a **resolution failure** rather than a silent widening, which is the choice
`SILENT-FAILURES.md` asks for everywhere else.

**And `cux_buildnumber: ^0.1.0`, declared and imported nowhere, stops being
odd.** The first pass read it as a leftover of the package doing double duty.
After the move the double duty *is* the duty: the donor's package exists to be
the pin plus `bin/train.dart`, and an unimported pin is what that looks like.

### 6.4 One form of the dependency broke the wrapper, and the fix belonged here

| form | one lockfile | `ship` finds the CLI |
|---|---|---|
| hosted `cux_train: ^1.0.0` | yes | yes |
| git ref on this repository | yes | yes — `resolved-ref` already covered |
| `path:` to a local checkout | yes | **no** |

*As measured, before the fix below. There is now no path to find, so the third
row is a fact about a question nobody asks any more.*

**Measured: a path dependency's `rootUri` is relative** — `../../leaf` on the
probe — and `ship`'s extraction was
`sed -n 's|.*"rootUri": "file://\(.*\)".*|\1|p'`, which matches nothing. It then
died on *"could not read cux_ship's location"*, naming the right file for the
wrong reason.

That is the form a developer reaches for when working on both repositories at
once, so it is the one that will be hit, and by whoever is mid-change rather than
mid-release.

**This section first answered "parse the file rather than widen the pattern",
and that was the right shape at the wrong level.** A launcher reads `rootUri` at
all only because this repository made its entry a filesystem path — and for a
hosted pin that path is a version-stamped directory under `~/.pub-cache` that
nothing but the config knows. One file here against a parser in every consumer.

So since 8 November 2026, and on `main` since the 10th, `cux_ship` and
`cux_buildnumber` declare their CLIs in `lib/cli.dart`, the VM resolves the
entry through `--packages`, and the failing row has nothing left to find:

```bash
dart --packages=<root>/.dart_tool/package_config.json \
     package:cux_ship/cli.dart "$@"
```

A relative `rootUri` stops mattering because nobody reads `rootUri`. `main`
rather than a named function is what makes that line work, because the VM looks
up `main` in whatever library it is handed as the script; `bin/cux_ship.dart`
becomes `export 'package:cux_ship/cli.dart' show main;`, so `dart run` and `dart
pub global activate` are unchanged. The regex had two further defects the same
change removes: a percent-encoded `file:` URI passed through verbatim, and
`"name": "cux_ship"` matching `cux_ship_verify`, which is the next entry in the
file.

**That branch landed, and this section is now true of `main`.** It was
[#85](https://github.com/codeuxdesign/cux_ship/pull/85), merged 10 November
2026 — before this document itself landed, which is why the paragraph was
wrong on arrival rather than overtaken. It read *"that branch is not this one,
and this section is only true once it lands"*, and said that
[publishing-from-a-workspace.md](publishing-from-a-workspace.md) did not
mention `lib/cli.dart` at all. That document now carries its own amendment —
the entry is no longer a path — while keeping *"the fix is a path, not a
pubspec"* in place as the sentence this section overturns. All three members
declare `lib/cli.dart`, `cux_train` included, so this section's requirement
below was met at creation rather than left to ask for.

**The released half has not moved, and it is the half the donor feels.** No
*released* `cux_ship` carries any of this; the donor's pin is `4.5.0-dev.8`,
which does not. So the facts above are still stated here rather than delegated
to a release.

**Which turns this section's requirement on `cux_train` from a parser into one
line: a published member with an executable declares it in `lib/cli.dart`.** It
costs one file at creation and spares every consumer the question.
`cux_ship_verify` bounds the rule rather than breaking it — no `bin/`, so no
entry to declare.

**Two things keep the donor's parser alive for now, so it was still worth
writing.** Not the three defects — the parser fixed those the day it landed, and
saying otherwise (as this paragraph first did) leaves a reader unable to tell
whether the donor is broken today. What is live is the **need to read a path at
all**, and it is the *hosted* pin that keeps it alive: `4.5.0-dev.8` has no
`lib/cli.dart`, so there is nothing to name but a version-stamped directory
under `~/.pub-cache`. A `path:` pin is the opposite case — it resolves to a
working tree, so a checkout carrying the fix can use the `package:` form at
once, with no release in between. The relative-`rootUri` defect was still worth
fixing on its own account, and not as the hypothetical the table makes it look:
the relative form is what pub writes for a **workspace member**, so it is in
this repository's own config today (`cux_ship` resolves to `"../cux_ship"`) and
in the donor's (the root package at `"../"`). And `dart compile kernel` refuses
a `package:` URI
(*`"package:cux_ship/cli.dart" file not found`*, where the plain `dart` above
resolves it), so a consumer caching a snapshot still needs a real file — though
it can be a one-line `export` committed in its own tree rather than a path
recovered from the cache.

**For the record, because the research was the expensive part: no `dart` command
prints that path.** `dart pub deps --json` gives each package exactly `name`,
`version`, `kind`, `source`, the dependency lists and the constraints, and no
path for any of them; the `executables` list — `["train",
"cux_buildnumber:git_buildnumber", "cux_ship", "test"]` — is a top-level key
rather than a per-package one, and it is names only. The documented artefact is
`package_config.json`
itself (`configVersion: 2`), whose documented parser is `package:package_config`
(`findPackageConfig`/`loadPackageConfig`) and whose in-process equivalent is
`Isolate.resolvePackageUri` — the route `test/fakes.dart` already takes. Both are
Dart-side, and the bash wrapper every other tool spawns cannot pay a VM start to
find a path before starting the VM that does the work. Measured on the donor's
own config (68 packages, 12.9 kB): `grep | sed` around **7 ms**, the python
parser **39–47 ms**, a Dart reader **150–180 ms**.

**The middle figure is a range because it would not hold still, and this
sentence has now carried four different numbers.** It said 28 ms in the first
pass, 56 ms on 9 November, then 39 ms, then 39–47 — and the spread is not
sloppiness in the last two: the same machine measured an hour apart under
different load gave 39 and 47, with bare `python3 -I -c pass` moving 13 → 17 ms
over the same interval. Only the first two were wrong; the rest is load. So the
honest form is an order of magnitude, which is all the decision needs: the Dart
reader is 3–20× the others and is the one that cannot be avoided by starting
fewer processes. Recorded rather than quietly corrected, per this document's own
rule, because a figure nobody can reproduce is worse than no figure.

**And a correction to this section's own advice, which is the better lesson.**
It said the donor could nearly halve the parser by dropping its
`urllib.request` import, on the strength of `python3 -I -c 'import json,
urllib.parse'` costing 17 ms less than the same plus `urllib.request`. The
donor tried it. Timed as two copies of the real script differing only in that
import, 30 runs each over three alternating rounds: **46.7/47.3, 47.3/47.0,
47.3/46.3 ms — no difference at all.** Once `json` and `pathlib` are loaded the
marginal cost is noise, so the import is back and the parser is unchanged. An
import benchmarked in isolation is not a measurement of the program that
contains it, and about 3 ms of the whole thing is the JSON parse either way.

`jq` would also work and is on GitHub's runners, but it would be a new unpinned
binary on the hot path of a repository whose `deps.lock` exists to pin external
binaries. And a Dart reader could not be snapshotted away the way `cux_ship`
itself is, because it computes the path the snapshot is compiled from.

### 6.5 The cost that is real

The donor loses **unilateral** control of the pin. Today a `cux_ship` bump is one
line in one pubspec. Afterwards, a bump past `cux_train`'s cap needs a
`cux_train` release first — and §4's diamond makes that up to three serialized
publishes with a resolver-liveness wait between each. During a release that is
the difference between a one-line edit and an afternoon.

**The escape hatch is already named in the donor.** `_release_pkg.sh` says: *"If
a second Dart tool ever needs `cux_ship` as a library rather than as a command,
the answer is a pub workspace and this moves again; docs/SHIPPING.md §12.3 has
the comparison and what it would cost."* A donor-side workspace over
`tool/train` and a local `cux_train` checkout restores same-day iteration, at
exactly the price §12.3 put on A′ — a root pubspec, deleted member lockfiles, a
`resolution:` key per member, a pre-commit hook change, and the pin declared
twice. Worth paying during development of the extraction and not after it.

So the honest summary is that the move costs the donor **release-time latency on
a `cux_ship` bump**, not the integrity property §12.3 was written to protect.
That is a smaller cost than the first pass claimed and a different one, and it is
the kind that only shows up under time pressure — which is the argument for
settling the workspace question before the first release that needs it rather
than during.

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
  prerelease **one** major up — and the train declares `sdk: ^3.13.0` while
  AuthPass pins Flutter 3.44.7, whose bundled Dart is below that floor
  (`ci.yaml`'s own comment: 3.13.0 is what Flutter 3.47 bundles). That is a
  Flutter bump as well.

  *Corrected 12 November 2026:* this bullet said "two majors up". 3.6.0 to
  4.5.0 is a single major step, and `cux_ship/pubspec.yaml` is
  `version: 4.5.0-dev.8`. The figure changes no conclusion here, and it is
  corrected anyway because it had already been copied into a draft of
  [authpass-on-the-train.md](authpass-on-the-train.md) and restated there as
  read fact. Also worth recording beside it: 4.5.0 has no stable release, but
  **4.4.0 does**, and the `--json` reads a consumer needs for Play and the App
  Store land in 4.1.0 — so a consumer wanting the reads and not exact parity
  with this document's `status` can stay on a stable pin.
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

- **When does the donor's pub workspace get built — before the extraction or
  after the first bump that needs it?** §6.5. The pin itself no longer moves
  (§6), and the `rootUri` question is now closed from both ends — the donor
  parses the config today, and stops needing to the day its pin reaches a
  release carrying `lib/cli.dart` (§6.4). So what is left here is release-time
  latency on a `cux_ship` bump, and that is the donor's to schedule.
- **Where does the coverage of the five shell scripts and the Python script go?**
  §3. "Deleted" and "left in a package that no longer exists" are the two honest
  answers.
- **Published, or `publish_to: none`?** §4 shows an unpublished member costs
  nothing in this repository's CI. It is not free at the consumer, and the first
  pass called this open when this repository had already answered it:
  [publishing-from-a-workspace.md](publishing-from-a-workspace.md) records that a
  git dependency on a member needs `--packages` pointed at
  `<checkout>/.dart_tool/package_config.json`, because `pub get` writes no
  config beside the member — found "9 September 2026 by a consumer pinning a
  branch of this repository as a git dependency". **That finding is about where
  the config lives, and it still stands.** What §6.4's `lib/cli.dart` change
  replaces is only the *script* argument on the same line —
  `<checkout>/<member>/bin/….dart` becomes `package:<member>/cli.dart` — so the
  surprising half is untouched: pointing `--packages` at the member is still the
  wrong guess, and it still reads as a broken checkout rather than a wrong flag.
  AuthPass's `ship.sh` ends in `exec "$dart" run cux_ship "$@"`.

  **This bullet needs re-pricing before it is relied on, because the warning it
  rests on no longer prints.** Measured 9 November 2026 on Dart 3.13.7: a
  consumer on hosted `cux_ship 3.4.1` gets zero bytes of stderr from both `pub
  get` and `dart run`, and `publishing-from-a-workspace.md` now carries that
  with what was run. The `--packages` awkwardness above is only *reached* by a
  consumer avoiding `dart run`; one that can simply call `dart run cux_train`
  never meets it. So the cost of `publish_to: none` is smaller than this bullet
  says, and what survives of it is narrower: a consumer that caches a kernel
  snapshot still needs a real entry path, and for a git checkout that path is
  hand-writable, which is the cheap case. Still probably "not the better one",
  but the "materially worse" framing was carried by a message that is gone, and
  this question is `open` — so it should be re-answered on the snapshot and on
  resolver behaviour, not on log noise. CI pins can lag (this repository's own
  workflow pins 3.13.0), so a consumer on an older SDK may still see it.
- **The name is a filename, not a label — and §6.4 took the force out of this.**
  §4 — pub ties the entry library to the package name on pain of exit 65, so
  choosing `cux_train` would rename `lib/train.dart` to `lib/cux_train.dart` and
  every consumer's import with it; `cux_ship_train` is the other reading and
  costs the same rename. **But that check fires only on a package with a single
  top-level library**, and §6.4 now requires a `lib/cli.dart` beside the barrel,
  which is a second one. Re-probed 9 November: the warning is present with the
  barrel alone and gone once `lib/cli.dart` exists. So the question is back to
  being a naming preference, answerable on legibility, with no exit 65 behind
  it — which makes it cheaper to settle, not harder.
- **Does the pinned terminal block belong in this repository at all?** Promoted
  from a note to a finding, because the second consumer settles it: every AuthPass
  upload runs on a GitHub runner with no TTY, and **1,399 of the reads stage's
  4,359 lines are pinned-terminal presentation** — `pinned_block` 221, `style`
  371, `panel` 442, `status_block` 143, `upload_progress` 222 — which degrade to
  null off a terminal. What AuthPass would use in CI is none of it. A package of
  their own, with no googleapis attached, is the alternative.
- **ANSWERED 10 November 2026 — what is the Dart floor, against Flutter
  3.44.7?** Flutter 3.44.7 bundles **Dart 3.12.2**, so §7's reading of
  `ci.yaml`'s comment was right and AuthPass is indeed below `^3.13.0`. **But
  the floor is not required**: the donor's constraint is incidental, the train
  analyzes clean declared at `^3.12.2`, and `cux_train` therefore declares
  `^3.12.2` like its siblings. This question asked whether §7 could be relied
  on; the answer is that its premise holds and its conclusion does not. The
  header has what was run, and the ordering stage asks the consumer for no SDK
  move. Nothing here closes §7's *other* objection, which is the reads stage's
  4.5.0-dev pin.
- **ANSWERED 12 November 2026 — does the train replace AuthPass's build matrix,
  run inside one cell, or watch it?** None of the three: it conducts from
  outside and enters no cell. The question as originally written, with its own
  premise, follows; the answer is below it.

  Its Android release is a six-way matrix with `fail-fast: true`, each cell
  allocating its own build number by pushing a ref, while `Train` takes a
  `List<Platform>` and assumes one process orders every destination. And its Apple
  path is deliberately two CI *steps* with a build number handed between them
  through a file, so the build step never holds a decryption key — the split that
  made `cux_ship` 3.0.0 adoptable there. Whether a `RELEASE_PHASE`-style split
  survives the train is unanswered, and AuthPass will not give it up.

  **The answer.** The plan is
  [authpass-on-the-train.md](authpass-on-the-train.md), written to the
  maintainer's own goal — `train.sh` typed the same way in both repositories,
  with AuthPass still distributing to every channel. `tool/train.sh` runs on the
  maintainer's machine; CI cells keep running `release.sh` as *steps*, and the
  train orders across jobs, which only something outside the jobs can see. So
  the `RELEASE_PHASE` split is not "preserved" but untouched, and the matrix and
  its `fail-fast` are never seen by the train at all.

  **The premise above is wrong, in both directions.** "Each cell allocating its
  own build number by pushing a ref" is not what happens: `_generateOrGet`
  returns the commit's existing number before allocating, and concurrent cells
  converge on the first push's note. AuthPass's `refs/buildnumbers/commits`
  carries one allocation per commit with none repeated, so one commit has one
  number and there is nothing for the train to centralize.

  But the reassuring reading of that is also wrong, and it took a second review
  pass to see: a *release* is not one commit. AuthPass's 1.9.13 has **dozens**
  of `uploaded/` tags, each on its own commit (25 of them on 12 November 2026,
  and climbing), because `main.yml` builds and uploads `playstoredev` on every
  pull request to `main` as well. Its real build is **2196**, the number
  allocated for `origin/stable`'s tip — which `refs/buildnumbers`, the only
  tag at that commit, the artifact server's manifest and snap `edge` all
  agree on, while the highest `uploaded/` tag says 2219. So the invariant
  this document's five verbs rest on — *the same build* moving through
  audiences — does not hold at a consumer like AuthPass unless the release
  candidate is **named** rather than inferred from the newest record. That is a
  requirement on `cux_train`, and it is the one finding of this pair that
  changes the design.

  Parity is reached by declaring every AuthPass release step a destination and
  letting most start as `manual` — which is what its README checklist already
  is — so the five verbs *mean* the same in both repositories before anything
  is automated, with `status` and `production` working from the first step and
  `ready`, `beta` and `internal` becoming real as destinations flip from
  `manual` to automated, one at a time, behind an unchanged command. `beta` is
  honest for exactly three of nineteen destinations and refuses by name for the
  rest. The real new work is resumability and distinguishing *observed* from
  *attested*, because an AuthPass `production` spans days and half its
  destinations can only be attested by a person.
- **Should `secrets exec` strip `SOPS_AGE_KEY`?** §2.1. Not this document's
  question, but this document is the reason it stops being latent.
