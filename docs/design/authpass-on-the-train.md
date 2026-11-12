# AuthPass on the release train — an integration plan

Status: **proposed**, 12 November 2026. Answers the open bullet in
[release-train.md](release-train.md) §9 — *"does the train replace AuthPass's
build matrix, run inside one cell, or watch it?"* — together with the
maintainer's own framing of the goal:

> where I can use train.sh the same way in authpass as in cycling_storyteller
> … but still having authpass distribute in all it's channels

and, earlier in the same conversation:

> for everything which is supported by train.. it should be replaced.. but
> f-droid, etc. can't be replaced

Research and design only; nothing in any of the three checkouts was modified.

**This supersedes PR #88, which was closed unmerged.** That document answered
the shape question and not the parity one, and its central claim was false: it
said AuthPass's six Android matrix cells each allocate their own build number,
so one release burned six and its artifacts disagreed. They do not — §2 has the
evidence, three independent ways. Everything #88 built on that claim went with
it: its headline, its second stage, and one of its risks. An adversarial review
found five further blocking defects, of which the sharpest was that §88's own
diagram violated the hard constraint it declared two sections later, by leaving
the Android cells "unchanged" while re-parenting Play uploads that run *inside*
those cells' build process. The plan below cannot have that defect, because the
train never enters a CI cell at all (§5). #88's three findings worth keeping are
folded into §2.

**One disclosure about independence.** I did read
`docs/design/release-train.md` on `cux_ship`'s `origin/main` before designing,
because it defines what `cux_train` is meant to become. Its §8 already
proposes a "manual destination". So that idea is inherited, not mine; what is
mine is how far I take it (§1), the evidence model (§6), the role split (§5)
and the staging (§8).

Throughout: **[V]** = verified by reading the file or running a read-only git
command today; **[A]** = my argument; **[?]** = not verified, and I say what
would settle it.

---

## 1. The thesis in four sentences

1. **Parity is reached on day one by declaring every AuthPass release step a
   destination, and letting most of them start as `manual`** — exactly what the
   README checklist is today — so the five verbs and the flags mean the same
   thing in both repositories before a single step is automated. [A]
2. **Automation then replaces `manual` one destination at a time, behind an
   unchanged command.** Play and the App Store flip to `cux_ship` promotes;
   snap, the artifact server, GitHub and FossHub flip to scripts AuthPass
   already has; the consoles with no API and F-Droid never flip. This is the
   owner's own rule ("everything supported by train is replaced; f-droid etc.
   can't be") expressed as a property of a table rather than of a migration. [A]
3. **`tool/train.sh` runs on the maintainer's machine and nowhere else.** CI
   cells keep running *steps* (`release.sh` via `ci-release.sh`); the train is
   what orders steps across jobs, and only something outside the jobs can see
   across them. The Apple `RELEASE_PHASE` split is therefore not touched at
   all, rather than "preserved". [A]
4. **The train must become resumable and must distinguish what it observed
   from what it was told**, because an AuthPass `production` spans days and
   half its destinations can only be attested by a person. Those two properties
   are the real new work in `cux_train`; the rest is a table. [A]

---

## 2. What I verified, and what it changes

Only the facts the design rests on.

- **[V] The donor surface.** `tool/train/lib/src/options.dart`: stages
  `status|ready|internal|beta|production`; `--store` is validated against a
  four-row `storeTable` (`play`, `appstore`, `appstore:ios`, `appstore:macos`);
  a bare invocation refuses; `--build` is refused by `internal` and `status`;
  the bare `vX.Y.Z` tag is only spent when `isEveryStore`. The file's own
  comment already anticipates a second Android store and says of F-Droid that
  "releasing there is pushing [a tag]… no credential, no artifact, no track. A
  row in the table below can express that."
- **[V] The donor is five spawned scripts plus hooks.** `bin/train.dart`
  requires `ship`, `build.sh`, `upload.sh`, `promote.sh`, `finish.sh` beside
  it and regex-reads a `--only tokens.…` list out of `build.sh`. AuthPass has
  none of the last four by those names.
- **[V] The donor's record is git tags.** `uploaded/v{version}+{build}` written
  by `cux_ship` at upload, `promoted/<store>/<track>/v{version}+{build}`
  written by `tool/record-promotion.sh` (donor-local shell) from the `post-*`
  hooks, and that script's header says it is also run "by hand for promotions
  done in a store console".
- **[V] AuthPass already writes `uploaded/` tags** (`.cux-ship.yaml`:
  `tag.upload.enabled: true`; newest in the main checkout is
  `uploaded/v1.9.13+2217`). It writes **no** `promoted/` tags.
- **[V] One build number per commit, across every CI cell.** So although a
  dozen jobs each call `ship.sh buildnumber generate`, one release commit has
  one number, and `--build N` means in AuthPass what it means in the donor.
  This is what makes one grid over twelve artifacts coherent. **It is also what
  PR #88 got wrong**, so it is worth having three ways rather than one:

  1. **The allocator is commit-keyed.** `cux_buildnumber/lib/src/tool.dart`'s
     `_generateOrGet` returns the commit's existing number — local note first,
     then after a `_fetch()` — *before* it will allocate. On a lost push it
     refetches and takes the winner's note for that commit, which is what its
     "Another allocation won the race" retry resolves to. Concurrent cells
     therefore converge rather than each claiming a number.
  2. **The allocation log agrees, over sixty-six allocations.** In AuthPass's
     `refs/buildnumbers/commits`, 66 entries carry a built commit as a second
     parent, across 66 **distinct** commits, and no commit appears twice:

     ```
     git log --first-parent --format='%P' refs/buildnumbers/commits \
       | awk 'NF>=2 {print $2}' | sort | uniq -c | awk '$1>1' | wc -l
     → 0
     ```
  3. **A shipped release says so.** `authpass/README.md:71`–`:74` lists one
     release's GitHub assets — `AuthPass-setup-1.7.7_1519.exe`,
     `authpass-sideload-1519.apk`, `AuthPass.app-1.7.7-b1519.zip`,
     `authpass-linux-1.7.7_1519.tar.gz`. Four artifacts, three workflows, one
     build number.

  The corollary matters for §5: because the number is a property of the commit,
  the train needs no step *before* the matrix to allocate one, and `fail-fast`
  costs no numbers.
