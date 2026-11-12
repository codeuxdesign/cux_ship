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

Research and design only: it proposes work and performs none.

**This supersedes PR #88, which was closed unmerged.** That document answered
the shape question and not the parity one, and its central claim was false: it
said AuthPass's six Android matrix cells each allocate their own build number,
so one release burned six and its artifacts disagreed. They do not — §2 has the
evidence, three independent ways. Everything #88 built on that claim went with
it: its headline, its second stage, and one of its risks.

Its other blocking defects, stated here because §10 compares against a branch
most readers will not open: its §1 diagram left the Android cells "unchanged"
while re-parenting Play uploads that run *inside* those cells' build process,
contradicting the hard constraint it declared two sections later; its
destination table claimed completeness while omitting `web.authpass.app`,
packagecloud and the appcast, and miscategorising snap; its F-Droid paragraph
was wrong on four counts, including treating a 22-locale metadata tree as "a
changelog file"; and it proposed handing a central build number to four
workflows, which is the stage that rested on the false claim. The plan below
cannot have the first of those, because the train never enters a CI cell at
all (§5). Four findings of #88's are worth keeping and are folded into §2 and
§5: the fail-open upload guards, the `::set-output` measurement, resumability
as the central capability, and the manifest as a build's receipt.

**The "manual destination" idea is inherited, not mine**: `release-train.md`
§8 on `cux_ship`'s `origin/main` already proposes one, and I read that document
before designing because it defines what `cux_train` is meant to become. What
is mine is how far the idea is taken (§1), the evidence model (§6), the role
split (§5) and the staging (§8).

Throughout: **[V]** = verified by reading the file or running a read-only git
command, or a public read with no credential, on or before the date above;
**[A]** = my argument; **[?]** = not verified, and I say what would settle it.
Anything added when this document was reviewed on 12 November 2026 says so in
place.

---

## 1. The thesis in four claims

1. **The vocabulary is shared on day one, by declaring every AuthPass release
   step a destination and letting most of them start as `manual`** — exactly
   what the README checklist is today — so the five verbs and the flags *mean*
   the same thing in both repositories before a single step is automated. [A]
   Meaning the same is not working the same: §8 delivers `status` and
   `production` in step 1, `ready` in step 2, a `beta` that acts in step 3 and
   `internal` in step 5. What is true on day one is that nothing has to be
   re-learned later — the words do not change as the automation arrives.
2. **Automation then replaces `manual` one destination at a time, behind an
   unchanged command.** Play and the App Store flip to `cux_ship` promotes;
   snap, the artifact server, GitHub and FossHub flip to scripts AuthPass
   mostly already has — mostly, because the appcast's script is not in the
   repository (§6.4); F-Droid and the four consoles never flip. Those four are
   not "consoles with no API": §7 believes all four publish one, though it
   marks that `[?]` and did not check, and what is certainly missing is a
   client for any of them. Writing four is a separate project. This is the
   owner's own rule ("everything supported by train is replaced; f-droid etc.
   can't be") expressed as a property of a table rather than of a migration.
   [A]
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
  `tag.upload.enabled: true`). It writes **no** `promoted/` tags at all: not
  one, against dozens of `uploaded/` — see the bullet below for why that
  number is not worth pinning down.
- **[V] One build number per commit, across every CI cell.** So although a
  dozen jobs each call `ship.sh buildnumber generate`, one *commit* has one
  number, and every artifact built from that commit agrees. **It is also what
  PR #88 got wrong**, so it is worth having three ways rather than one:

  1. **The allocator is commit-keyed.** `cux_buildnumber/lib/src/tool.dart`'s
     `_generateOrGet` returns the commit's existing number — local note first,
     then after a `_fetch()` — *before* it will allocate. On a lost push it
     refetches and takes the winner's note for that commit, which is what its
     "Another allocation won the race" retry resolves to. Concurrent cells
     therefore converge rather than each claiming a number.
  2. **The allocation log agrees, over every allocation ever made.** In
     AuthPass's `refs/buildnumbers/commits`, each entry carries a built commit
     as a second parent, and **no commit appears twice**. The invariant is the
     claim; the total is whatever the log has reached (67 on 12 November 2026,
     and it grows with every build):

     ```
     git log --first-parent --format='%P' refs/buildnumbers/commits \
       | awk 'NF>=2 {print $2}' | sort | uniq -c | awk '$1>1' | wc -l
     → 0
     ```
  3. **A shipped release says so.** `authpass/README.md:71`–`:74` lists one
     release's GitHub assets — `AuthPass-setup-1.7.7_1519.exe`,
     `authpass-sideload-1519.apk`, `authpass-linux-1.7.7_1519.tar.gz` — three
     artifacts from three workflows on two operating systems, one build number.
     The fourth asset, `AuthPass.app-1.7.7-b1519.zip`, carries 1519 as well and
     is deliberately *not* counted here: it is built on the laptop
     (`notarize-macos.sh`), so it is evidence that the laptop shares the
     allocator, which is a different claim from the CI cells agreeing.

  The corollary matters for §5: because the number is a property of the commit,
  the train needs no step *before* the matrix to allocate one, and `fail-fast`
  costs no numbers.
