# Review: the `begin`/`seal` split rests on an inverted premise

Status: **review of the superseded `begin`/`seal` design**, which occupied
`build-lifecycle.md` and is now at `ec62f18` in this repository's history.
Written against that document, `build_manifest.dart`, `manifest_cli.dart`,
`play/cli.dart`, `runner.dart`, and the one migrated consumer's `tool/build.sh`,
`tool/upload.sh` and `tool/_common.sh`.

Verdict: **replace** — and it was, so section references below point at a file
that no longer says those things. [build-lifecycle.md](build-lifecycle.md) is
now the design this review argued for.

Kept rather than deleted with the thing it killed, because the reasoning
outlives the verdict. The inverted premise it identifies — treating baked-in
values as unknowable to anyone but the builder, when they are precisely the
values recoverable from the artifact forever — is an easy mistake to make twice.

## The verdict in one paragraph

The document's central claim — that `versionName` and `buildNumber` "cannot be
verified at all in the current ordering" (§11) — is false, because the rule it
rests on (§1) is stated backwards. Values baked into the artifact are precisely
the ones that *can* be verified after the fact, by anyone, forever: they are in
the bytes, and §7's own table names where. The fields that genuinely cannot be
verified afterwards — `gitSha`, `dirty` — are not verified by `begin`/`seal`
either; the split moves the trust boundary without removing it. What the
document correctly wants, the cross-check of §7, is writable today inside
`manifest write` and `BuildManifest.verify()`, with no new commands, no unsealed
state, no reconciliation rules, and no schema bump. That is the design worth
having, and it is small enough that most of it is a table of per-format readers.

## 1. The rule in §1 is inverted

> The manifest describes the artifact. Values baked *into* the artifact are
> knowable only by the thing that baked them.

Exactly wrong, and the inversion is load-bearing for the whole document. A
baked-in value is recoverable from the artifact at any time — that is what
"baked in" means. `versionCode` is in `base/manifest/AndroidManifest.xml`;
`CFBundleVersion` is in `Info.plist`; both survive signing, travel with the
file, and answer the same question next year. The values knowable *only at build
time* are the ones **not** baked in — `gitSha` and `dirty` — and
build-manifest.md's own "What it is for" section says so, listing exactly those
(plus the digest-as-written) as the three things "cannot be recovered from the
artifact at any price once the build is over." `versionName` and `buildNumber`
are not on that list because they do not belong on it.

What §1 actually establishes is narrower and true: the values cannot be
re-derived from the *repository* afterwards, because pubspec and the tags may
have moved. Correct — so derive them from the artifact instead. The document
conflates "the repository is not a valid source later" with "no source exists
later," and the second does not follow. §7's table refutes §1 by naming the
read sources; it just hands the reading to a command that runs at a different
time, as if the bytes were only legible at the moment of sealing. A reader does
not care when it runs.

## 2. `begin`/`seal` does not verify what actually cannot be verified

The honest ledger, field by field:

| Field | Today | Under `begin`/`seal` |
|---|---|---|
| `versionName`, `buildNumber` | trusted — **fixable by read-back, no reordering** | cross-checked at `seal` |
| `gitSha`, `dirty` | trusted (producer obligation 1) | **still trusted** — `begin` records the tree at begin time; nothing proves the build consumed that tree |
| `sha256` | verified (writer holds the bytes) | verified |