- **[V] AuthPass's release is branch-triggered.** Pushing `stable` fires
  `main.yml` (six Android flavors), `ios.yaml` (ios, macos), `linux.yml`
  (tar.gz, snap → `edge`), `windows.yaml` (setup exe, msix, portable zip),
  `web-gh-pages.yaml`; `make_deb.yaml` chains off the linux workflow and pushes
  to packagecloud. `playstore` goes to Play's **internal** track only;
  `release.sh` contains no promote and nothing in `_tools/` or the workflows
  calls `play promote`, `appstore promote`, `appstore beta-release` or
  `release finish` (grepped).
- **[V] Three channels are public the moment `stable` is pushed**, with no
  later gate: the web app (`peaceiris/actions-gh-pages` to `web.authpass.app`),
  the `.deb` on packagecloud (`make_deb.yaml`), and snap `edge`.
- **[V] The Apple split is a process property, not only a step property.**
  `ios.yaml` gives *both* steps `SOPS_AGE_KEY`; what keeps the key from
  xcodebuild is `keychain exec --only ssh_keys.github_deploy`, which strips it
  from the child. The upload is a sibling step that decrypts for itself.
- **[V] Two App Store app records, two Play packages.** iOS is
  `design.codeux.authpass.ios` (`upload-ios.sh`); macOS is a different record
  (`release-train.md` §5.2 quoting `upload-macos.sh`); `playstoredev` is
  `design.codeux.authpass.dev`, "a separate listing, not a track".
- **[V] The macOS direct download is local on purpose** (`notarize-macos.sh`
  header: team key in `~/.appstoreconnect`, "DELIBERATELY NOT PART OF CI").
