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

**The `pkg` row followed on 9 September 2026, and §2's reason for deferring it
was wrong rather than merely conservative** — §8 records that, and it is the
second estimate in this file to have been priced against the wrong file. Every
format a repository shipping both Apple platforms produces is now read.

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
| `apk` | `AndroidManifest.xml` → `versionCode`, `versionName` | zip entry + a binary-XML (axml) reader — **built**, ahead of the producer that needed it | ~170 lines: a string pool and one element's attributes |
| `pkg` | `<component>.pkg/PackageInfo` → the `<bundle>` the component says it is versioned by | `xar` for two metadata members + an XML read — **built**, §8 | ~110 lines, and no payload is decompressed |
| `dmg`, `msix`, `snap`, `deb`, archives | — | none | **trusted, and said out loud** — see below |

**A format without a reader is trusted loudly, never silently.** The check
prints its effective coverage — `cross-check: versionCode ok, versionName ok`
or `cross-check: none for format dmg — buildNumber taken on trust` — so absence
of verification is a visible state, not the same line as success. This is the
consuming project's own rule (print effective configuration, never intended)
applied here.

The macOS `.pkg` *was* the notable trusted case, on this reasoning:

> the producer's own read-back from the xcarchive (`build.sh` 617–622) covers
> the defect class at build time, and a pkg is a xar of a signed app whose
> plist is several layers deep — a reader there is real work for a platform
> whose check already exists upstream of it.

Both halves were wrong in the same way, and §8 records how. The plist is
several layers deep and **is not where the answer is** — the installer copies
the two values into its own metadata, one member of the archive's table of
contents. And a check in one producer's `build.sh` is a check the *next*
repository does not have; the line that prompted this was printed by a
repository shipping iOS and macOS from one commit, where half of every release
had artifact-level confirmation and half did not.

## 3. Where it runs: both existing chokepoints

**At `manifest write`** — built second, and only because a consumer noticed it
was missing: the writer printed no cross-check line at all, so "no reader for
apk" and "checked and agreed" rendered identically one command over from where
that distinction was the whole point. The writer already holds the artifact's
bytes — it digests them. Reading two more values out of the same file catches the defect
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

## 8. The `.pkg` reader, 9 September 2026 — the deferral was priced against the wrong file

§2 deferred this format because the app's `Info.plist` is inside a gzipped cpio
inside a xar. That is true, and it is not where the answer is.

**`pkgbuild` and `productbuild` copy the two values out of the app and into
each component's `PackageInfo`**, because the installer compares them against
what is already on disk before it will replace it. `PackageInfo` is a member of
the xar's table of contents, beside the payload rather than inside it — so the
read is two `xar` invocations and an XML parse, and no payload is
decompressed. The estimate was wrong by a whole layer, in the same direction
§5's `aab` estimate was.

That does make this a weaker reading than the `.ipa`'s: it is the *installer's*
record of the app's two values, not the app's own bytes. It is still the right
one for the defect class, because those values are written by the packaging
step and every failure this exists for — an export that rewrote
`CFBundleVersion`, a variable that evaluated empty — happens upstream of it and
shows through.

### The trap, which is the whole reason this section is long

**How many bundles a component describes depends on which tool built it**, and
the difference decides how much of this section is load-bearing. Both shapes
below are measured, on the same Flutter-shaped `.app` — an embedded
`FlutterMacOS.framework` and a login-item helper inside it.

`productbuild --component` — what `xcodebuild -exportArchive` drives, and
therefore what a Mac App Store upload is — describes the *installed* bundle and
nothing else. One element, whatever is nested inside it.

`pkgbuild --root` describes every bundle in the payload. Three elements, and
the app's neither first nor last:

```xml
<bundle path="./Runner.app/Contents/Library/LoginItems/Helper.app"
        id="…helper" CFBundleShortVersionString="9.9.9" CFBundleVersion="777"/>
<bundle path="./Runner.app/Contents/Frameworks/FlutterMacOS.framework"
        id="io.flutter.flutter.macos" CFBundleShortVersionString="3.24.0" CFBundleVersion="1"/>
<bundle path="./Runner.app" id="…" CFBundleShortVersionString="1.1.0" CFBundleVersion="65"/>
```

There, "the first bundle carrying both attributes" answers with a login item's
777, which compares unequal and **refuses a correct release** — the plausible
wrong answer this whole file exists to prevent, arriving in a new format.

**On the release path, though, this is defensive rather than load-bearing, and
the honest version says so.** Against a one-`<bundle>` `-exportArchive`
package, picking the first element would also have been right. The selector is
kept for the reason `unusableBuildState` keeps a branch two live runs never
reached: the other shape is real and one `pkgbuild` away, the check is one
comparison, and the asymmetry runs the wrong way — dropping it costs a
framework's version reported as a build number and a correct release refused.
An unexercised branch that reads as routine is the one somebody later deletes
as dead. Said here because the three-bundle example above would otherwise be
taken as the shape releases have, and it is not.

