# Releasing cux_ship

`tool/release.sh <package>` does it. This is the part the script cannot enforce,
and the reasoning behind what it does enforce.

## Make a release commit

**A commit whose only job is the version.** Nothing else in it.

```
Call it 3.3.0 — <what a reader needs to know about this release>
```

Not because it reads nicely. Because it makes *the commit that set the version*
and *the commit that was published* the same commit, and everything else here
follows from those two being the same.

They used to be, and it decayed without anyone deciding it:

```
2e7488e  Call it 2.3.2 — it adds a message, not a surface     ← dedicated
a7aafa0  document the empty default, and call it 3.0.0        ← folded in
fcca99d  refuse an ambiguous project instead of picking…      ← version invisible
8604e62  Enforce the declaration where it reaches Apple…      ← version invisible
```

By 3.2.0 the version was written on a feature commit **seven commits before the
publish**, and those seven were not cosmetic — they carried the fixes for two
checks that would have failed listings a store was actively serving. A tag at
the version-setting commit would have pointed at code predating all of them; a
tag at the published commit is right. Both are defensible readings, which is the
problem: the release commit removes the question rather than answering it.

`tool/release.sh` refuses to publish when the version was not set by `HEAD`.

## Tag what was published

The rule the script follows, and the fallback if you ever publish by hand.

- `cux_ship` → `v3.2.0`
- everything else → `cux_ship_verify-v1.9.0`

**The prefix is not tidiness.** The bare series is cux_ship's own, and it goes
back to `v1.0.0` — so `v1.9.0` names *cux_ship* 1.9.0, which exists. Tagging
cux_ship_verify 1.9.0 as `v1.9.0` would put an existing cux_ship version on a
commit that has nothing to do with it. The two series were unambiguous only
while both packages sat at 1.7.1 together; they diverged when cux_ship went to
2.x and verify did not.

`cux_ship_verify` 1.6.0 through 1.8.0 are **deliberately untagged**. None had a
dedicated release commit, so their publish points cannot be recovered without
guessing, and a tag that guesses is worse than an absent one — an absent tag is
a gap, a wrong tag is a claim.

## Publish the dependency first, then wait

`cux_ship` depends on `cux_ship_verify`, so verify goes first. That is obvious.
What is not:

**Wait for the dependency to be resolvable before publishing the dependent.**
pub.dev's web API reports a new version as live well before the resolver will
accept it. In the 3.2.0 release both packages were published minutes apart and
`cux_ship 3.2.0` was accepted while its own `^1.9.0` constraint could not yet be
satisfied by any client. Nothing broke, because nobody resolved in that window —
the ordering protected consumers by luck rather than by design.

Check with a real resolution, not the API:

```bash
cd "$(mktemp -d)" && printf 'name: probe\nenvironment:\n  sdk: ^3.12.2\ndependencies:\n  cux_ship_verify: ^1.9.0\n' > pubspec.yaml
dart pub get   # succeeds only once the resolver has it
```

It took about twenty seconds, against the "up to 10 minutes" the upload warns
about — but the API said yes long before that, and the API is not what governs.

## What is not automated, and why

**Nothing warns that a version line is stale, and nothing warns that a publish
left no tag.** `dart pub publish` refuses a dirty tree, which is a real guard,
and is silent on both.

The first is closed by the release commit above, and checked by the script. The
second is closed by the script tagging immediately after publish and then
asserting `git describe --exact-match HEAD` — because there is nowhere else it
can live. CI does not know a publish happened, and by the time it could, the
untagged commit is already the released one.

That gap is why three of the five releases before this document had something
wrong here, and why none of them broke anything.