- **[V] A *version*, though, has many build numbers, and `uploaded/` is a log
  of uploads rather than a ledger of releases.** Corrected in review on 12
  November 2026; the bullet above used to continue *"one release commit has one
  number … this is what makes one grid over twelve artifacts coherent"*, and
  that inference does not hold. One commit has one number. A release is not one
  commit.

  **Dozens of `uploaded/` tags cover just two versions** — on 12 November 2026
  there were 47, split 22 for 1.9.12 and 25 for 1.9.13, each on its own
  commit. The reason is that `main.yml` triggers on
  `pull_request: branches: [main]`, `playstoredev` is in the matrix and is
  *not* in the `shouldRelease: false` exclude list, and `release.sh:205`–`:230`
  uploads it to Play on every such run — so an ordinary pull request writes an
  `uploaded/` tag.

  Two consequences, and the second is why no count above is given without a
  date. Tag creation order does not track build number: `+2218` was tagged at
  12:42:47 and `+2217` twenty seconds *later*, so the namespace is not
  monotonic in either axis. And the figures move constantly — during the
  review of this document the totals went from 46 to 47 and 1.9.13's from 24
  to 25, because one more pull request merged. **A count of `uploaded/` tags is
  not a fact about a release; it is a fact about the hour it was taken.**

  And the destinations disagree in exactly the way that predicts. Read from
  `api.snapcraft.io` (no credential) on 12 November 2026, snap `edge` holds
  **1.9.13+2196** — twenty-three numbers below the highest record for the same
  version, and, as it turns out, the *correct* build. Which the next paragraph
  is about.

  So the donor's central invariant — *the same build* moves through the
  audiences — does not hold in AuthPass as it stands, and two things follow
  that the rest of this document is written to:

  1. **The release candidate has to be named, never inferred from the highest
     tag.** `--build N` explicitly, or the number allocated for the commit at
     the tip of `stable`, read from `refs/buildnumbers`. `uploaded/` is
     corroboration only — §5 says the same thing for a different reason, and
     §3 and §8 must not quietly use it as the anchor.

     **That rule was checked against 1.9.13, and four independent sources
     agree on 2196.** [V, 12 November 2026] `origin/stable`'s tip is
     `50f5d63f`; `refs/buildnumbers/commits` carries
     `buildnumber: 2196 (increment) at commit 50f5d63f…`; the only tag at that
     commit is `uploaded/v1.9.13+2196`; the artifact server's manifest for
     that build records `gitSha: 50f5d63f…`; and snap `edge` holds 2196.
     Asking instead for the highest `uploaded/` tag gives 2219, whose artifact
     set is **incoherent**: `authpass-sideload-1.9.13_2219.apk` answers 200 and
     `authpass-linux-1.9.13_2219.tar.gz` answers 404, because `sideload` builds
     on pull requests and `linux.yml` does not. A run anchored there would ask
     fifteen destinations for an artifact that was never built.
  2. **`status` has to be able to say that one version is scattered across
     builds**, because today it is. That is not an error state to refuse; it is
     the state of the world, and rendering it is most of the value.
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
  the `.deb` on packagecloud (`make_deb.yaml`), and snap `edge`
  (`snapcore/action-publish@v1`, `release: edge`, under no `if:`).

  `packagecloud` is looser than "the moment `stable` is pushed" suggests, in
  two ways worth knowing before the train claims to order it: `make_deb` is a
  `workflow_run` on "build linux" with `types: [completed]`, so it fires on
  *any* conclusion of that workflow and on its `beta` and `linux**` triggers
  too; and it does not consume the triggering run's artifact — it `wget`s
  `authpass-linux-latest.tar.gz` from the artifact server and repackages that.
  So the deb is only indirectly tied to the push that produced it. [V]
- **[V] The Apple split is a process property, not only a step property.**
  `ios.yaml` gives *both* steps `SOPS_AGE_KEY`; what keeps the key from
  xcodebuild is that **`keychain exec` strips it from the child
  unconditionally**, with no way to readmit it (`cux_ship` 3.0.0). `--only
  ssh_keys.github_deploy` is the other half and does the opposite job: it names
  what the build *does* get, which is the deploy key `ship.sh buildnumber
  generate` needs. The upload is a sibling step that decrypts for itself.
- **[V] Two App Store app records, two Play packages.** iOS is
  `design.codeux.authpass.ios` (`upload-ios.sh`); macOS is a different record
  (`release-train.md` §5.2 quoting `upload-macos.sh`); `playstoredev` is
  `design.codeux.authpass.dev`, "a separate listing, not a track".
- **[V] The macOS direct download is local on purpose** (`notarize-macos.sh`
  header: team key in `~/.appstoreconnect`, "DELIBERATELY NOT PART OF CI").