- **[V] A Dart child with inherited stdio dies on the Windows runner**
  (`ship.sh`'s `buildnumber` block works around it with temp files). The train
  spawns everything with inherited or piped stdio. This matters in §5.
- **[V] The checklist drifts when nobody orders it.** In the main checkout the
  newest bare release tag is `v1.9.11` and the newest `fdroid-v` tag is
  `fdroid-v1.9.10`, while `uploaded/v1.9.12+…` and `uploaded/v1.9.13+…` exist
  and `origin/stable` is at "prepare 1.9.13". **[?]** I cannot tell from git
  whether 1.9.12 reached every console and merely went untagged, or was never
  finished — and *that I cannot tell* is the argument for a record.
- **[V] `cux_ship` 3.6.0 already has** `play promote`, `appstore promote`,
  `appstore beta-release`, `release finish`, `play version-code`,
  `appstore build-number`. **It does not have** the `--json` reads the donor's
  `status` is built on (4.1.0 onward; the donor pins `4.5.0-dev.8`). 4.0.0's
  one loud CLI break is `--data-safety`, which AuthPass does not pass (grepped
  `_tools/`).
- **[V] `cux_train` on `origin/main` is an entry point and a usage text**,
  `sdk: ^3.12.2`, no dependency on `cux_ship` yet.

Three findings inherited from the superseded #88, kept because they are right
and because two of them bear on the evidence model in §6:

- **[V] AuthPass's pre-upload guards fail *open*, and the train's reads fail
  *closed*.** `upload-android.sh:74`–`:84` asks `cux_ship play version-code`
  with `2>/dev/null` and then guards on `[ -n "$NEWEST" ]`, so a store it
  cannot read lets the upload through; it is also escapable with
  `AUTHPASS_ALLOW_REUSED_BUILD_NUMBER=1`. `upload-macos.sh:77` is the same
  shape. The donor's opposite convention — a read that throws lands in
  `StatusReport.failed` and makes the command exit non-zero — is why §6 keeps
  *pending* distinct from *observed* rather than treating an unanswered read as
  a pass. The two policies must not be merged by accident during step 2.
- **[V] `::set-output` still works, so CI step outputs are not a dead channel.**
  `release.sh:58`–`:60` says GitHub disabled it in 2023 and that the remaining
  line "has been doing nothing for a while". Measured on run `43219160509`: the
  `sideload` cell's `upload artifact` step is gated on
  `steps.buildapk.outputs.outputfilename != null` and **ran**. The
  `playstoredev` cell skipped it for an unrelated reason — that branch of
  `release.sh` sets no `outputfilename` at all. GitHub's annotation on both jobs
  reads "will be disabled soon", i.e. not yet. Anything here that treats step
  outputs as unavailable would be planning against the wrong facts; the comment
  in `release.sh` is AuthPass's to correct.
- **[A] Resumability is the central new capability**, not one feature among
  several. #88 ranked it first and that ranking is right: thesis 4 above and the
  whole of `production` in §3 depend on it, and nothing else in `cux_train`
  is hard in the same way.

---

## 3. What each verb means in AuthPass

The donor's definition is by **audience**: the stage word names who has the
build afterwards. I keep that definition and do not bend it. Where AuthPass has
no such audience for a destination, the destination has no step at that stage
and the train says so in the grid — it never invents one.

### The destination table

Names are proposals. "Built" is where the artifact comes from today.

| destination | artifact | built | `internal` | `beta` | `production` | can be read? |
|---|---|---|---|---|---|---|
| `play` | aab, flavor `playstore` | CI | uploaded to Play internal track | `play promote --to beta` | `play promote` | yes (API) |
| `appstore:ios` | ipa | CI, 2 steps | uploaded to TestFlight | `appstore beta-release --beta-group` | `appstore promote` | yes (API) |
| `appstore:macos` | pkg | CI, 2 steps | uploaded to TestFlight | same | `appstore promote`, other bundle id | yes (API) |
| `amazon` | apk, amazon keystore | CI | on artifact server | **none** | **manual** console | no |
| `samsung` | apk | CI | on artifact server | **none** | **manual** console | no |
| `huawei` | apk | CI | on artifact server | **none** | **manual** console | no |
| `microsoft` | msix | CI (windows) | on artifact server | **none** | **manual** Partner Center | no |
| `direct:android` | sideload apk | CI | on artifact server | **none** | script: `stable.txt` + `update_stable.sh` | yes (public URL) |
| `direct:windows` | setup exe, portable zip | CI (windows) | on artifact server | **none** | same script, plus appcast | yes |
| `direct:linux` | tar.gz, deb | CI | on artifact server | **none** | same script | yes |
| `direct:macos` | notarized zip | **laptop** | local build + notarize + `upload-artifact.sh` | **none** | same script | yes |
| `github` | the above, re-hosted | — | none | none | script: `github-release.sh` | yes (API) |
| `fosshub` | the above, re-hosted | — | none | none | script: `fosshub-release.sh` | [?] |
| `snap` | snap | CI | **already on `edge`** | none today (a `beta` channel exists and is unused) | manual today; `snapcraft release … stable` is scriptable | yes (public API) [?] |
| `packagecloud` | deb | CI (`make_deb`) | **already public** | — | nothing left to do | [?] |
| `ppa` | deb source | other repo, docker | none | none | **manual**: two `docker-compose run` lines in `authpass-deb` | yes (Launchpad) [?] |
| `flathub` | — | Flathub's bot | none | none | **observe only** | yes (public API) [?] |
| `fdroid` | — | F-Droid, from source | none | none | push `fdroid-vX.Y.Z`, update `fdroid-version.txt` | yes (f-droid.org index) [?] |
| `web` | gh-pages | CI | **already public** | — | nothing left to do | yes (it is a URL) |

`playstoredev` is deliberately **not a destination**. It is a nightly listing
fed by every `main` push, not a stage of a release; it stays in `main.yml` and
the train never mentions it. [A]

The four [?] in the last column are "I believe a public read endpoint exists
and did not call one" — I made no network requests. Each is settled by one
`curl` the owner can run; none of them is load-bearing, because a destination
that turns out unreadable simply becomes *attested* (§6).

### `status`

Reads, writes nothing. One row per destination, one column per audience, each
cell a build number **with its evidence class** (§6): observed from the
destination, recorded in git, or unknown. Clean mapping. The only difference
from the donor is that the grid is taller and that most cells are records, and
the grid has to say which is which rather than render both the same way.

### `ready`

"Could `production` run, and what is missing." Clean mapping, and **this is
where AuthPass gains the most**, because "wait for github builds" in the README
is exactly a readiness question nobody can currently ask. For build N:

- the `pre-release` hook (AuthPass's own: CHANGELOG has a section for the
  version; the F-Droid changelog file exists; `store/appstore/` verifies);
- every CI-built destination has its artifact for N — on the artifact server
  with its `.manifest.json`, or in the store — one row per missing one;
- `direct:macos` exists (the step people forget, because CI does not do it);
- for `--build N`, the `uploaded/` record names one commit.

### `internal`

Donor meaning: *build and upload everywhere; testers have it; no review.*

AuthPass meaning: **the same, with the building done by CI.** Concretely, on
the laptop:

1. `pre-build` hook (gate) — refuses before anything is spent.
2. Dispatch: `git push origin HEAD:stable`, behind the confirmation `--yes`
   skips. This is README step 2, typed by the train.
3. In parallel: the one local step, `direct:macos` (build-macos → notarize →
   upload-artifact), which needs the laptop's team key anyway.
4. Wait, one grid row per destination, until each has its artifact for the
   allocated number or its CI job has failed. A failed cell is reported and
   does not stop the others — the donor's own rule ("a store refusing does not
   stop the others").

**Where this is not honest, and the train must say so:** for `web`,
`packagecloud` and (arguably) `snap`, `internal` reaches the public. That is a
fact about today's workflows, not something the train causes, but a command
whose help says "testers have it, no review" must not hide it. The grid marks
these `public at internal`, and the confirmation prompt before the push names
them. Moving those three behind `production` is possible later (trigger them by
`workflow_dispatch` from the production stage) and is **a CI change the owner
has to want**; this plan does not assume it.

### `beta`

Donor meaning: *the same build, to public testers.*

**Honest for exactly three destinations**: `play` (internal → beta track),
`appstore:ios`, `appstore:macos` (external TestFlight group — the capability
`cux_ship` 3.5.0 added and AuthPass pinned for, per its own pubspec comment,
but which nothing calls yet).

**No honest meaning for the other sixteen.** Amazon, Samsung, Huawei and the
Microsoft Store have no "public tester" audience AuthPass uses; a direct
download has no audience tiers at all; F-Droid and Flathub are not ours to
stage. `train.sh beta` therefore acts on three rows and prints the rest as
`— no beta audience`, and `--store amazon beta` **refuses by name** ("amazon
has no beta stage; its only promotion is production"), which is the donor's
rule that a flag that would do nothing is refused rather than dropped.

`snap` could have one (`edge` → `beta`), and I would **not** add it: nobody
uses it today and inventing an audience to fill a cell is the thing the brief
warns against.

**A naming collision the owner has to resolve.** AuthPass has a `beta`
*branch* that triggers builds of a *different commit* to TestFlight and to
`playstoredev`'s beta track. The train's `beta` promotes the *same build*
`internal` uploaded. These are different ideas with one name. My
recommendation is to leave the branch alone through every stage of this plan
and decide afterwards whether it still earns its keep; the train never pushes
it. [A, and unresolved]

### `production`

Donor meaning: *the same build, to users; then finish.*

AuthPass meaning: the README's "Submit release to" list plus everything after
"create tag", in one ordered, **resumable** run:

1. gates: `pre-release` hook, and `release finish --dry-run` first (the donor's
   placement: refuse "wrong branch" while it is still free);
2. API destinations: `play promote`, `appstore promote` ×2;
3. script destinations: `stable.txt`/`update_stable.sh`/appcast, GitHub
   release, FossHub, snap → stable;
4. manual destinations, one at a time: Amazon, Samsung, Huawei, Microsoft, PPA
   (§6 says what the operator sees);
5. finish, **only when every destination is recorded**: `vX.Y.Z` via
   `cux_ship release finish`, then the `fdroid` destination's step — push
   `fdroid-vX.Y.Z` and update `fdroid-version.txt`.

Two things differ from the donor and both are real:

- **It cannot be one sitting.** Review queues and console uploads take days. A
  re-run must skip what is recorded and pick up at the first destination that
  is not. The donor has no such notion — its `production` is three API calls.
- **"Production" for a manual destination means *handed over*, not *live*.**
  The record says the operator submitted it. `status` can only upgrade that to
  *live* where the destination can be read. The grid must not render
  "submitted to Huawei" and "Play production holds 2217" identically.

### Flags

`--build`, `--dry-run`, `--yes`, `--verbose` carry over unchanged. `--rollout`
stays Play-only, `--phased`, `--hold`, `--prepare` stay App-Store-only, and are
refused by name for any other destination, as the donor already refuses
`--prepare` for Play. **No new flag is needed for the normal path.** I
considered `--resume` and rejected it: resuming is what a re-run *is* when
state is recorded, and the donor's rule is that the ordinary path takes no
flag. [A]

---

## 4. What `--store` becomes

**It stays one flag, it stays `--store`, and its values become the
consumer's declared destinations instead of a hardcoded four-row map.** [A]

- The four donor names keep their exact meaning, so `--store play` and
  `--store appstore:ios` are typed identically in both repositories. That is
  the parity that matters.
- The `family:member` colon form the donor already uses for `appstore:ios`
  generalizes: `--store direct` is all four direct downloads, `--store
  direct:macos` is one. No new syntax.
- The default remains "every destination", and `isEveryStore` — the condition
  for spending the bare version tag — becomes "every declared destination is
  recorded at production". That is the finish rule AuthPass needs anyway.
- A platform name is still refused by name. With six Android destinations the
  donor's message ("Android has one store today and will not always") has come
  true.

The word "store" is slightly wrong for `direct`, `web` and `github`. I would
keep it rather than add `--destination` as an alias: two spellings of one flag
across two repositories is the opposite of what was asked for. [A]

**Where the table lives:** a `train:` block in `.cux-ship.yaml` at the
repository root, beside `app-dir` and `tag`, because `repo.dart` already
parses that file and because the `uploaded/` namespace it must agree with is
declared there. **[?]** `cux_ship` may reject unknown top-level keys in that
file; if it does, a sibling `.cux-train.yaml`. One read of `cux_ship`'s config
loader settles it.

A destination row declares, per stage, one of four **step kinds**:

| kind | who acts | examples in AuthPass |
|---|---|---|
| `ship` | the train spawns `cux_ship` through the consumer's shim | play, appstore |
| `run` | the train spawns a consumer script | artifact-server stable, github, fosshub, direct:macos |
| `manual` | a person; the train instructs, waits, records | amazon, samsung, huawei, microsoft, ppa |
| `none` | nobody | every "no beta audience" cell; flathub everywhere |

plus an optional `read` (a `ship` read or a consumer script printing one small
JSON document) and identity (`package`, `bundle-id`) per destination, which is
what fixes the donor's singular `appleBundleId`/`playPackageName` for a
repository with two of each.

---

## 5. One process and three operating systems

**The train runs on the maintainer's laptop, as the conductor, and in no CI
cell.** [A] Not "both roles with different scopes". The reasons, in order of
weight:

1. **There is nothing to order inside a cell.** Every AuthPass CI cell is one
   destination: build one artifact, put it one place. The train's entire
   contribution — order across destinations, the same build promoted onward,
   one report — is a property of the *set* of jobs. Running it inside one adds
   a process layer and no behaviour.
2. **It leaves the Apple split untouched rather than re-deriving it.** The
   donor does reproduce the guarantee structurally (build under `keychain
   exec`, upload as a sibling under `secrets exec --only`), so a train in the
   macOS cell would *probably* be equivalent. "Probably equivalent" is the
   wrong standard for the one property the owner has said he will not give up,
   and a `--phase build|upload` flag to make it exact would be a surface the
   donor does not have — a parity break in the wrong direction.
3. **It cannot run on the Windows runner today.** [V, from `ship.sh`] A Dart
   child of a Dart parent with inherited stdio dies there; the train is a Dart
   parent that spawns Dart children.
4. **`fail-fast: true` and the matrix stay exactly as they are**, because the
   train never sees them. It sees a commit, a build number, and whether each
   destination's artifact arrived.
5. **The laptop is already in the release.** Notarizing, the GitHub release,
   FossHub and five consoles happen there now.

So the reconciliation is: **CI is one executor of the `internal` stage's
build-and-upload step, for most destinations.** The donor's `internal` spawns
`build.sh` then `upload.sh` per platform. AuthPass's `internal` spawns one
dispatch (the push) and then *waits on evidence* per destination, while running
the single local build beside it. The donor's two-lane structure survives as
"remote lane" and "local lane".

**How the train knows a remote destination finished** — in decreasing order of
how much I trust it:

- the destination itself holds build N (store read, or the artifact URL
  answers) — *observed*;
- the artifact's `.manifest.json` on the artifact server names N and the
  commit — *observed*, and already written for every artifact except web [V];
- the CI job concluded successfully (`gh run list --commit`) — a *claim*, used
  for progress and for failure, never as the final evidence.

The `uploaded/` tag is deliberately **not** on that list for per-destination
evidence: it is one tag per commit, first store wins [V, `.cux-ship.yaml`], so
it proves somebody uploaded and not who. `release-train.md` §8 says the same.

**What I am unsure of here.** The manifest sidecar upload is currently a
*tolerated failure* in `upload-artifact.sh` because the server's allow-list
does not admit `*.manifest.json` yet [V, the script's own comment]. If that is
still true, the best evidence above does not exist on the server and the wait
falls back to "the artifact filename for N answers 200", which is adequate
(filenames embed `{version}_{build}`) but weaker. Fixing the allow-list is a
small server-side change in `authpass-cloud` and worth doing first.

**The dispatch needs `gh` only for progress**, not for correctness, so the
train works without it and says "no CI progress — waiting on the artifacts
alone".

---

## 6. Channels with no API

They participate as first-class rows. The mechanism is three things.

### 6.1 A manual step is an instruction, a wait, and a record

When `production` reaches a `manual` destination the operator sees, for
example:

```
── huawei · production · build 2217 ────────────────────────────────────
  upload   authpass-huawei-1.9.13_2217.apk
           https://data.authpass.app/data/artifacts/authpass-huawei-1.9.13_2217.apk
           sha256 3f9c…  (from its manifest)
  where    https://developer.huawei.com/consumer/en/service/josp/agc/index.html
  notes    CHANGELOG.md § 1.9.13, rendered for this store — copied to the clipboard

  [d]one   [s]kip for now   [q]uit — nothing after this is lost
```

- **Instruction**: the exact artifact (name, URL, digest from the manifest),
  the console URL from the README, and the release notes already rendered —
  three things the operator currently assembles by hand, per console.
- **Wait**: `d` records and moves on; `s` leaves it unrecorded so the next run
  stops here again; `q` ends the run with everything so far kept.
- **Record**: `promoted/huawei/production/v1.9.13+2217`, the donor's existing
  tag shape, pushed. That one tag is what makes the run resumable, what
  `status` shows next week, and what the finish rule counts.

`--yes` must **not** auto-confirm a manual step. `--yes` means "do not ask me
before doing what you were going to do"; a manual step is not something the
train does. Off a terminal, a manual destination is reported as pending and
the run exits non-zero having done everything else. [A]

`--dry-run` prints every instruction and records nothing — which is the README
checklist, generated for this build, and is useful by itself.

### 6.2 Observed and attested are different cells

Every cell in `status` carries one of:

| mark | meaning | example |
|---|---|---|
| observed | the destination was read and holds this build | Play production, snap stable, F-Droid index |
| attested | a `promoted/` tag says a person or script did it | Huawei, Amazon, PPA |
| pending | neither | |
| n/a | this destination has no such stage | every non-store `beta` cell |

Where both exist and **disagree** — a tag says snap stable is 2217, the snap
API says 2196 — that is the most valuable line the tool can print, and `ready`
lists it as a problem. Where only attestation exists, the grid says so in the
cell and never promotes it to "holds".

### 6.3 F-Droid, Flathub: nobody here acts

- **F-Droid** has a `production` step that is not an upload: the gate checks
  the changelog file is committed, and the step pushes `fdroid-vX.Y.Z` and
  updates `fdroid-version.txt`. Afterwards it is `attested` until the F-Droid
  index shows the version, then `observed`. The train can never make F-Droid
  build; it can make sure the tag was not forgotten, which per §2 it has been.
  **[?]** F-Droid's changelog files are named by a versionCode around 160 while
  build numbers are around 2217, and `pubspec.yaml` on the main checkout reads
  `1.9.12+166` — so I infer F-Droid's versionCode is the pubspec's `+N`, not
  the git build number. I did not confirm that against `fdroiddata`. The
  `fdroid` row needs the right number and I do not know it for certain.
- **Flathub** is `none` at every stage with a `read`. It appears in `status`
  so that "should already be updated automatically daily — check" becomes a
  cell that is red when the bot did not run.

### 6.4 What is *not* dropped — the check

Every line of the README's "Releasing" section, against a row:

| README step | destination / mechanism |
|---|---|
| write CHANGELOG, F-Droid changelog | `pre-build` + `pre-release` hooks |
| push `stable`, wait for builds | `internal` dispatch + wait |
| macOS direct zip, local | `direct:macos`, `run`, laptop |
| tags `v…`, `fdroid-v…` | finish; `fdroid` step |
| `stable.txt`, `update_stable.sh`, `fdroid-version.txt` | `direct:*` production script; `fdroid` step |
| appcast | `direct:windows` production script |
| GitHub release | `github`, `run` |
| FossHub | `fosshub`, `run` |
| Play, App Store Connect | `play`, `appstore:*`, `ship` |
| Samsung, Huawei, Amazon, Microsoft | `manual` |
| PPA | `ppa`, `manual` |
| snap edge → stable | `snap`, `manual` then `run` |
| flathub check | `flathub`, read only |

Nothing is unassigned. Three things CI does that the README does not list are
also rows: `web`, `packagecloud`, and the snap `edge` publish.

---

## 7. What moves into `cux_train`, and what stays in AuthPass

Test applied to each: **would the donor, or a third consumer, want it?**

### Into `cux_train`

| what | why a second consumer wants it |
|---|---|
| The destination table and `--store` resolution over it (replacing `storeTable`, `StoreId`, `StoreSelection`) | The donor's own comment says a second Android store and F-Droid are rows. The donor becomes a three-row table and loses nothing. |
| Step kinds `ship` / `run` / `manual` / `none` | `manual` is useful to the donor too: its `record-promotion.sh` header already documents "by hand for promotions done in a store console". |
| **The promotion record** — writing and reading `promoted/<dest>/<stage>/v…+N` | Today it is donor-local shell called from hooks. Once resumability and the finish rule depend on it, it is core state, not an app's side effect. Whether the *writer* belongs in `cux_train` or as a `cux_ship release record` command beside `release finish` is a fair question; I lean `cux_ship`, since it already owns `uploaded/` and the tag namespace config. [A] |
| Resumable `production`; the finish rule "every declared destination recorded" | The donor gets it for free and it closes its own "narrowed with `--store`, so not finishing — run finish.sh by hand" note. |
| Evidence classes in the grid (observed / attested / pending / n/a) | Any consumer with one unreadable destination needs it. |
| Per-destination identity (bundle id, package) | AuthPass forces it; the donor is the degenerate case. |
| The hook contract (already generic) with `HOOK_STORES` carrying destination names | Unchanged shape. |
| A `wait`-on-evidence step: poll a destination's `read` until it holds build N or times out | This is the generic half of "CI builds it". The donor's `appstore wait` is the same idea for one store. |
| Not requiring `build.sh`/`upload.sh`/`promote.sh`/`finish.sh` by name; not regex-reading `build.sh` | Already called out as a defect in `release-train.md` §5. A consumer whose `internal` is a dispatch has no `build.sh`. |

### Deliberately staying in AuthPass

| what | why not shared |
|---|---|
| The dispatch itself (`git push origin HEAD:stable`) and reading `gh` for progress | Which ref triggers which workflow is this repository's CI design. A `run` script. If a third consumer turns up dispatching to CI, promote it then — one example is not a pattern. |
| `release.sh`, `ci-release.sh`, every workflow, `RELEASE_PHASE` | Steps, not ordering. Untouched by every stage of this plan. |
| Artifact-server knowledge: `artifact.push`, `stable.txt`, `update_stable.sh`, appcast, filename patterns | One server, one owner. `run` and `read` scripts. |
| `github-release.sh`, `fosshub-release.sh`, the snap release, the PPA lines | Same. |
| Console URLs and per-console instructions | Data in AuthPass's table. |
| The F-Droid tag and `fdroid-version.txt` | A `run` script. "Push a tag as a release" *might* be generic (the donor's comment imagines it) but AuthPass's also edits a file on a server. |
| `pre-build` / `pre-release` hook bodies | By construction. |
| The notary key path and `notarize-macos.sh` | Out-of-band credential; the train must never learn where it is. |

### Explicitly *not* in either, yet

Amazon, Huawei, Samsung and Microsoft all publish submission APIs. [?, from
general knowledge, not checked today] Writing clients for them in `cux_ship`
would turn four `manual` rows into `ship` rows. That is a separate project with
its own review burden; this plan makes it *possible* (flip the row's kind) and
does not ask for it.

---

## 8. Staging, and the smallest first step

### Step 1 — the smallest thing that is real

> **`tool/train.sh status` and `tool/train.sh production --dry-run` in
> AuthPass, on the laptop, with every destination declared and none
> automated.**

What exists after it:

- `tool/train.sh` at AuthPass's **git root** — the same path typed in both
  repositories, and the root is where `CHANGELOG.md`, `.cux-ship.yaml` and
  `store/` already live. A launcher of a few lines.
- The destination table of §3, every production step `manual` or `none` —
  *including Play and the App Store*, which are console steps today.
- `status`: a grid built from `uploaded/` and `promoted/` tags plus the reads
  that need no credential (artifact server URLs). Mostly `pending` on day one;
  that is honest.
- `production --dry-run`: the README checklist, generated for the newest
  recorded build, with artifact names, URLs and consoles filled in.
- `production` for real: walks the manual steps and records each. **The
  release is performed exactly as today — by hand — but ordered, resumable and
  recorded.**

Why this and not something smaller: anything less leaves no record, and the
record is what every later stage is built on. Why not something larger: it
dispatches nothing, promotes nothing through an API, and holds no credential.

**It does not touch working CI**, in the strict sense:

- no workflow file changes;
- `release.sh`, `ci-release.sh`, `ship.sh` unchanged;
- **the `cux_ship: ^3.6.0` pin is unchanged**, because step 1 calls no
  `--json` read. To keep it unchanged the train resolves from its own wrapper
  (`authpass/_tools/cux_train/pubspec.yaml`), which CI never resolves.

That last point is **a second pin, and I am recommending it knowingly** against
this codebase's well-argued dislike of two pins. The justification is narrow:
step 1's `cux_train` spawns `cux_ship` zero times, so the two cannot disagree
about anything. The exit condition is written into the wrapper: the day a
`ship`-kind step or a `--json` read is switched on, the two wrappers merge
into one. If the owner would rather not carry it even briefly, the alternative
is to bump AuthPass to `cux_ship` 4.x first, which *is* a CI change. [A]

**The honest cost of step 1 is in `cux_ship`, not AuthPass.** `cux_train` is
empty. Step 1 needs from it: the table, `--store` over it, the `manual` kind,
the record (write + read), `status` from the record, and resumable
`production`. That is new code plus the donor's `options.dart`, `hooks.dart`,
`summary.dart` and the presentation files — and none of the donor's
`status.dart` reads or `train.dart` lanes. It agrees with `release-train.md`'s
conclusion that the *ordering* stage is the one with a consumer.

### Step 2 — `ready`, and the reads

Adds per-destination reads and the `ready` verdict: every artifact for N
present, CHANGELOG and F-Droid changelog in place, attestation and observation
agree. Needs the `--json` reads for Play and the App Store, therefore
`cux_ship` ≥ 4.1 and — to match the donor's `status` — a 4.5.0 release. **This
is the step that moves AuthPass's pin and merges the two wrappers**, as its own
change, verified on a `main` push (which exercises `playstoredev`) before any
`stable` push. I would wait for a stable `4.5.0` rather than pin a `-dev`
release in a repository whose CI ships to stores. [A]

### Step 3 — flip the API destinations

`play` and `appstore:*` go from `manual` to `ship` for `production`, and
`beta` gains its three real rows. This is where the owner's "everything
supported by train should be replaced" lands: two consoles leave the checklist.
`--rollout`, `--phased`, `--hold`, `--prepare` start meaning something. First
run under `--dry-run`; the `appstore promote` default of publishing the
listing tree needs a decision for AuthPass, whose uploaders pass
`--no-metadata` today on purpose. [V that they pass it; A that it needs
deciding]

### Step 4 — flip the script destinations

`direct:*`, `github`, `fosshub`, `snap` from `manual` to `run`, one at a time,
each wrapping a script that already exists or a few lines of `ssh`.
`github-release.sh` reads `~/.authpass_github_api_token` and needs a draft
release to exist; the train's `run` step should create the draft, which is the
one place a script changes rather than being wrapped.

### Step 5 — `internal`

The dispatch and the evidence wait, with `direct:macos` as the local lane.
Last, because it is the only step that pushes a branch CI reacts to, and by
then `ready` (step 2) can already say whether a manual push produced
everything — so step 5 automates a wait that is already checkable.

### Never

`release.sh` moving into the train; the train in a CI cell; the Apple step
split changing; F-Droid, Flathub, the PPA or the four consoles being "handled"
by anything but a person and a record.

---

## 9. What I could not resolve

1. **The `beta` branch versus the `beta` verb** (§3). Owner's decision.
2. **Whether `web`, `packagecloud` and snap `edge` should stay public at
   `internal`.** The plan reports it and does not change it.
3. **F-Droid's version number** (§6.3). Inferred, not confirmed.
4. **Whether the artifact server accepts manifests yet** (§5). Determines how
   strong the `internal` evidence is.
5. **Where the record writer lives** — `cux_train` or a `cux_ship release
   record` command (§7).
6. **Which read endpoints actually exist** for snap, Flathub, F-Droid,
   Launchpad, FossHub. I called none.
7. **"Submitted" versus "live" for manual stores.** One record state
   (*handed over*) is what I propose. A second attestation ("I saw it live")
   is easy to add and I am not sure it would be used.
8. **Is 1.9.12 actually finished?** I could not tell from git, which is the
   plan's own motivating example rather than a gap in it.
9. **Whether `.cux-ship.yaml` tolerates a `train:` key** (§4).
10. **Time.** I have not estimated the `cux_train` work in step 1. It is the
    bulk of the effort and it is in the repository another agent is working in.

---

## 10. Against PR #88, which this replaces

Read only after §1–9 were written; read from
`origin/claude/authpass-on-the-train` with `git show`. §1–9 above are unedited
since, apart from the three inherited findings added to §2 and the stronger
build-number evidence beside them.

**#88 was closed unmerged** on the strength of this section and of an
adversarial review that found five further blocking defects. This section is
kept rather than deleted, because the comparison is the record of why.

### Where we agree

- The ordering stage is the one to build first, and "a destination the train
  names and waits on" covers most of AuthPass's release. Both of us took this
  from `release-train.md` §8, so the agreement is weaker evidence than it
  looks.
- The matrix stays a matrix; the Apple split and the local notarization are
  hard constraints; F-Droid and Flathub are checked, never performed.
- `upload-artifact.sh`, `github-release.sh`, `fosshub-release.sh` and the
  appcast stay AuthPass's, named as steps.
- Reads wait on `cux_ship` 4.5.0.

### The difference that matters most: #88's central factual claim is wrong

#88 §3 is titled "the one change that pays for the work: allocate once", and
rests on: *"Six cells, six pushes, six numbers — so the Samsung APK, the
Amazon APK and the Play bundle of one release do not agree on what build they
are."* Its stage 2, its `fail-fast` risk, and its headline ("allocate one
build number instead of six") all follow from that sentence.

**It is false, and I checked three ways. [V]**

1. `cux_buildnumber/lib/src/tool.dart`, `_generateOrGet` (on `cux_ship`
   `origin/main`): it returns the commit's *existing* number — from the local
   note, then again after a fetch — before it allocates anything. The package
   README states the property outright: "Two hosts building the same SHA get
   the same answer."
2. AuthPass's own allocation chain (`refs/buildnumbers/commits` in the main
   checkout): one `buildnumber: N (increment) at commit <sha>` entry per
   commit, not six.
3. AuthPass's README names one release's artifacts from three different
   workflows on two operating systems with one number:
   `AuthPass-setup-1.7.7_1519.exe`, `authpass-sideload-1519.apk`,
   `authpass-linux-1.7.7_1519.tar.gz`. And all 21 `uploaded/` tags in the
   checkout sit on 21 distinct commits.

So the six cells already agree, the allocator already is the "allocate once"
mechanism, and #88's stage 2 (`FORCE_BUILDNUMBER` into every cell) would
replace a working distributed guarantee with a central one that needs a new
way to hand a number to four workflows — a real CI change bought for nothing.
Its `fail-fast` dilemma ("a partial release at a number already spent") is
also already the state of the world and is harmless: the number belongs to the
commit, and a re-run of the failed cell gets the same one.

What *is* true in the neighbourhood, and may be what #88 saw: six cells race
to allocate for a fresh commit. The loop in `_generateOrGet` re-fetches and
adopts the winner's number; `cux_ship` 3.4.2's changelog entry mentions a
"same-commit tag race fix". That is a race the allocator resolves, not six
numbers. **[?]** I did not test the race; I read the code path.

**This should be corrected in #88 before it merges**, because the amendment it
makes to `release-train.md` §9 repeats the claim as the answer to an open
question ("the train runs before it to allocate **one** build number instead of
six").

### The second difference: where the train runs

#88: "the train brackets the matrix" — before it (allocate, preflight),
between its halves (it re-parents the uploads: "upload — train: the three
destinations with an API"), and after it. It does not say on which machine,
and its item 1 ("a step model that survives being split across CI jobs…
resumable from its records rather than from process memory") implies train
steps executing *inside* CI jobs.

Mine: the train is on the laptop only; CI runs steps, and the train observes
their results (§5).

I think mine is right for the first several stages and #88's is underspecified
rather than wrong. Three things #88's shape has to answer and does not:

- **A train step in the Windows cell** meets the Dart-child-stdio bug
  `ship.sh` works around. [V]
- **"Re-parent the uploads under train steps"** on the Apple path means the
  train process sits in the upload step. That is compatible with the split —
  but it buys nothing there, since the step already is one `cux_ship` call
  under one credential, and there is no neighbour for the train to order.
- **With allocation no longer needing a "before"** (above), the bracket loses
  its opening half. What remains is "after", which is my §5.

Where #88 is better than mine: resumability "from records rather than process
memory" is stated as *the* central change. I reach the same requirement in §3
(`production` spans days) but #88 is right to rank it first, and it applies to
`internal` as well, which I under-weighted.

### The third difference: command-surface parity is absent from #88

The owner's ask is "use train.sh the same way". #88 has no section on what
`status`, `ready`, `internal`, `beta`, `production` mean for AuthPass, nothing
on `--store`, and does not mention that `beta` has no meaning for sixteen
destinations or that AuthPass has a `beta` branch meaning something else. It
describes a train with phases `allocate / build / upload / name`, which is a
different vocabulary from the one being asked for. It also proposes **not
pulling `status`** ("whether AuthPass wants a human-facing `status` at all"),
which gives up one of the five words.

I think that is the larger gap of the two documents: #88 answers "what can
`cux_train` do for AuthPass's pipeline", not "how do I type the same command".
My §3 and §4 are the missing half. (It was written to answer §9's bullet, not
this brief, so this is a scope difference more than an error.)

### The fourth: `playstoredev`

#88 lists `playstoredev` as a destination the train replaces. I exclude it
(§3): it is fed by every `main` push and is a nightly listing, not a stage of a
release. Re-parenting it would put the train in the path of every merge to
`main`. I would hold my position.

### Where #88 found something I missed

- **`::set-output` still works.** #88 measured on a real run that the
  `sideload` cell's gated `upload artifact` step ran, so `release.sh`'s
  comment that the output "has been doing nothing for a while" is wrong. I
  read that comment and believed it. It does not change my design (I never
  read CI step outputs), but it is a correct finding and it bears on my §5:
  the artifact uploads I rely on as evidence do in fact happen.
- **The pre-upload guards** (`play version-code`, `appstore build-number`,
  fail-open, env-escapable) versus the train's fail-closed reads. I noted the
  commands exist at 3.6.0 and did not think about the policy mismatch. It
  matters at my step 3: when `play` flips to a `ship` step under the train,
  somebody has to decide which failure policy wins.
- **The manifest as the build's receipt** is stated as a principle. I use it as
  evidence in §5 and §6.1 without elevating it; #88's framing is cleaner.

### Where I think I may be wrong

- **The second pin in step 1** (§8). #88 does not need one because it never
  says where `cux_train` is resolved from. Mine is explicit and may be more
  ceremony than the owner wants for a transitional state.
- **Laptop-only may be too strict eventually.** If AuthPass later wants
  `internal` to be re-runnable per destination from CI's own "re-run job"
  button, a record-resumable step inside a cell — #88's model — is the natural
  shape. I rule it out as "never" in §8; "not until the record exists and the
  Windows bug is gone" would be more defensible.
- **My `internal` pushes `stable`**, which makes the train the thing that
  publishes `web` and packagecloud. #88 avoids this by never saying what
  triggers the matrix. Neither of us has solved it; I have at least written it
  down.

### Net

Take #88's emphasis on record-resumability and its three findings; drop its
stage 2 and correct §3 and the §9 amendment; and add what it lacks — the verb
and `--store` semantics — from §3–4 here. The two staging lists then agree on
stage 1 and differ only in that mine has no "centralize the build number"
stage and puts `internal` last.
