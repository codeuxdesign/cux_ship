# AuthPass on the train: the train brackets the matrix

Status: **proposed**, 12 November 2026. Answers the open bullet in
[release-train.md](release-train.md) §9, *"does the train replace AuthPass's
build matrix, run inside one cell, or watch it?"*, with the maintainer's answer:
**everything the train supports should be replaced, and F-Droid and its kind
cannot be.** This document is what that costs and what it asks for.

Everything marked *read* was read out of the AuthPass checkout at
`claude/train-script-cux-ship-integration-28cdfd`; everything marked *measured*
was run. Nothing here is implemented.

## 1. The answer is "none of the three"

The question offered three shapes and the honest answer is a fourth: **the train
brackets the matrix.** It runs before it, between its halves, and after it, and
the matrix stays a matrix.

```
allocate   train: one build number, preflight            ← new train step
build      6 Android cells + ios + macos (unchanged)     ← FORCE_BUILDNUMBER from above
upload     train: the three destinations with an API     ← re-parented, not rewritten
name       train: the sixteen without one                ← the new concept
```

"Replace the matrix" fails because six flavors genuinely produce six different
artifacts on six cells, and nothing about that is accidental. "Run inside one
cell" fails because a cell cannot order the cells beside it. "Watch it" is
closest and still wrong, because the most valuable thing the train can do here
happens *before* the matrix runs: allocate one build number instead of six.

## 2. What the train can actually replace is small

*Read* from `authpass/_tools/release.sh`, `.github/workflows/main.yml` and
`.github/workflows/ios.yaml`. Every row is a destination of one AuthPass
release.

| destination | how it ships today | does `cux_ship` speak to it |
| --- | --- | --- |
| Play, `playstore` | `upload-android.sh -t internal` | **yes** |
| Play, `playstoredev` | `upload-android.sh -t internal\|beta` | **yes** |
| App Store / TestFlight, iOS | `upload-ios.sh` | **yes** |
| App Store / TestFlight, macOS | `upload-macos.sh` | **yes** |
| build number | `ship.sh buildnumber generate` | **yes**, `cux_buildnumber` |
| Samsung, Huawei, Amazon | APK artifact, then a console by hand | no |
| Microsoft Store | `.msix` artifact, then a console by hand | no |
| sideload, linux, windows, portable | artifact server, GitHub release, fosshub | no |
| Linux PPA, snapcraft, flathub | `authpass-deb`, console, automatic | no |
| macOS direct download | **local**, notarized off CI on purpose | no, and should stay no |
| F-Droid | builds from source itself | nothing to speak to |

So "everything the train supports should be replaced" is right, and the set is
**four steps plus the allocator**. Three of the four already call `cux_ship`;
moving them under a train step is re-parenting, not rewriting.

**Which is why the ordering stage is the one worth building.** AuthPass's
release is roughly twenty steps — `authpass/README.md` §Releasing is the list,
and it opens with *"One day I have to automate this..."*. The train can perform
five of them. It can **order and record** all twenty, and that is the larger
number by a long way. [release-train.md](release-train.md) §8 reached this from
the other side and called it *"a destination the train names and waits on,
rather than spawns"*.

## 3. The one change that pays for the work: allocate once

Today every one of the six Android cells calls `ship.sh buildnumber generate`,
which claims a number **by pushing a ref**. Six cells, six pushes, six numbers —
so the Samsung APK, the Amazon APK and the Play bundle of one release do not
agree on what build they are. *Read* at `release.sh:107` and
`main.yml:22`.

The Apple path already fixed this, across two steps rather than six cells:
`RELEASE_PHASE=build` allocates and writes `build/release-buildnumber.txt`,
`RELEASE_PHASE=upload` reads it and **refuses to allocate** if the record is
missing, with the reason spelled out at `release.sh:64` — a second `generate`
would ship an artifact whose `CFBundleVersion` is not the one Apple was told
about.

The train generalizes that from two steps to the whole release: it allocates
once, publishes the number, and every cell takes it as `FORCE_BUILDNUMBER`,
which `release.sh:63` already honors. **No new mechanism is needed at the
consumer** — the parameter, the record and the refusal all exist.

**One decision this forces.** The matrix is `fail-fast: true`. Today a failed
cell costs its own number and nothing else. Under one shared number a failed
cell leaves a *partial release at a number that is already spent*, which is more
visible and more awkward. The choice is to retry the cell or to record the
release as partial, and it should be made deliberately rather than discovered.

## 4. What must not move, and F-Droid is the clearest case

- **F-Droid is not a destination the train can have.** F-Droid builds from
  source on its own infrastructure. AuthPass's whole obligation is a
  `fdroid-v1.2.3` tag and a changelog file under `metadata/android/`, both of
  which exist before any build runs. So F-Droid is a step the train **names and
  checks** — does the tag exist, does the changelog file for this versionCode
  exist — and never one it performs. Same for flathub, which
  `authpass/README.md:94` records as updated automatically daily: the step is
  *confirm*, not *do*.