- **[V] A Dart child with inherited stdio dies on the Windows runner**
  (`ship.sh`'s `buildnumber` block works around it with temp files). The train
  spawns everything with inherited or piped stdio. This matters in §5.
- **[V] The checklist drifts when nobody orders it**, and two destinations say
  so out loud. In git: the newest bare release tag is `v1.9.11`, the newest
  `fdroid-v` tag is `fdroid-v1.9.10`, there are **no `promoted/` tags at all**,
  and `origin/stable` carries 1.9.13 (`pubspec.yaml` 1.9.13+167, a
  `## 1.9.13 - 2026-11-09` CHANGELOG section, tip `50f5d63f`, the merge of PR
  #435) while `uploaded/v1.9.12+…` and `uploaded/v1.9.13+…` exist.

  And from the destinations themselves, read without a credential on 12
  November 2026: **F-Droid is on 1.9.10** and **snap `stable` is on 1.9.7+1940,
  published 30 June 2022** — six releases and four years behind its own `edge`.

  **Every direct download is still on 1.9.11+2007**, and three separate
  server-side documents say so independently: `stable.txt` reads
  `release=1.9.11_2007`, `appcast.xml` offers `Version 1.9.11+2007`
  (`sparkle:version="2007"`, so Windows auto-update is pointed there), and the
  `.fosshub` index — the document `github-release.sh` and `fosshub-release.sh`
  both read, and from which the former takes its version — reads
  `1.9.11+2007`. Two releases have been built and uploaded and have reached no
  direct-download user.

  That last one carries an ordering constraint §3 should respect: because
  `github` and `fosshub` read the server's index, their steps must run *after*
  the `direct:*` production step that updates it. Run today, in the order §3
  step 3 lists them, `github-release.sh` would cut a release for **1.9.11**.

  So the question the draft could not answer from git ("did 1.9.12 reach every
  console and merely go untagged?") is answered *no* wherever anything can be
  read, and remains open only for the consoles that cannot be. **[?]** Which is
  still the argument for a record, now with examples: for Amazon, Samsung,
  Huawei, Microsoft and the PPA there is no way to find out at all.
- **[V] `cux_ship` 3.6.0 already has** `play promote`, `appstore promote`,
  `appstore beta-release`, `release finish`, `play version-code`,
  `appstore build-number`. **It does not have** the `--json` reads the donor's
  `status` is built on (4.1.0 onward; the donor pins `4.5.0-dev.8`). 4.0.0's
  one loud CLI break is `--data-safety`, which AuthPass does not pass (grepped
  `_tools/`).
- **[V] `cux_train` on `origin/main` is an entry point and a usage text**,
  `sdk: ^3.12.2`, no dependencies at all yet. **And that floor is reachable,
  which settles a disagreement between the two documents.** `release-train.md`
  §7 still says "the train declares `sdk: ^3.13.0` while AuthPass pins Flutter
  3.44.7, whose bundled Dart is below that floor … That is a Flutter bump as
  well" — that is about the *donor's* `tool/train/`, and `cux_train`'s own
  pubspec records why it does not inherit it: the donor's `^3.13.0` was
  incidental, the package analyzes clean declared at `^3.12.2`, and 3.12.2 is
  exactly the Dart that Flutter 3.44.7 bundles. `release-train.md` §9 already
  carries that as answered. So step 1 needs **no Flutter bump**, which is what
  lets §8 claim it moves no pin.

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
| `snap` | snap | CI | **already on `edge`** | none today (a `beta` channel exists; last fed 1.9.11 in Feb 2024) | manual today, and **last done in 2022**; `snapcraft release … stable` is scriptable | **yes**, `api.snapcraft.io`, no credential [V] |
| `packagecloud` | deb | CI (`make_deb`) | **already public** | — | nothing left to do | [?] |
| `ppa` | deb source | other repo, docker | none | none | **manual**: two `docker-compose run` lines in `authpass-deb` | yes (Launchpad) [?] |
| `flathub` | — | Flathub's bot | none | none | **observe only** | yes (public API) [?] |
| `fdroid` | — | F-Droid, from source | none | none | push `fdroid-vX.Y.Z`, update `fdroid-version.txt` | **yes**, `f-droid.org/api/v1/packages/…` [V] |
| `web` | gh-pages | CI | **already public** | — | nothing left to do | yes (it is a URL) |

`playstoredev` is deliberately **not a destination**. It is a dev listing, not
a stage of a release, and it stays in `main.yml` with the train never
mentioning it. [A] It is fed more widely than "nightly" suggests: every `main`
push, every pull request to `main`, and — to its *beta* track — every `beta`
and `stable` push, since `release.sh:208`–`:212` sets `track=beta` when the ref
contains either word [V]. That breadth is why §2's `uploaded/` tags appear on
pull-request commits, and it strengthens rather than weakens the exclusion: a
destination in the path of every merge is not a release stage.

**The `[?]` in the last column** mean "I believe a public read endpoint exists
and did not call one". Four of the six are still that: `fosshub`,
`packagecloud`, `ppa` (Launchpad) and `flathub` — and for `fosshub` and
`packagecloud` the honest position is no position rather than a belief. **Two
are now settled** [V, 12 November 2026]: snap answers on `api.snapcraft.io`
and F-Droid on `f-droid.org/api/v1/packages/<id>`, both without a credential,
and §6.3 records what they said.

Of the four remaining, **two** are not load-bearing — `fosshub` and `ppa`,
where a person or a script acts, so an unreadable destination simply becomes
*attested* (§6). The other two are, for the reason §6.3 gives about Flathub:
nobody acts there, so there is nothing to attest, and the row's entire content
is its read. If Flathub cannot be read the row is permanently `pending` and
means nothing, rather than degrading gracefully. **`packagecloud` has exactly
that shape** — its production cell is "nothing left to do" — and so does
`web`, which is readable because it is a URL.

### `status`

Reads, writes nothing. One row per destination, one column per audience, each
cell a build number **with its evidence class** (§6.2's six marks: observed,
attested, disagreed, failed, pending, n/a). Clean mapping. The only difference
from the donor is that the grid is taller and that most cells are records, and
the grid has to say which is which rather than render both the same way.

**The grid is keyed by version, and the build number lives in the cell.** That
is forced by §2: AuthPass's 1.9.13 exists as two dozen builds and its
destinations hold different ones, so a grid keyed by build would render one
release as two dozen near-empty grids. A cell whose build differs from the
candidate (below) is named as such — snap `stable` holds 1940 where the
candidate is 2196 — and never normalised
away, because that difference is the thing worth seeing.

**Which build the run is about — the candidate — is named, not guessed.**
`--build N`, or the number `refs/buildnumbers` allocated for the commit at the
tip of `stable`. Not the newest `uploaded/` tag, which §2 shows is routinely a
pull request's.

### `ready`

"Could `production` run, and what is missing." Clean mapping, and **this is
where AuthPass gains the most**, because "wait for github builds" in the README
is exactly a readiness question nobody can currently ask. For build N:

- the `pre-release` hook (AuthPass's own: CHANGELOG has a section for the
  version; the F-Droid changelog file exists; `store/appstore/` verifies —
  though note that tree holds exactly one file today,
  `listings/en-US/beta_description.txt`, so that last check is thin [V]);
- every CI-built destination has its artifact for N — on the artifact server
  with its `.manifest.json`, or in the store — one row per missing one;
- `direct:macos` exists (the step people forget, because CI does not do it) —
  and note that it has no `.manifest.json`, so this one row is checked by the
  artifact's presence and name alone (§5);
- the candidate resolves: `--build N` was given, or `stable`'s tip has an
  allocated number. A bare `ready` with neither **refuses** rather than taking
  the newest `uploaded/` tag.

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
   candidate, or its CI job has failed, **or the wait times out**. A failed
   cell is reported and does not stop the others — the donor's own rule ("a
   store refusing does not stop the others").

   The timeout is not optional, because the failure signal is. §5 keeps the
   train working without `gh`, and without `gh` there is no way to observe
   "its CI job has failed" — so for a destination whose build failed, the only
   exit is the clock. A default on the order of an hour and `--wait-timeout` to
   change it.

   A timed-out row is **`pending`**, not `failed`: not hearing back is not the
   same as being told no. That is why §6.2 defines `pending` as *no evidence
   either way* rather than as "nobody has acted" — a dispatched build whose
   wait expired has been acted on and read repeatedly, and still produced no
   evidence. The run says so in its summary ("3 destinations still pending
   after 1h") so that a timeout is never mistaken for a quiet success. [A]

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

`snap` could have one (`edge` → `beta`), and I would **not** add it. The
channel is not unused in the way the draft said — `api.snapcraft.io` shows
`latest/beta` holding 1.9.11+2007, released 4 February 2024 [V] — but it has
not been fed since, and reviving a channel nobody has used in two years to
fill a cell is the thing this plan warns against. If it is revived, it is a row
change and nothing else.

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
3. script destinations, and **this group is ordered, not a set**: the
   artifact-server index first (`stable.txt`/`update_stable.sh`/appcast), then
   GitHub release and FossHub, which read that index and would otherwise
   publish the previous release (§2), then snap → stable;
4. manual destinations, one at a time: Amazon, Samsung, Huawei, Microsoft, PPA
   (§6 says what the operator sees);
5. finish, **once every destination that has a production step is recorded**:
   `vX.Y.Z` via `cux_ship release finish`, then the `fdroid` step — push
   `fdroid-vX.Y.Z`, update `fdroid-version.txt`, record it.

   Two exclusions, both deliberate, because without them the rule can never be
   met. A destination whose production kind is `none` — `web`, `packagecloud`,
   `flathub`, and every "nothing left to do" cell in the table — is **satisfied
   vacuously**: nobody acts, so there is nothing to record, and waiting for a
   record that no step writes would hold the `vX.Y.Z` tag forever. And `fdroid`
   is ordered *after* finish on purpose, so that `fdroid-vX.Y.Z` follows the
   `vX.Y.Z` it annotates; it is therefore the one destination finish does not
   wait on.

Two things differ from the donor and both are real:

- **It cannot be one sitting.** Review queues and console uploads take days. A
  re-run must skip what is recorded and pick up at the first destination that
  is not. The donor has no such notion — its `production` is three API calls.
- **"Production" for a manual destination means *handed over*, not *live*.**
  The record says the operator submitted it. `status` can only upgrade that to
  *live* where the destination can be read. The grid must not render
  "submitted to Huawei" and "Play production holds 2196" identically.

### Flags

`--build`, `--dry-run`, `--yes`, `--verbose` carry over unchanged.
`--wait-timeout` is new and belongs to `internal` alone (above); it is the one
addition to the donor's surface this plan asks for, and it exists because the
evidence it bounds is a wait on other machines. `--rollout`
stays Play-only, `--phased`, `--hold`, `--prepare` stay App-Store-only, and are
refused by name for any other destination, as the donor already refuses
`--prepare` for Play. **No new flag is needed for the normal path** —
`--wait-timeout` has a default, so the normal path never types it. I
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
  direct:macos` is one. No new syntax. Note that AuthPass declares no bare
  `appstore` destination — it has two Apple records, not one — so `--store
  appstore` means "both members", exactly as the donor's does.
- **A family whose every member is `none` at a stage is refused, by name.**
  `--store direct beta` prints "no direct download destination has a beta
  stage; direct downloads have no audience tiers" and exits non-zero, rather
  than succeeding against nothing. That is the same rule as `--store amazon
  beta` (§3) applied one level up, and it is the donor's principle: a flag
  that would do nothing is refused rather than dropped. A family with *some*
  members staged acts on those and names the ones it skipped.
- The default remains "every destination", and `isEveryStore` — the condition
  for spending the bare version tag — becomes "every declared destination that
  has a production step is recorded at production", with the two exclusions §3
  step 5 sets out: a `none` kind is satisfied vacuously, and `fdroid` is
  ordered after finish. That is the finish rule AuthPass needs anyway.
- A platform name is still refused by name. With six Android destinations the
  donor's message ("Android has one store today and will not always") has come
  true.

The word "store" is slightly wrong for `direct`, `web` and `github`. I would
keep it rather than add `--destination` as an alias: two spellings of one flag
across two repositories is the opposite of what was asked for. [A]

**Where the table lives.** The natural home is a `train:` block in
`.cux-ship.yaml` at the repository root, beside `app-dir` and `tag`, because
the `uploaded/` namespace it must agree with is declared there. **That does not
work today, and the failure is not soft.** [V, `cux_ship/lib/src/config.dart`,
12 November 2026] `_knownKeys` is `{app-dir, apple, appstore, play, tag}` and
`_checkKeys` **throws** `ProjectException` on anything else; the file's own
header states the policy — "An unknown key is an error, not a value to ignore"
— and gives the reason, that a silently skipped key is a setting which appears
to be applied and is not. Since the file is read before *every* `cux_ship`
command, a `train:` block would fail every upload in AuthPass's CI, which is
flatly incompatible with §8 step 1's "does not touch working CI".

So there are two options, in the order I would take them, and no third:

1. **Add `'train'` to `_knownKeys`.** One line, in *this* repository —
   `cux_train` is a workspace member of `_cux_ship_workspace` beside
   `cux_ship`, so there is no cross-repository coordination. It keeps one
   config file at the root, which is the arrangement worth keeping.
2. **A sibling `.cux-train.yaml`** — works immediately, at the cost of a
   second file that has to agree with the first about the tag namespace.

**Option 1 is not available to step 1**, because step 1 holds the
`cux_ship: ^3.6.0` pin and the key would only be known to the version that
learns it. So step 1 uses the sibling file.

**And option 1 has no release to land in yet**, which is a consequence of
step 2 settling on 4.4.0 (§8). 4.4.0 is already published and cannot learn the
key, so the move into `.cux-ship.yaml` waits for the first `cux_ship` release
*after* it — not for step 2. Until then the sibling file is where the table
lives, and if no such release is cut, it is where the table stays. That is a
tolerable end state rather than a broken one; it is recorded so nobody plans a
migration that has no date. [A]

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
  commit — *observed*, where one exists; `release.sh`'s `write_manifest` is
  called for the ipa, the App Store pkg, all four apk flavors, both aabs, the
  linux tar.gz, the windows exe, the portable zip and the msix, and
  `make_deb.yaml` writes the deb's [V];
- the CI job concluded successfully (`gh run list --commit`) — a *claim*, used
  for progress and for failure, never as the final evidence.

The `uploaded/` tag is deliberately **not** on that list for per-destination
evidence: it is one tag per commit, first store wins [V, `.cux-ship.yaml`], so
it proves somebody uploaded and not who. `release-train.md` §8 says the same.

**Three destinations have no manifest at all, and one of them matters.** [V]
Web is excluded deliberately (`release.sh:313`: "No manifest, deliberately").
The `.snap` is uploaded to the artifact server by `linux.yml` and `release.sh`
has no snap branch, so none is written for it. And **the notarized macOS zip —
`direct:macos` — has none**: neither `notarize-macos.sh` nor `build-macos.sh`
calls `write_manifest`, and the only macOS manifest is the App Store pkg's.
That is the destination §3 singles out as "the step people forget" and the one
§6.1's instruction block would most like a digest for. For these three, the
evidence is the artifact's presence and name, which embeds `{version}_{build}`
— adequate, and weaker. Writing a manifest for the macOS zip is a few lines in
`notarize-macos.sh` and worth doing before step 1 leans on it.

**The server does accept manifests. Settled by reading it.** [V, 12 November
2026] Two of AuthPass's own comments disagree —`upload-artifact.sh` makes the
sidecar upload a *tolerated failure* because "no `*.manifest.json` companion
pattern is in [the allow-list] yet", while `make_deb.yaml`, committed thirteen
hours later the same day, says "the server only recently learned to accept
manifests". The newer one is right. For build 2196, every CI-built artifact
checked answers 200 **with its sidecar**: the linux tar.gz, the sideload apk,
the windows setup exe, and the huawei and amazon apks. The sidecar is schema 2
and carries exactly what §6 wants from *observed* evidence:

```
{ "artifact": "authpass-linux-1.9.13_2196.tar.gz", "sha256": "6559bd0b…",
  "versionName": "1.9.13", "buildNumber": 2196, "buildNumberAssigned": true,
  "gitSha": "50f5d63f8a11d3800b09c33b9af6a7e89ee60793", "dirty": false,
  "platform": "linux", "producer": { "name": "cux_ship", "version": "3.6.0" } }
```

So §5's best evidence class exists today, and `upload-artifact.sh`'s comment is
the stale one. Its own instruction now applies — "Drop the `||` once the
allow-list knows manifests; a silent-refusal state is not worth keeping" —
which is a small change in AuthPass and not this plan's to make, but it should
be made before a `run` step relies on that upload failing loudly.

The three manifest-less destinations above are a separate gap, and `direct:macos`
is the one that bites: `AuthPass.app-1.9.13_2196.zip` answers **404** on the
server, so 1.9.13's macOS direct download was never uploaded at all. "The step
people forget" has in fact been forgotten for the current release — which is
§3's `ready` check, firing on live data, before the tool exists.

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
── huawei · production · build 2196 ────────────────────────────────────
  upload   authpass-huawei-1.9.13_2196.apk
           https://data.authpass.app/data/artifacts/authpass-huawei-1.9.13_2196.apk
           sha256 3f9c…  (from its manifest)
  where    https://developer.huawei.com/consumer/en/service/josp/agc/index.html
  notes    CHANGELOG.md § 1.9.13, rendered for this store — copied to the clipboard

  [d]one   [s]kip for now   [f]ailed   [q]uit — nothing after this is lost
```

- **Instruction**: the exact artifact (name, URL, digest from the manifest),
  the console URL from the README, and the release notes already rendered —
  three things the operator currently assembles by hand, per console.
- **Wait**: `d` records and moves on; `s` leaves it unrecorded so the next run
  stops here again; `f` records that it was *attempted and refused*, with a
  line of why; `q` ends the run with everything so far kept. `f` exists
  because `s` alone makes "the console rejected the binary" look exactly like
  "nobody has looked yet", and §2's whole argument for a record is that *not
  being able to tell* is the failure.
- **Record**: `promoted/huawei/production/v1.9.13+2196`, the donor's existing
  tag shape, pushed. That one tag is what makes the run resumable, what
  `status` shows next week, and what the finish rule counts.

The example uses 2196 because that is 1.9.13's actual candidate (§2), and the
artifact and sidecar it names both answer 200 on the server today — so the
block above is what the operator would really see, not a sketch.

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
| disagreed | observation and attestation name different builds | snap stable: a record would say 2196, the API says 1.9.7+1940 |
| failed | a step ran or was attempted and did not land | a CI cell that failed; a console that refused the binary |
| pending | no evidence either way — nothing was read, nothing is recorded, and nothing is known to have failed | an untouched cell; a destination whose wait timed out |
| n/a | this destination has no such stage | every non-store `beta` cell |

Six marks, not four, and the two added ones are the point rather than
bookkeeping. **`disagreed`** is the most valuable line the tool can print, and
it needs a mark of its own: in the draft it was described in prose here and
then had nowhere to live in the grid. `ready` lists it as a problem.
**`failed`** exists because §3's `internal` reports "its CI job has failed" and
§6.1 now lets an operator record a refusal — neither of which is `pending`,
and rendering them as `pending` loses exactly the distinction §2 says the
record exists for.

Where only attestation exists, the grid says so in the cell and never promotes
it to "holds".

One annotation sits beside the mark rather than among them: **`public at
internal`**, for the three destinations §3 identifies as reaching users the
moment `stable` is pushed. It is a property of the destination's stages, not of
this cell's evidence, which is why it does not belong in the table above.

### 6.3 F-Droid, Flathub: the publishing decision is not the train's

- **F-Droid** has a `production` step that is not an upload: the gate checks
  the changelog file is committed, and the step pushes `fdroid-vX.Y.Z` and
  updates `fdroid-version.txt`. Afterwards it is `attested` until the F-Droid
  index shows the version, then `observed`. The train can never make F-Droid
  build; it can make sure the tag was not forgotten, which per §2 it has been.

  **The version number is settled, and the row is three releases stale.** [V,
  `f-droid.org/api/v1/packages/design.codeux.authpass.fdroid`, 12 November
  2026] The index answers `suggestedVersionCode: 164` with
  `versionName: 1.9.10`. So F-Droid's versionCode **is** the pubspec's `+N`,
  not the git build number — the draft inferred that and marked it `[?]`, and
  the inference was right. What the same read also says is that F-Droid is on
  **1.9.10** while `stable` carries 1.9.13: 1.9.11, 1.9.12 and 1.9.13 never
  arrived, matching `fdroid-v1.9.10` being the newest such tag. And the
  changelog tree tops out at `160.txt` against a shipped 164, so the changelog
  step has been missed too. This is the plan's motivating example, confirmed
  from the destination rather than inferred from absent tags.
- **Flathub** is `none` at every stage with a `read`. It appears in `status`
  so that "should already be updated automatically daily — check" becomes a
  cell that is red when the bot did not run. **Its read is therefore
  load-bearing in a way the others are not** (§3): with nobody acting, there is
  nothing to attest, so an unreadable Flathub leaves a cell that is
  permanently `pending` and says nothing.

### 6.4 What is *not* dropped — the check

Every line of the README's "Releasing" section, against a row:

| README step | destination / mechanism |
|---|---|
| write CHANGELOG, F-Droid changelog | `pre-build` + `pre-release` hooks |
| push `stable`, wait for builds | `internal` dispatch + wait |
| macOS direct zip, local | `direct:macos`, `run`, laptop |
| tags `v…`, `fdroid-v…` | finish; `fdroid` step |
| `stable.txt`, `update_stable.sh`, `fdroid-version.txt` | `direct:*` production script; `fdroid` step |
| appcast | `direct:windows` production step — but see below: the script is not in this repository |
| GitHub release | `github`, `run` (`_tools/release/github-release.sh`) |
| FossHub | `fosshub`, `run` (`_tools/release/fosshub-release.sh`) |
| Play, App Store Connect | `play`, `appstore:*`, `ship` |
| Samsung, Huawei, Amazon, Microsoft | `manual` |
| PPA | `ppa`, `manual` |
| snap edge → stable | `snap`, `manual` then `run` |
| flathub check | `flathub`, read only |

Nothing is unassigned. **Two** things CI does that the README does not list are
also rows: `web` and `packagecloud`. (The draft said three and counted the snap
`edge` publish; `README.md:93` does list it — "snapcraft.io is already
published to `edge` channel" — so only the web app and packagecloud are
genuinely unlisted. [V])

Three things the table glosses, all verified, each of which a `run`-kind step
has to handle rather than assume:

- **`appcast.generate.sh` is not in this repository.** `README.md:67` says to
  run it and `winsparkle_init.dart:13` consumes the resulting
  `appcast.xml`, but no such file is tracked here — it lives server-side. So
  §8 step 4's "each wrapping a script that already exists" does not hold for
  this one; it is a step whose script has to be found or written.
- **`github-release.sh` fails silently successful.** It needs a draft release
  to exist, and its not-found path (`:47`–`:52`) ends in a bare `exit`, i.e.
  status 0. A `run` step that trusts the exit code would record a GitHub
  release that never happened — which is precisely the fail-open shape §2
  flags in the upload guards.
- **`github-release.sh` and `fosshub-release.sh` get their file list from the
  artifact server**, not from local state (both `curl`
  `data.authpass.app/data/artifact.download/.fosshub`, and the GitHub one
  takes `version` and `build` from that document). Those two destinations are
  already downstream of the server's view of a release, which is convenient
  for §6's evidence model and worth stating rather than discovering.

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
| Evidence classes in the grid (observed / attested / disagreed / failed / pending / n/a) | Any consumer with one unreadable destination needs it. |
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
general knowledge; not checked against their documentation] Writing clients
for them in `cux_ship` would turn four `manual` rows into `ship` rows. That is
a separate project with its own review burden; this plan makes it *possible*
(flip the row's kind) and does not ask for it.

---

## 8. Staging, and the smallest first step

### Step 1 — the smallest thing that is real

> **`tool/train.sh status` and `tool/train.sh production --dry-run` in
> AuthPass, on the laptop, with every destination declared and none
> automated.**

What exists after it:

- `tool/train.sh` at AuthPass's **git root** — the same path typed in both
  repositories. A launcher of a few lines. The root is where `.cux-ship.yaml`
  and `store/` live, and `CHANGELOG.md` is there as a symlink into
  `authpass/`; `.cux-ship.yaml`'s own comment says why that is deliberate —
  "CHANGELOG.md and store/ deliberately stay at this level: a release
  describes what the repository shipped, not what one package did" [V]. The
  donor's layout is the same shape: `tool/` at a root that holds
  `.cux-ship.yaml` and `CHANGELOG.md` and *no* `pubspec.yaml`, with the app in
  `app/` [V].

  Two things to be straight about. `tool/` would be AuthPass's **first**
  root-level tool directory — every existing release script lives under
  `authpass/_tools/`, and CLAUDE.md tells readers to run Flutter commands from
  `authpass/`. And the root `CHANGELOG.md` being a symlink is not free: it is
  why the wrapper's pubspec records taking `cux_ship` 3.5.1 for "the
  symlink-aware committed-notes guard this repo's root CHANGELOG.md needs".
  The placement is still right — parity is the point, and the release-level
  files are already here — but it is a new convention, not an existing one.
- The destination table of §3, every production step `manual` or `none` —
  *including Play and the App Store*, which are console steps today.
- `status`: a grid built from `uploaded/` and `promoted/` tags plus the reads
  that need no credential (artifact server URLs). Mostly `pending` on day one;
  that is honest.
- `production --dry-run`: the README checklist, generated **for the named
  candidate** (§3: `--build N`, or `stable`'s tip), with artifact names, URLs
  and consoles filled in. Not for the newest `uploaded/` tag — §2 shows that is
  usually a pull request's build, for which most destinations have no artifact
  at all.
- `production` for real: walks the manual steps and records each. **The
  release is performed exactly as today — by hand — but ordered, resumable and
  recorded.**

Why this and not something smaller: anything less leaves no record, and the
record is what every later stage is built on. Why not something larger: it
dispatches nothing, promotes nothing through an API, and holds no credential.

**It does not touch working CI**, in the strict sense:

- no workflow file changes;
- `release.sh`, `ci-release.sh`, `ship.sh` unchanged;
- **the `cux_ship: ^3.6.0` pin is unchanged**, and no second pin is added —
  `cux_train` goes into the wrapper that already exists.

That last point was wrong in the first draft of this document and is worth
setting out, because the reasoning it replaces was the one piece of this plan
recommended *against* the consumer's own stated principle.

The draft proposed a second wrapper at `authpass/_tools/cux_train/`, justified
by "step 1's `cux_train` spawns `cux_ship` zero times, so the two cannot
disagree". **That justification is false by this document's own §3 and §7.** §3
opens `production` with `release finish --dry-run` as a gate and closes it with
`cux_ship release finish`; §7 leans toward the record *writer* being a
`cux_ship release record` command, which 3.6.0 does not have. Step 1 spawns
`cux_ship`, so two pins could disagree — and about the tag namespaces §4's
finish rule and §6's evidence model both depend on.

**It is also unnecessary.** `authpass/_tools/cux_ship/pubspec.yaml` already
carries *two* packages, `cux_ship` and `cux_buildnumber`, and states the
principle in a comment: "pinned by the same lockfile so there is exactly one
place to bump". Adding `cux_train` there is that same pattern — one wrapper,
one lockfile, one pin, and `ship.sh`'s existing resolution discipline. Once
`cux_train` does import `cux_ship` (its pubspec says it will, for
`documents.dart` and `exit_codes.dart`), the single lockfile *forces* the two
to agree, which is the point of one pin rather than a cost of it. The step-2
"merge the two wrappers" task disappears because there was never a second one.

**One prerequisite neither version of this stated: `cux_train` is not
published.** `pub.dev/api/packages/cux_train` returns 404 (checked 12 November
2026) — it is `version: 0.1.0-dev.1` with `resolution: workspace`, and its own
pubspec says publishing is a `release/` branch's job. So step 1 consumes it as
a **git ref**, the way `cux_ship` itself was consumed before 1.6.0 and the way
`cux_ship`'s CI already tests ("Resolve as a git dependency" is one of its
checks), or `cux_train` is published first. That is a decision step 1 cannot
skip, and it belongs to `cux_ship`'s side of the work. [A]

**The honest cost of step 1 is in the `cux_ship` repository, not in AuthPass —
and it is the bulk of the whole programme, unestimated.** (Repository, not
package: every version number in this section — 3.6.0, 4.1, 4.4.0 — is the
*package*, and the work below is in its sibling `cux_train`. The two share a
name and this is the paragraph where confusing them costs most.)

`cux_train` is empty. Step 1 needs from it: the table, `--store` over it, the
`manual` kind, the record (write + read), `status` from the record, and
resumable `production`. That is new code plus the donor's `options.dart`,
`hooks.dart`, `summary.dart` and the presentation files — and none of the
donor's `status.dart` reads or `train.dart` lanes. It agrees with
`release-train.md`'s conclusion that the *ordering* stage is the one with a
consumer.

So "the smallest thing that is real" is smallest **as seen from AuthPass**,
where it changes no workflow, moves no pin and holds no credential. Measured in
work it is the largest step in this plan, and §9 item 9 is right that nobody
has sized it. A reader choosing step 1 because it sounds cheap should read that
sentence first.

### Step 2 — `ready`, and the reads

Adds per-destination reads and the `ready` verdict: every artifact for the
candidate present, CHANGELOG and F-Droid changelog in place, attestation and
observation agree. Needs the `--json` reads for Play and the App Store,
therefore `cux_ship` ≥ 4.1. **This is the step that moves AuthPass's pin**, as
its own change, verified on a `main` push (which exercises `playstoredev`)
before any `stable` push.

**And it can move to a stable release today: 4.4.0.** [V, pub.dev, 12 November
2026] The draft said to wait for "a stable `4.5.0`", which does not exist and
is not scheduled — `cux_ship`'s newest published stable is **4.4.0**, and the
4.5.0 line exists only as `-dev.1` through `-dev.8`. Since the floor this step
actually needs is 4.1, 4.4.0 carries it, and pinning a prerelease in a
repository whose CI ships to stores is avoided. What 4.4.0 does *not* carry is
exact parity with the donor's `status`: `release-train.md` §7 names three
`StoreReads` members above 4.4.0 — `appStorePreviews` (needs
`noSuchVersionExit`, 4.5.0-dev.3), `appStoreListingDiff` (4.5.0-dev.4) and
`storefrontReleased` (4.5.0-dev.6) — so step 2's grid has **three** fewer
columns than the donor's until 4.5.0 ships.
That is a smaller price than either waiting or pinning a `-dev`. [A]

### Step 3 — flip the API destinations

`play` and `appstore:*` go from `manual` to `ship` for `production`, and
`beta` gains its three real rows. This is where the owner's "everything
supported by train should be replaced" lands: two consoles leave the checklist.
`--rollout`, `--phased`, `--hold`, `--prepare` start meaning something. First
run under `--dry-run`; the `appstore promote` default of publishing the
listing tree needs a decision for AuthPass, whose **Apple** uploaders pass
`--no-metadata` today on purpose (`upload-ios.sh:135`, `upload-macos.sh:114`
— "this lane ships TestFlight builds and never the listing"). The Android one
deliberately does *not*: `upload-android.sh` opts in with `--metadata` and
publishes release notes from the root CHANGELOG.md by default, its own comment
noting "the suppression is retired". So the two sides already have opposite
listing policies, and step 3 has to carry both rather than pick one. [V that
they differ; A that it needs deciding]

### Step 4 — flip the script destinations

`direct:*`, `github`, `fosshub`, `snap` from `manual` to `run`, one at a time,
each wrapping a script that already exists or a few lines of `ssh` — with one
exception: `appcast.generate.sh` is **not** in the repository (§6.4), so
`direct:windows`'s appcast step has a script to find or write, not wrap.
`github-release.sh` reads `~/.authpass_github_api_token` and needs a draft
release to exist; the train's `run` step should create the draft, which is the
one place a script changes rather than being wrapped — and while changing it,
its not-found path should stop exiting 0 (§6.4), because a `run` step cannot
see that failure otherwise.

### Step 5 — `internal`

The dispatch and the evidence wait, with `direct:macos` as the local lane.
Last, because it is the only step that pushes a branch CI reacts to, and by
then `ready` (step 2) can already say whether a manual push produced
everything — so step 5 automates a wait that is already checkable.

### Never

`release.sh` moving into the train; the train in a CI cell; the Apple step
split changing; and **the publishing decision** at F-Droid, Flathub, the PPA
or the four consoles belonging to anything but a person and a record.

That last clause is narrower than the draft's ("being 'handled' by anything but
a person and a record"), which contradicted §3, §6.3 and §7 — all three have
the train perform F-Droid's step, pushing `fdroid-vX.Y.Z` and updating
`fdroid-version.txt` as a `run` script. It does. What it never does is decide
to publish, or claim F-Droid published: it pushes a tag a person asked for and
records that it did, and F-Droid's builder is still the one that acts.

**The PPA is the open case in the other direction.** §3's table calls its
production step two `docker-compose run` lines — the same scriptability that
justifies flipping snap in step 4 — yet it is `manual` forever here with no
reason given. Either it is a `run` destination eventually, or there is a reason
it is not; the draft asserted the conclusion without either. [?]

---

## 9. What I could not resolve

1. **The `beta` branch versus the `beta` verb** (§3). Owner's decision.
2. **Whether `web`, `packagecloud` and snap `edge` should stay public at
   `internal`.** The plan reports it and does not change it.
3. **Writing a manifest for the macOS zip and the `.snap`** (§5). The server
   question is settled — it accepts them — so what is left is that nothing
   writes one for those two, which is a few lines in `notarize-macos.sh` and a
   snap branch in `release.sh`. AuthPass's change, not `cux_train`'s.
4. **Where the record writer lives** — `cux_train` or a `cux_ship release
   record` command (§7). This one now has a consequence attached: on the
   `cux_ship` reading, step 1 needs a command 3.6.0 does not have (§8).
5. **Which read endpoints exist** for FossHub, packagecloud, Launchpad and
   Flathub. Snap and F-Droid are settled (§3, §6.3). Of the four left,
   **Flathub's and packagecloud's are the ones that matter**, because nobody
   acts at either and the read is the whole content of the row; FossHub's and
   Launchpad's rows degrade to *attested* and lose little.
6. **"Submitted" versus "live" for manual stores.** One record state
   (*handed over*) is what I propose, now with *attempted and refused* beside
   it (§6.1). A third ("I saw it live") is easy to add and I am not sure it
   would be used.
7. **Whether the PPA should eventually be a `run` destination** (§8). Its step
   is two `docker-compose` lines, which is the test snap passes.
8. **Should `release.sh` stop writing `uploaded/` tags on pull requests?** Not
   this plan's call, and the plan is written to work either way (§2, §3: the
   candidate is named, never inferred). But a release ledger that records 46
   uploads for two versions is why that had to be designed around, and
   narrowing the tag to release refs would make `status` simpler.
9. **Time.** Nobody has estimated the `cux_train` work in step 1. It is the
   bulk of the effort (§8).

**Settled since the draft**, recorded here so the list is not read as still
open: F-Droid's versionCode is the pubspec's `+N` (164 for 1.9.10, from the
F-Droid index — §6.3); `.cux-ship.yaml` **rejects** an unknown `train:` key and
would fail every `cux_ship` command if given one (§4); snap and F-Droid both
answer public reads (§3); `cux_ship` 4.4.0 is a released stable that carries
step 2 (§8); the artifact server **does** accept manifests, so §5's best
evidence class exists today (§5); `cux_train`'s `^3.12.2` floor needs no
Flutter bump (§2); and "is 1.9.12 finished?" is answered *no* — for F-Droid,
for snap, and for every direct download, since `stable.txt`, the appcast and
the FossHub index all still read 1.9.11+2007 (§2). It is unanswerable only for
the five consoles nobody can read.

---

## 10. Against PR #88, which this replaces

#88's text is on the branch `claude/authpass-on-the-train`, which is kept
undeleted so this comparison stays checkable. §1–9 above were written before
#88 was read; both were then corrected in review on 12 November 2026, and
those corrections say so where they appear.

**#88 was closed unmerged** on the strength of this section and of the further
defects the preamble lists. This section is kept rather than deleted, because
the comparison is the record of why.

### Where we agree

- The ordering stage is the one to build first, and "a destination the train
  names and waits on" covers most of AuthPass's release. Both of us took this
  from `release-train.md` §8, so the agreement is weaker evidence than it
  looks.
- The matrix stays a matrix; the Apple split and the local notarization are
  hard constraints; the publishing decision at F-Droid and Flathub is never
  the train's. (#88 and the draft both wrote this as "checked, never
  performed", which §8's "Never" correction and §6.3 show is too strong: the
  train does push `fdroid-vX.Y.Z` and update `fdroid-version.txt`. What
  neither tool ever does is decide to publish or claim F-Droid published.)
- `upload-artifact.sh`, `github-release.sh`, `fosshub-release.sh` and the
  appcast stay AuthPass's, named as steps.
- Reads wait on a `cux_ship` the consumer does not yet pin. *Corrected in
  review — see §8 step 2:* both documents said "4.5.0", which is unreleased.
  The reads land in 4.1.0 and **4.4.0 is published**, so the agreement holds
  only in the weak sense that the pin has to move at all.

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
2. AuthPass's own allocation chain (`refs/buildnumbers/commits`): one
   `buildnumber: N (increment) at commit <sha>` entry per commit, not six.
3. AuthPass's README names one release's artifacts from three different
   workflows on two operating systems with one number:
   `AuthPass-setup-1.7.7_1519.exe`, `authpass-sideload-1519.apk`,
   `authpass-linux-1.7.7_1519.tar.gz`. And every `uploaded/` tag sits on its
   own commit — no commit carries two build numbers, which is the property
   this check actually establishes. (The draft gave a total of 21, which was
   both wrong and the wrong kind of claim: §2 explains that the total climbs
   with every pull request, so the invariant is stated here and the snapshot
   is dated there.)

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

**The claim must not be taken from #88 into `release-train.md`.** #88 proposed
amending that document's §9 to carry the false claim as the answer to an open
question — "the train runs before it to allocate **one** build number instead
of six". #88 was closed unmerged, so that amendment never landed; the §9 note
that *did* land states the corrected position instead. Anyone reading #88's
branch for the comparison below should know that one paragraph of it is wrong
in a way that reads authoritative.

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
the maintainer's parity goal, so this is a scope difference more than an
error.)

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

- **The second pin in step 1 was simply wrong**, and is gone (§8). The draft
  recommended one against the consumer's stated principle, justified by "step 1
  spawns `cux_ship` zero times" — which §3 and §7 of this same document
  contradict. #88 needs no such argument because it never says where
  `cux_train` is resolved from; the right answer turned out to be the wrapper
  AuthPass already has. I am recording the mistake rather than quietly fixing
  it, because the reasoning was wrong in a way that sounded careful.
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

What this document takes from #88: its emphasis on record-resumability, which
it was right to rank first, and the four findings now folded into §2 and §5.
What it leaves: stage 2, the central build number it rested on, and the §9
amendment that would have carried the false claim forward. What it adds: the
verb and `--store` semantics of §3–4, which #88 has none of. The two staging
lists then agree on stage 1 and differ only in that this one has no
"centralize the build number" stage and puts `internal` last.
