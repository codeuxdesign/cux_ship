# Verify the manifest by reading the artifact, not by reordering the write

Status: **proposed**, and it replaced a different design that occupied this file
for about an hour. That one split the write into `manifest begin` before the
build and `manifest seal` after it; it is at `ec62f18` in this repository's
history, and [build-lifecycle-review.md](build-lifecycle-review.md) is the
review that dismantled it. Both are kept because the argument is more useful
than the conclusion: the superseded design rested on a rule stated exactly
backwards, and §1 below is that rule the right way around.

**Built, 21 August 2026, and shipped in `cux_ship` 3.4.0.** The cost question
that gated §2's `aab` row was answered by writing the reader — §5 records the
run, and the estimate was pessimistic in three ways. `verify()` now cross-checks
every `--manifest` upload, and a format with no reader says so on its own line.

Its first real use was a release: it read `versionCode 65` out of a 69 MB bundle
in 0.77 s including VM startup, where the same check previously cost a transfer
to Play. No new commands, no schema change, no state between commands, as
designed.

This extends [build-manifest.md](build-manifest.md), which specifies the file.
This specifies *what is checked against the artifact*, and the answer is: more
than the digest, in the same two places the digest is checked now.

## 1. The defect, stated the right way around

The manifest's fields fall into two classes, and the split decides everything:

- **Recorded facts** — `gitSha`, `dirty`. Knowable only at build time, from the
  tree. No reader of the artifact can ever confirm them; no ordering of
  commands changes that. They are producer obligations (build-manifest.md,
  Producer requirements 1) and stay that way.
- **Baked facts** — `versionName`, `buildNumber`. Compiled into the artifact,
  therefore recoverable *from* the artifact by anyone, at any time. That they
  cannot be re-derived from the repository afterwards — pubspec moves, tags
  move — is true and irrelevant: the artifact is the source, and it is sitting
  next to the manifest.

Today the baked facts are taken on trust, and the trust has already failed in
the way that matters: a bundle containing versionCode 0 beside a manifest
claiming 62, discovered by Play after the upload (`play/cli.dart` 1479). The
defect class is "the build did not honor the values the script passed" — an
export step rewriting `CFBundleVersion`, a Gradle override, a variable that
evaluated empty, a stale artifact copied over a fresh manifest's neighbor. The
digest check cannot see any of these, because the manifest honestly describes
the wrong artifact.

The fix is not to reorder the write. It is to **read the baked facts back out
of the bytes and refuse a manifest that disagrees with its artifact.**

## 2. The check, per format

| Format | Read from | How | Cost |
|---|---|---|---|
| `ipa` | `Payload/*.app/Info.plist` → `CFBundleVersion`, `CFBundleShortVersionString` | zip entry + `plutil` (Apple artifacts are only produced on macOS) | trivial |
| `aab` | `base/manifest/AndroidManifest.xml` → `versionCode`, `versionName` | zip entry + a minimal aapt2-proto walker, **§5** | to be priced |
| `apk` | binary XML (axml), a different encoding than the `.aab`'s proto | separate reader | deferred until a producer ships `.apk` — AuthPass's sideload and Amazon flavors will, so the deferral has a known end |
| `pkg`, `dmg`, `msix`, `snap`, `deb`, archives | — | none | **trusted, and said out loud** — see below |

**A format without a reader is trusted loudly, never silently.** The check
prints its effective coverage — `cross-check: versionCode ok, versionName ok`
or `cross-check: none for format pkg — buildNumber taken on trust` — so absence
of verification is a visible state, not the same line as success. This is the
consuming project's own rule (print effective configuration, never intended)
applied here.

The macOS `.pkg` is the notable trusted case, and it is acceptable: the
producer's own read-back from the xcarchive (`build.sh` 617–622) covers the
defect class at build time, and a pkg is a xar of a signed app whose plist is
several layers deep — a reader there is real work for a platform whose check
already exists upstream of it. If that producer-side check ever proves
insufficient, this table is where the reader goes.

## 3. Where it runs: both existing chokepoints

**At `manifest write`.** The writer already holds the artifact's bytes — it
digests them. Reading two more values out of the same file catches the defect
at the earliest moment it exists, minutes after the build, before an upload is
attempted and before anyone walks away believing `dist/` is good. A mismatch is
a refusal: the manifest is not written, and the message names both values and
both sources.

**At `BuildManifest.verify()`.** Every `--manifest` upload already calls it
(`runner.dart`, `_manifest()`), holding the artifact and every claimed value at
the same instant. Re-checking here catches what write-time cannot: a `dist/`
whose artifact was swapped for another *correctly built* one — same digest
discipline, wrong build — and it makes the check hold for manifests written by
older writers or by hand. The digest is verified once (it is the expensive
half, 69 MB on one project); the baked-fact read costs one zip entry.

Play's post-upload comparison (`play/cli.dart` 1479) stays. It is the check of
record against what Play *itself* parsed, and it becomes the backstop it should
have been rather than the first line.

Nothing about the interface changes: same flags, same schema 2, same sidecar.
A producer that lies about `--build-number` now gets refused; that is the whole
observable difference.

## 4. What is deliberately not built