The right column's only genuine gain over "today plus read-back" is empty.
`begin` reading the tree before the build is something the consumer's `build.sh`
already does in three lines (`git rev-parse`, `git status --porcelain`, lines
103–109), and nothing in either ordering closes the gap between "what the tree
was when we looked" and "what the compiler read." The inversion's chief output
is bookkeeping — the document even says so in §2 ("everything else here is
bookkeeping") — without noticing that the cross-check it keeps as the point
does not need the inversion.

## 3. The check the document wants already half-exists, in the places it belongs

- **Apple, at build:** `build.sh` lines 617–622 read
  `ApplicationProperties.CFBundleVersion` back out of the xcarchive and die on
  mismatch. That is §7's check, running today, in the current ordering — direct
  evidence that ordering was never the obstacle.
- **Android, at upload:** `play/cli.dart` 1479–1485 compares the versionCode
  Play parsed against `--build-number` *before the draft edit is committed*, so
  nothing publishes on a mismatch. The failure is loud and pre-release; the
  cost is the upload bandwidth.
- **Every `--manifest` upload:** `runner.dart` `_manifest()` runs
  `BuildManifest.verify()`, holding the artifact and every claimed value at the
  same instant — which is the exact property §7 attributes to `seal`. The
  insertion point for the local cross-check already exists and already runs.

So "a 25 MB upload to learn" is the price of one gap on one platform: the
`.aab`'s versionCode, unread locally because it is protobuf. That is an
implementation cost worth pricing (§10 asks the right question), not an
ordering defect — and the answer prices low: aapt2's `Resources.proto` is
public and stable, the walk needed is one element and two attributes, and the
repository already prefers shelling out to a host tool over growing a
dependency (`deps.dart` line 215 shells to `tar` for the same reason). No Java
toolchain, no bundletool. The alt document scopes it.

## 4. The unsealed manifest is negative value

Two justifications are offered (§5), and neither survives contact with what
exists:

- **"The durable record" of what was allocated.** `cux_buildnumber` already
  *is* that record — the allocation lives in `refs/buildnumbers/commits` and
  `refs/notes/buildnumbers`, per commit, shared through origin, recoverable by
  `get` from any machine. A JSON file in `dist/` is a strictly worse copy of
  state git already holds durably.
- **A file on disk between two commands.** In the only migrated consumer, that
  file cannot even live where the sealed one does: `build.sh` runs
  `rm -rf "$DIST/android"` *after* the build, immediately before copying the
  artifact in (lines 507–508, 637–638). An unsealed
  `dist/<platform>/manifest.json` written by `begin` is deleted by the
  producer's own dist-cleaning between `begin` and `seal`. So integration
  forces a new location convention on day one — on top of the reconciliation
  rules §10 admits are unsettled. New failure surface, purchased for a record
  nobody needed.

## 5. The `--shell` handoff is a silent-failure machine

§5's happy path is:

```bash
eval "$(cux_ship manifest begin --shell …)"
```

Under `set -e`, a command substitution that fails *inside an argument* does not
stop the script: `begin` dies, prints to stderr, the substitution yields an
empty string, `eval ""` exits 0, and the build proceeds with `VERSION_NAME` and
`BUILD_NUMBER` unset — `--build-name= --build-number=` — producing a plausibly
numbered bundle with versionCode 0/1. That is the exact shape the consuming
project's SILENT-FAILURES.md exists to hunt: absence and success rendered
identical. It is mitigable (`vals=$(…) || die; eval "$vals"`), but the design
document teaches the broken idiom as its example, and a design whose canonical
usage needs a footnote to fail loudly has put the complexity in the caller —
the same critique that produced this document in the first place.

## 6. The schema-3 argument is escapable even on its own terms

§6 is right that absence-as-signal is the enemy, and right that an old reader
must never mistake an unsealed manifest for a complete one. It then concludes a
schema bump is forced — without considering the standard idiom: **the unsealed
file is not named `manifest.json`.** Write `manifest.building.json` (carrying
`"sealed": false` for humans and reconciliation), rename atomically at seal. An
old reader then fails with `no build manifest at <path>` — the loudest refusal
the toolchain has, already implemented, zero schema churn. That is not
absence-as-signal within a document; it is the contract name not existing until
the contract holds, the same shape as write-temp-then-rename. Under the
replacement design the point is moot — there is no unsealed state — but §6's
"this forces a bump to 3" is false either way, and it is the document's most
argued section.

## 7. What the document gets right

- **§3, the boundary.** "cux_ship owns release identity, not builds" is correct
  and well argued — and it also disposes of the alternative this review was
  asked to weigh, `cux_ship build -- flutter build …`. Wrapping the build makes
  cux_ship own the invocation §3 rightly refuses, and buys nothing: a wrapper
  still cannot prove the child honored the values it was handed; only read-back
  proves that, and read-back needs no wrapper.
- **§9.** `write` surviving as the single-shot form for derivation cases is the
  right call and carries into the replacement unchanged.
- **§8.** Keeping knobs and signing checks in the build script, with the
  declarative-table escape hatch, is right.
- **§11's restraint, half of it.** Waiting for a real release and a second
  consumer before *building* is genuine learning from the manifest-write
  episode, not over-correction — the 22→20-line verdict was earned. But the
  closing line, "Until then this document is the artifact," preserves a wrong
  premise as the plan of record. The correction is not to build sooner; it is
  to replace the artifact. And note the replacement mostly dissolves the
  trigger: read-back is an addition to code that ships today, gated only on
  pricing the `.aab` reader, not on AuthPass.

## 8. What this review found in the shipped code along the way

Both support §11's first trigger — `manifest write` has not survived a real
release — more concretely than the document knew:

- **The only migrated consumer cannot complete a build.** `build.sh` line 103
  captures `GIT_SHA=$(git rev-parse --short HEAD)` and passes it to
  `manifest write`; `writeBuildManifest` refuses anything but
  `^[0-9a-f]{40}$` (build_manifest.dart line 281). Every real
  `tool/build.sh` run dies at `write_manifest` — after allocating a build
  number and finishing a multi-minute build. Loud, so not the dangerous kind,
  but proof that the writer and its one consumer have never run end to end.
  Fix in the consumer: capture the full sha, shorten only for display.
- **The writer contradicts the spec on `buildNumber`'s type.**
  build-manifest.md says "JSON integer"; `writeBuildManifest` takes a `String`
  and emits `"buildNumber": "53"` (the write tests pass `'53'` throughout,
  while `build_manifest_test.dart` line 36 reads an integer `51`). Today's
  consumers survive both — `manifest_get` is a grep, the Dart reader
  stringifies — but AuthPass writing a second producer against the spec's
  prose would produce the disagreement the single writer exists to prevent.
  Decide which is canonical before then.