The selector is `<bundle-version>`, which names the identifier the component is
versioned by. That is the installer's own designation rather than a heuristic
over the file: it is what the installer reads to decide whether what is on disk
is older.

**The property that makes it safe is not "`<bundle-version>` always names the
app" — it is that every way it can fail to is a refusal or a wrong answer in
the safe direction.** That is the claim to hold this to, because it survives a
package neither the author nor the reviewer has seen, and the stricter one does
not. Enumerated:

| The file says | This does |
|---|---|
| a component that is a framework or plugin, not an app | reports *that* bundle's version, which compares unequal — refused, in the safe direction |
| several designated bundles | refuses; choosing would be a guess |
| several components each designating one | refuses, naming both paths |
| a component designating nothing (scripts only) | contributes nothing, and does not mask a component that does |
| a designated identifier it does not then describe | refuses; the file is not being read as the structure it is |

None of those is silent, and none of them is trust.

**The top-level `Distribution` is not read, and it is the easier file to
find.** It carries the same three bundles with the same two attributes, in the
same order, and *without* the `<bundle-version>` marker to pick between them —
so it offers the trap and not the way out. It is also absent from a flat
component package, which `pkgbuild` alone produces. The test fixtures build one
anyway, so that a reader which started to prefer it would be caught.

### The gate, in §5's shape

Four packages built locally and read, all reporting `1.1.0` / `65`:

| Built by | `<bundle>` elements | Shape |
|---|---|---|
| `productbuild --component`, plain app | 1 | product archive |
| `productbuild --component`, app with a framework and a login item inside | **1** | product archive |
| `pkgbuild --root`, the same app | **3** | flat component, `PackageInfo` at the top |
| `productbuild --package` over that component | 3 | product archive |

The two bold rows are the same `.app` and disagree, which is the whole of the
section above — and the first of them is the row that already said an
`-exportArchive` package would describe one bundle, four hours before anybody
opened one.

Confirmed independently by `pkgutil --expand-full` and `plutil -extract` against
the app's own `Info.plist` **inside the payload** — the file the reader
deliberately does not open — which agreed, and against the helper's, which is
the 777 the reader must not return.

One more thing was measured and then declined: `<pkg-info>` carries a top-level
`version`, and it is the *package's*, set by `pkgbuild --version` independently
of the payload. A package built `--version 9.9.9` around an app carrying 1.1.0
/ 65 records exactly that disagreement. Two sources that can differ need a rule
for differing; the bundle's is the one the installer compares against what is
on disk, so the reader has one source rather than a tie-break.

### The assumption, and its retirement four hours later

This section shipped saying, as §5's does: *these packages were built by
`pkgbuild`/`productbuild` directly rather than by `xcodebuild -exportArchive`,
which is what a real Mac App Store upload comes from. Xcode drives the same two
tools, so the metadata is expected to be identical; that is an argument rather
than a measurement.*

**It is now a measurement.** Against `how-it-went` 1.1.6 (169) — the
`-exportArchive` package from the 9 September TestFlight upload that prompted
all of this:

```xml
<pkg-info … identifier="design.codeux.howitwent" version="1.1.6"
          generator-version="InstallCmds-864.12 (25F84)" install-location="/Applications">
    <payload numberOfFiles="124" installKBytes="64812"/>
    <bundle path="./How It Went.app" id="design.codeux.howitwent"
            CFBundleShortVersionString="1.1.6" CFBundleVersion="169"/>
    <bundle-version>
        <bundle id="design.codeux.howitwent"/>
    </bundle-version>
```

Every structural claim above holds: the metadata is in the table of contents
with `Payload` beside it untouched, `<bundle-version>` names exactly one
identifier, and the `<bundle>` carrying it has both attributes and the right
values.

**And it carried a negative result, which is why the section above was
rewritten.** One `<bundle>` element against 124 payload files. The three-bundle
hazard is real and is a `pkgbuild --root` shape, not the shape an App Store
upload has — so the doc had been presenting the wrong example as typical. The
evidence for that was already in this repository's own gate run, in the
`productbuild --component` package that also described one bundle while
containing three; it was recorded and not drawn on.

`generator-version` identifies the Xcode toolchain. Nothing reads it; noted in
case provenance ever matters.

### Two consequences worth stating

**A test fixture's format can stop being unreadable without the fixture
changing.** `build_manifest_write_test.dart` and `manifest_cli_test.dart` both
used a text file named `.pkg` as their stand-in artifact, chosen precisely
because pkg had no reader — a comment in each said so. Both moved to `dmg`.
That is the second time this has happened: they were `.aab` before, and passed
only because a reader that could not open its input reported "no reader for
aab". If a `dmg` reader is ever written they move again.

**`pkg` is not added to the "found neither is a refusal" list.** That refusal
is keyed to `apk` and `aab` because those readers walk a binary layout and can
desync, so "found neither" means a lost parser. This one locates its element by
the identifier the file itself designates, so an attribute that is not there
was not written — the `ipa` case, and reported as taken on trust naming the
component. Adding pkg to that list would turn an unusual package into a failed
release.
