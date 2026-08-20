# The manifest as two moments: `begin` and `seal`

Status: **specified, deliberately unimplemented.** The trigger is in §11. Nothing
here exists; `cux_ship manifest write` is what ships today and stays.

This extends [build-manifest.md](build-manifest.md), which specifies the file.
This specifies *when it is written*, and the answer turns out to change what can
be checked.

## 1. The defect

`manifest write` runs after a build and is told what the build did. Fourteen
flags, of which four are facts the caller must supply because nothing else can
know them:

```
--version-name 1.1.0 --build-number 61 --git-sha 76ca8f2… --no-dirty
```

The rule that makes those four unavoidable is worth stating precisely, because a
weaker version of it — "the tree might have moved between building and writing" —
is true but not the point:

> **The manifest describes the artifact. Values baked *into* the artifact are
> knowable only by the thing that baked them.**

`versionName` is `CFBundleShortVersionString` and Gradle's `versionName`.
`buildNumber` is `CFBundleVersion` and `versionCode`. Both are compiled in. A
tool that read them from `pubspec.yaml` afterwards would report what the
repository says *now*, which under a tagged release is not necessarily what was
compiled — this repository's build script takes the version name from the git
tag, not from the pubspec.

The consequence is that the writer cannot verify its own most important claims.
It verifies the digest, because it holds the bytes. It takes `buildNumber` on
trust, and that is the field an upload is *named* by.

**And the divergence is real rather than theoretical.** If allocation fails
during a build, `0` is compiled in and `buildNumberAssigned: false` records it.
A later successful `generate` on the same commit would return a real number. So
"ask the allocator again" is wrong in exactly the case that matters, which is
why `manifest write` deliberately does not.

## 2. The inversion

Have cux_ship *decide* the values and hand them to the build, rather than be told
them afterwards.

Then it knows them by construction. `versionName` and `buildNumber` stop being
inputs it must trust, and become outputs it can hold the artifact to.

```
cux_ship manifest begin   →  allocates, resolves, writes an unsealed manifest,
                             prints the values the build must use
        (the build runs, owned by whoever builds)
cux_ship manifest seal    →  digests the artifact, checks it against what begin
                             handed out, marks the manifest complete
```

The cross-check is the point. Everything else here is bookkeeping that follows
from getting the ordering right.

## 3. Why not `prepare-build`

The obvious name for `begin` is `prepare-build`, and it is the wrong one:
cux_ship does not build anything, and a name that says it does is how a boundary
erodes. Six months later something is passing `--gradle-args` through it.

`manifest begin` and `manifest seal` say what is true — cux_ship owns the
manifest across two moments, and the build happens in between, owned by someone
else.

**This does not breach the boundary the pubspec comment in the consuming
repository states** ("everything in cux_ship acts on an artifact that exists").
That was always a loose statement of a real rule: `release finish` tags and bumps
with no artifact anywhere. The rule is that cux_ship owns **release identity** —
which version, which number, which commit — and identity is decided before an
artifact exists, by necessity. `begin` is that rule applied honestly rather than
a new exception to it.

## 4. What `begin` does

In order, because the ordering is a guard:

1. Resolve the repository — root, app directory, `.cux-ship.yaml`.
2. Read `gitSha`, `gitTag`, and the dirty state. **Before the build**, which is
   the only time the answer describes the source the artifact came from.
3. Decide `versionName`: from the tag under `--release`, from the pubspec
   otherwise. One place, rather than the same twenty lines in three build
   scripts.
4. Refuse a release whose version already shipped, by reading the tags. This is
   generic and currently lives in each build script.
5. Allocate the build number via `cux_buildnumber`, or fall back to `0` with
   `buildNumberAssigned: false` under a non-release build.
6. Write the unsealed manifest.
7. Print the values for the build to consume.

Steps 2 through 5 are the 68 non-comment lines this replaces in one consuming
repository's `build.sh`, and none of them are about that app.

## 5. Two handoffs, and both earn their place

**The unsealed manifest is the durable record.** It exists on disk between the
two calls, so a build that dies in the middle leaves evidence of what was
allocated and for which commit.

**`--shell` prints assignments, for ergonomics:**

```bash
eval "$(cux_ship manifest begin --shell --platform android ${RELEASE:+--release})"
flutter build appbundle \
  --build-name="$VERSION_NAME" --build-number="$BUILD_NUMBER" $(knobs_define)
cux_ship manifest seal --artifact "dist/android/$name"
```

`eval` of tool output is acceptable here for the same reason `tool/ship` exists:
the tool is pinned by a lockfile, and every value it prints is a semver, a hex
sha, an integer or a boolean. It should validate each against that shape before
printing, so an unexpected value fails at the source rather than becoming shell.

A `--json` form should exist too, for a producer that is not a shell script.

## 6. `sealed` is an explicit field, never an absence

An unsealed manifest must not read as a complete one. So:

```json
{ "schema": 3, "sealed": false, … }
```