- **No `begin`, no `seal`, no unsealed state, no schema 3.** The cross-check
  was the stated point of the split, and it lands above without any of it. The
  durable record of an allocation is `cux_buildnumber`'s refs, which is where
  it already lives; a half-written JSON file in a directory the build script
  `rm -rf`s is not a record, it is a reconciliation problem.
- **No wrapping the build** (`cux_ship build -- …`). cux_ship owns release
  identity, not builds — build-lifecycle.md §3 argued this correctly and it
  survives the replacement. A wrapper also proves nothing a read-back does not:
  owning the invocation still cannot show the child consumed the values.
- **No consolidation of the 68 lines yet.** The version-name decision, the
  already-shipped refusal and the allocation call are genuinely duplicated
  intent — and consolidating them is exactly the shape the manifest-write
  episode just graded: parameters moving house, 22 lines to 20. If a shared
  home is ever justified, its shape must come from AuthPass's real build
  scripts (six flavors, mutually blind CI jobs, cross-machine `dist/`), not be
  guessed ahead of them, and it is a *value-resolver* concern, separate from
  the manifest. Deferred on the same trigger build-lifecycle.md §11 names — a
  real release survived, a second consumer migrated — which this design keeps
  for that question and dissolves for the verification one.

## 5. The one gate: price the `.aab` reader

Inherited from build-lifecycle.md §10, scoped down. The manifest inside an
`.aab` is aapt2's protobuf XML (`Resources.proto` — `XmlNode`, public, stable
across AGP versions because bundletool itself depends on it). The walk needed
is: one zip entry, descend to the `manifest` element, read two attributes —
`versionCode` is a compiled int, `versionName` a string. That is a
minimal-proto reader on the order of a hundred lines of Dart with no new
dependency; for the zip entry, shelling out to `unzip -p` follows the
repository's own precedent of preferring a host tool over a library
(`deps.dart` shells to `tar`, with its reason in a comment).

The gate is honest verification, not feasibility: **write the walker, point it
at a real signed `.aab`, and confirm the two values against an independent
decoder**, before the check is allowed to refuse anything.

### Run, 20 August 2026 — the gate is passed, and the estimate was pessimistic

Against the first real signed bundle this project has produced: 69 MB,
`how-it-went-1.1.0-65.aab`, AGP with `compileSdkVersion 36`.

```
versionCode = 65        versionName = 1.1.0
```

Confirmed against `protoc --decode_raw`, which needs no schema and shares no
code with the walker. Two further attributes were read in the same pass —
`package` (no namespace, exercising that branch) and `compileSdkVersion` — and a
name that does not exist came back absent rather than fabricated, so the walk is
parsing rather than returning two lucky hits.

Three corrections to what this section assumed:

- **The walk is two levels, not five.** `XmlAttribute.value` (field 3) already
  carries `"65"` as a rendered string, *alongside* the compiled
  `compiled_item → prim → int_decimal_value`. Nothing needs to decode `Item` or
  `Primitive`. The walk is: `XmlNode.element` (1) → repeated
  `XmlElement.attribute` (4) → `namespace_uri` (1), `name` (2), `value` (3).
- **~130 lines including a `main()` and two wire types the walk never meets.**
  The production reader is smaller. No new dependency; `unzip -p` for the zip
  entry as proposed.
- **`bundletool` was never the alternative, and neither is `aapt2`.** Neither is
  installed here, and `aapt2 dump xmltree` *refuses an `.aab` outright* — "could
  not identify format of APK" — so the hand-rolled reader is not a shortcut
  around a heavier tool, it is the only local option short of installing a Java
  toolchain to answer a question a hundred lines answers.

So the `aab` row of §2 graduates from "to be priced" to priced and cheap, and
the design's main check covers both stores rather than Apple alone.

**One assumption is untested and should be said.** This is one bundle from one
AGP version. The layout is expected to be stable because bundletool itself
depends on `Resources.proto`, but that is an argument rather than a measurement.
The first `.aab` from a different AGP that this refuses will say whether the
argument held — and the failure mode is a loud refusal, not a wrong answer,
which is the right way round.

## 6. What stays unverifiable, so nobody re-litigates it

`gitSha` and `dirty` are trusted in every design, including the one this
replaces. `begin` would have recorded the tree at begin time; nothing proves
the build compiled that tree, and nothing can — a signed artifact carries no
commit. The mitigations are the ones already in force: producer obligation 1
(capture before the first mutating step), the writer's dirty-recheck warning,
and the provenance record at upload. A future embedded card (build-manifest.md,
cards) narrows it further; no command ordering does.

## 7. Consumer fixes needed before any of this matters

Both found while reviewing, both independent of this design, both blocking the
first real release through `manifest write`:

1. **`tool/build.sh` passes a short sha to a writer that refuses one.** Line
   103 is `git rev-parse --short HEAD`; `writeBuildManifest` requires 40
   characters. Every real build dies at `write_manifest`, after the build
   number is spent and the build is done. Capture the full sha; shorten only in
   display strings.
2. **`buildNumber`'s JSON type.** The spec says integer; the writer emits a
   string. Pick one — the writer emitting an integer matches the spec and what
   schema-1 heredocs wrote — and pin it with a test on the raw JSON, before
   AuthPass writes anything against the prose.