- **The `RELEASE_PHASE` build/upload split stays.** §9 says AuthPass will not
  give it up and it is right to say so: the split is what made `cux_ship` 3.0.0
  adoptable there, because the build step holds no App Store Connect key and so
  *cannot* mint signing material rather than merely not doing it
  (`release.sh:157`). Any train step model where one process both builds and
  uploads breaks this. **This is a hard constraint on the design, not a
  preference.**
- **Per-step credential narrowing stays**, for the same reason the train spawns
  `cux_ship` instead of importing it ([release-train.md](release-train.md) §2):
  `secrets exec --keystore upload --api-key upload`, `keychain exec --only
  ssh_keys.github_deploy`.
- **The notarized macOS zip stays local.** Notarizing needs a *team* App Store
  Connect key and is deliberately off CI (`authpass/README.md:58`). It is a
  named-and-waited step forever.

## 5. What to pull into the train

In order of value per unit of work.

1. **A step model that survives being split across CI jobs.** This is the
   central change and everything else waits on it. The train today is one
   process taking a `List<Platform>` and assuming it orders every destination;
   AuthPass's CI is jobs on different runners, and its Apple path is already two
   steps that pass state through a file. So each train step must be **resumable
   from its records** rather than from process memory. The records largely
   exist: upload records, `uploaded/` tags, and the manifest every flavor writes
   through `ship.sh manifest write`.
2. **Build-number allocation as a train step.** §3. `cux_buildnumber` is already
   a separate package for the right reason — allocating is a git operation a
   build does before it has an artifact — so this is ownership of the *call*,
   not new code.
3. **A destination the train names and waits on.** The genuinely new concept,
   and the one that covers sixteen of twenty steps. It needs a declared list of
   destinations, a state per destination (pending / done / not applicable), and
   somewhere durable to keep it. The promotion-record work on the first
   consumer's side is the precedent for the recording half.
4. **The manifest as the build's receipt.** Every flavor but `web` already
   writes one, and `web` says why it does not. The train should read those
   rather than re-derive what was built.
5. **The preflight gate.** The hook shape is already generic: a gate fired
   before work, scope in the environment, exit code as the verdict, problems
   filed on a channel. AuthPass gets a `ready` of its own without the train
   knowing anything app-specific.

**And what not to pull:**

- **The pinned terminal block.** §9 settles this and the second consumer is why:
  1,399 of the reads stage's 4,359 lines are pinned-terminal presentation, every
  AuthPass upload runs on a GitHub runner with no TTY, and all of it degrades to
  null off a terminal. AuthPass would use none of it.
- **`StoreReads` and `status`.** §7's surviving objection: the set needs a
  `4.5.0-dev` pin two majors above AuthPass's `^3.6.0` (*read* at
  `authpass/_tools/cux_ship/pubspec.yaml:32`), and `status` does not answer the
  question AuthPass's guards ask — they ask whether the number about to go up
  beats the store's newest, via `play version-code` and `appstore build-number`,
  neither of which is in `StoreReads`.
- **`upload-artifact.sh`, `github-release.sh`, `fosshub-release.sh`,
  `appcast.generate.sh`.** One consumer each. Name them as steps; leave them
  owned by AuthPass.

## 6. Staging

1. **Ordering, in `cux_train`.** The step model and named-and-waited
   destinations, no store writes at all. AuthPass gets the order, the state and
   the preflight with nothing in its CI moved. This is the stage §7 puts first
   and it needs no SDK move — the donor's `^3.13.0` was incidental and
   `cux_train` declares `^3.12.2`.
2. **Centralize the build number.** The train allocates; the six cells take
   `FORCE_BUILDNUMBER`. Decide §3's `fail-fast` question here.
3. **Re-parent the five automated steps** under train steps. They already call
   `cux_ship`.
4. **Reads — blocked, and not by this document.** It waits on `cux_ship` 4.5.0
   going stable or AuthPass pinning a prerelease, and on whether AuthPass wants
   a human-facing `status` at all.

## 7. Risks and what is still open

- **`fail-fast: true` against a single build number.** §3. Unanswered.
- **The Apple split constrains the step model.** §4. A design that has the train
  process build *and* upload is excluded, and that is the design the first
  consumer has.
- **Whether AuthPass's pre-upload guards survive.** If the train allocates one
  number per release, the guards' question changes shape; their failure policy is
  also the opposite of the train's — they swallow an unreadable store and are
  escapable by an environment variable, while a read that throws lands in
  `StatusReport.failed` and exits non-zero.
- **A comment in `release.sh` is wrong, and it matters here if the train ever
  reads CI step outputs.** `release.sh:58` says GitHub disabled `::set-output`
  in 2023 "so the line below that still uses it has been doing nothing for a
  while". *Measured* 12 November 2026 on run `43219160509`: the `sideload`
  cell's `upload artifact` step is gated on
  `steps.buildapk.outputs.outputfilename != null` and **ran**, so the output was
  set. The `playstoredev` cell skipped it, but for the other reason — that branch
  of `release.sh` sets no `outputfilename` at all. Whatever the intent of the
  comment, any plan that treats step outputs as dead is planning against the
  wrong facts.