**Not** "`sha256` is missing, therefore it is incomplete." Absence-as-signal is
the failure mode this project keeps meeting — an optional parameter whose null
default makes "no photographs" and "the caller forgot to load them" the same
state. A build that dies between `begin` and `seal` should leave a file that
*says* it died there, and every reader should refuse it by name.

`seal` sets it true. `BuildManifest.verify()` refuses false.

**And this forces a schema bump to 3, which is worth arguing rather than
assuming.** An optional field that reads as `true` when absent is normally
backward compatible — that is exactly how `buildNumberAssigned` was added inside
schema 2. It does not work here, and the difference is which way the ignorance
cuts.

A reader that does not know `buildNumberAssigned` treats every manifest as
assigned, which is what schema 1 manifests actually were. A reader that does not
know `sealed` treats an **unsealed** manifest as complete — and an unsealed
manifest is precisely the document that must not be uploaded from. So the field
cannot be introduced silently: it has to arrive with a number that makes an older
reader refuse the whole document rather than read the parts it recognizes.

Schema 1 and 2 documents remain complete by construction and keep reading as
sealed. Only a document that *could* be unsealed declares 3.

## 7. What `seal` checks

The digest, as today. Then the cross-check, which is new and is the reason for
the whole design:

| Claim | Read from | Failure means |
|---|---|---|
| `buildNumber` | `versionCode` / `CFBundleVersion` | the artifact is not the one this build produced |
| `versionName` | `versionName` / `CFBundleShortVersionString` | same |

That check exists today, in the wrong place: Play parses the uploaded bundle and
cux_ship compares afterwards, reporting `versionCode mismatch: the bundle
contains 0 but the build says 62`. Correct, and it costs a 25 MB upload to
learn. `seal` holds the artifact and the claimed values at the same instant.

**The cost is not known and is the main open question — §10.**

## 8. What stays with the build script

Deliberately, and this is the split that keeps the design honest:

- The actual `flutter build` / `xcodebuild` / `gradle` invocation.
- Signing-material presence checks, which are toolchain-specific.
- **Knobs** — the `--dart-define` values a particular app bakes in. The
  *mechanism* generalizes (read env var, validate shape, fold into JSON,
  warn-or-die by release mode); the per-knob sentence explaining why a release
  cannot ship without it does not, and that sentence is the whole value of the
  check. If it ever moves, it moves as a declarative table where each entry
  carries its own consequence, not as shared code that prints `KNOB_X is not
  set`.

## 9. `manifest write` survives

Not everything has a `begin`. A `.deb` repackaged from a tarball, a `.snap` built
from a `.deb` — the derivation cases in build-manifest.md §Derivation — have no
build to precede them, and their inputs genuinely are known only afterwards.
`write` is the single-shot form and remains correct for them.

So: `write` for a producer that describes something already made, `begin`/`seal`
for one that owns the build. Two commands, one schema, and the second is not a
deprecation of the first.

## 10. Open questions

- **What does reading `versionCode` out of an `.aab` cost?** It is protobuf
  inside `base/manifest/AndroidManifest.xml`, and needing `bundletool` or `aapt2`
  is exactly why one consuming build script punted on it. If it needs a Java
  toolchain, §7's cross-check is Apple-only in practice and the design is worth
  materially less. **Price this before writing any code.** The `.ipa` half is a
  zip and a plist and is cheap.
- **Does `begin` refuse a dirty tree, or record it?** Today's build script
  records it and lets the upload refuse. Keeping that is probably right, but
  `begin` allocating a number against a tree that then changes is a new wrinkle.
- **What reconciles a stale unsealed manifest?** A second `begin` on the same
  commit should overwrite it. A second `begin` on a *different* commit, with an
  unsealed one present, is either a mistake or an abandoned build, and the two
  are indistinguishable from the file alone.
- **Does the build script still need `--platform`?** `begin` needs it to name
  the output directory; `seal` could infer it from the artifact's extension.
  Inference is acceptable where it is printed — the report line already names
  `android/aab` — but two sources for one value invites disagreement.

## 11. When to build it

**Not yet, and the trigger is two things rather than a date.**

1. **`manifest write` has survived a real release.** As of 20 August 2026 it has
   run only against synthetic artifacts. The first genuine Android and Apple
   release through it will say more than another round of design.
2. **A second producer has adopted it.** The argument for `begin`/`seal` is that
   68 lines are duplicated across repositories — which is an argument about
   repositories in the plural, and one of them has not migrated. Building the
   improved shape before the second consumer touches the current one means they
   migrate onto something already being replaced, and their flavors, `.deb` and
   `.snap` are exactly the cases that would test whether the split holds.

**The precedent is worth stating because it is recent and it went the other
way.** build-manifest.md said to wait for the third producer; the writer was
built ahead of that trigger anyway, and the first review of the result was that
it had not made much easier — the call site went from 22 lines to 20, because
the parameters that stayed are the ones no tool can remove. That judgment was
correct, and it is evidence that the trigger was too.

The difference here is that the payoff is not shorter code. It is a check that
cannot be written at all in the current ordering. That is a better reason to
build something, and it is still a reason to build it when the two conditions
above hold rather than now.

Until then this document is the artifact.
