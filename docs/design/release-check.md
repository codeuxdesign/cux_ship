# `release check` — has this version already gone out, asked of the repository

Status: **draft, second pass after review**, 21 August 2026. Not built.

Two repositories answer this question in shell, the answers have drifted, and one
of the two was wrong until this afternoon — it read an upload tag as a release
and would have refused a build for a release that never happened. This proposes
moving the answer into `cux_ship`.

**The first pass of this document contained the exact defect it warns against**,
and §6 is where it was found: it forbade contacting `origin`, and a default CI
checkout has no tags, so the check would have passed forever without once
running. That is recorded here rather than quietly corrected, because it is the
same failure as everything else in this file's lineage — a check that reports
success when it did not run.

## 1. The question, and who asked it

> **Given a version I am about to build, does *our own record* say that version
> has already gone out?**

Asked by `tool/build.sh` in How It Went and in Hold the Wheel, on every untagged
release build. Not asked by AuthPass, ever — see §3.

**The oracle is our git, and the distinction is ownership, not the network.**
The alternative is to ask the store: Play can report the live track's
versionName, and it is authoritative about what it holds. Rejected, because:

- **A store is a downstream consumer of a release, not the record of one.** A
  repository that can only answer "what did we ship" by asking Google has
  outsourced its own history to a company with no obligation to keep it.
- **There is more than one store.** Play, App Store, Amazon, F-Droid, direct
  download. If the store is the truth then there are five truths — and one
  project's real numbers say so: Play internal at 2168, Amazon at 2096, macOS on
  a sequence of its own. Nothing reconciles those except the repository.
- **It is the failure this toolchain keeps finding.** *The thing you can query
  is not the thing that governs you.* A store API answers about itself, at one
  moment, per destination.

**`origin` is not a store. It is where the repository lives.** The first pass
widened "do not depend on an external store" into "do not contact the network",
and those are different rules with opposite consequences. A local clone is a
*cache* of the repository; treating the cache as the record is how the check
becomes confident and wrong. So this reads `origin` and prefers its answer — §6.

The store's refusal stays where it belongs: the **last** line, not the first.

**What this oracle cannot tell you, stated plainly.** Git records what we
*sent*; a store records what users can *get*. The upload record is written
before the store is contacted and means "attempted", not "accepted" — so a tag
can outlive an upload the store rejected, and git-side answers over-report. A
periodic git-versus-store *diff* is what catches that, and it is neither oracle
alone. Out of scope here, worth building, and named so this document does not
imply a completeness it has not got.

## 2. What it replaces — one check of four, and not the others

`tool/build.sh` runs four checks in this area. Only the last is a version
comparison:

| | Check | Path |
|---|---|---|
| **A** | the tag and `pubspec.yaml` must not disagree | tagged |
| **B** | the tag must exist on `origin` | tagged |
| **C** | an untagged HEAD is refused | untagged — Hold the Wheel only; How It Went deleted it |
| **D** | the version must exceed the highest released | **untagged only** |

**`release check` takes D. A, B and C stay in the script**, where the pubspec and
the working tree are.

**D fires only on the untagged path, in both repositories.** The untagged case is
the internal track: every commit on `main` publishes, carrying whatever version
`pubspec.yaml` says, with no tag. That is the only route by which a version can
silently go backwards. On the tagged path, A already catches the disagreement.

Note for §6: **check B already runs `git ls-remote --tags origin`**, guarded by
`git remote get-url origin`. Contacting origin is existing practice in the very
script this replaces one check of, which is worth knowing before treating it as
a new dependency.

## 3. Who does not want it, and why that is final

AuthPass has **no version-level guard at all**. Its guards ask each store how
high a build number it holds, and its policy is that a version is never spent.

That is not abstention, it is structure: AuthPass's release is per-destination,
while its git record is deliberately one `uploaded/` tag per commit, so git
*cannot express* which destinations hold what. A git-oracled check is therefore
a tool for repositories whose release is a single event. Theirs is not.

**"Structural" does not mean permanent, and the reopening condition is already
written down.** The premise above rests entirely on one tag per commit — and
`BUILD-TAGS` §8.1 records that as a *decision*, with AuthPass supplying the
constraint that settled it, and names exactly what it gives up: git can no longer
answer *"did macOS ever ship from this commit?"*, only *"something did"*. Per-store
records were on the table as a real capability and declined for cost, not
refused as impossible. `upload-record-scope.md` files the same question from the
other end.

So: **final while the record stays one tag per commit; reopened by a per-store
opt-in, which two documents already contemplate.** A closed door with no named
condition is what stops the conversation happening when the condition arrives.

**And even then adoption would be a choice rather than a consequence.** A richer
git record would make this *possible* for AuthPass without making it *right*:
their guards ask what a given destination currently holds, and that is a
question about a store's present state which a git record only ever
approximates. The structural argument is the reason it cannot be adopted today;
it is not the only reason it might not be adopted the day it could.

**Final for AuthPass, and for the tuple — and for nothing else.** The
`(version, buildNumber)` tuple that `BUILD-TAGS` §6 asked for was asked for *by
AuthPass*, and is not built. But the first pass of this document went further and
concluded that plain version comparison was therefore correct, which §4 shows is
wrong. That conclusion is reopened; this paragraph closes the tuple question
only.

## 4. The comparison, and the two lanes

Given `--version X`:

1. Collect every tag matching a configured release format (§5), from origin
   where reachable (§6).
2. Parse each into a `Version`; skip and report what does not parse.
3. Take the **highest**.
4. Refuse when `X <= highest`, **unless this build is continuing that release**.

**Against the highest, never against a tag named for X.** Asking "does `vX`
exist" answers *no* for a version that was attempted, failed, and had its tag
deleted — then ships it behind a higher one. That nearly published 1.0.1 after
1.0.2 was live.

**`<=`, and equality is the case that matters.** `sort -V` cannot distinguish
"the same" from "newer", so the shell tests equality separately. Dart has a real
`Version` with a working `>`, which makes it easy to port this as `X > highest`
and silently stop refusing the exact case the check mostly exists for.

### The staggered-release lane, which the first pass got wrong

**The lane is a property of when a consumer writes its release tag, not of the
check** — and the two consumers answer differently. In How It Went the tag is
written the day of the upload, by hand per `SHIPPING.md`; nothing there calls
`release finish`. In Hold the Wheel it is written at promotion, by
`release finish` from `promote.sh`. `build.sh` takes its tagged path only for a
rebuild of the *identical* commit. And `SHIPPING.md` documents multi-store
divergence as a deliberate workflow — same version, new build numbers, fixes
from a release branch, per-platform tags specified for it (specified only —
none has ever been written, §5).

For a tag-at-upload consumer those together mean: **the moment 1.1.0 is
submitted anywhere, every later build of 1.1.0 from a different commit is
refused** — an RC2 after review feedback, a platform-scoped fix, the ordinary
staggered rollout. And the refusal advises "bump past it", which is exactly
what `SHIPPING.md` forbids in that lane.

For a tag-at-promotion consumer the lane cannot arise: by the time `v1.1.0`
exists, 1.1.0 has finished shipping, and a later build of it is exactly the
mistake the refusal names. Hold the Wheel never has cause to pass the flag
below. So the check stays neutral — it compares against tags, and what
continuing a release *means* is decided by whoever writes them; encoding either
consumer's answer here would encode a habit the other has not got
(`release-tagging.md` §6 holds the same line from the writing side).

This is latent in the shell today only because no version has yet shipped
staggered. It is not hypothetical: the per-platform tag convention exists
*because* platforms ship one version at different times.

**The tuple does not fix this, and would break the thing that works.** Allowing
same-version-higher-build unconditionally deletes the forward-lane equality
refusal, which is the check's main job. The policy is **lane-dependent** — the
same comparison is right in one lane and wrong in the other — and no comparison
of `(version, build)` can express a lane.

**Proposed: the caller names the prior submission it is continuing.**

```
cux_ship release check --version 1.1.0 --continues-build 43
cux_ship release check --version 1.1.0 --continues-commit <sha>
```

Not a boolean. `--allow-untagged` was a boolean, was passed by every invocation
that ever ran, gated nothing, and was deleted for it — a flag that is always
passed is not a check.

**And not `--continues v1.1.0`, which this document proposed until the flag was
run against its own bar.** Its validation was that the named tag exist and name
the version being built — so the only value that can ever validate is
`v$VERSION`, derivable from `--version` by concatenation, and a script can pass
it unconditionally. Worse than a boolean: on the lane the check mostly exists
for — `main` after a merge-back, with a forgotten pubspec bump — `v$VERSION`
*does* exist and *does* name the version being built, so the unconditional flag
validates precisely when the check should refuse. That is `--allow-untagged`
with a longer spelling, proposed three paragraphs after citing
`--allow-untagged` as the thing not to build.

The repair is to demand a fact the forward lane does not have: **which earlier
submission of this version is being continued.** `--continues-build 43` names
the build number the version already went out as; `--continues-commit <sha>`
names the commit that submission was built from. Either is checkable against
the tags that recorded the submission, and neither can be passed
unconditionally — on a fresh version there is no prior submission to name, so
the flag fails validation and the build stops loudly instead of the check being
silently disarmed. Which spelling is the owner's call (§9), and it should be
settled with the tag vocabulary that records those facts, not separately.

**The alternative considered** is a descent test — allow equality when HEAD
descends from the tag naming X. It needs no flag, and it has a real hole: `main`
after a merge-back, with a forgotten pubspec bump, also descends. That is the
ordinary shape of the mistake the check exists to catch, so the automatic version
is weakest exactly where it matters most. This repository's own rule applies —
*the fix is to type the flag, not to be careful* — and this is the owner's call
to confirm.

## 5. What counts as a release tag

From `tag.release`. A tag is a release of version *V* when substituting *V* into
a configured format reproduces the tag exactly — a literal template match, no
globbing.

**Reader and writer are different roles and need different keys.** `format`
(singular) is what `release finish` *writes*, and stays exactly as it is. This
adds `also` — a read-only list of further shapes that count as releases here:

```yaml
tag:
  release:
    format: v{version}          # what release finish writes. Unchanged.
    also:                       # what release check additionally counts
      - ios/v{version}          # written by hand from promote.sh when one
      - macos/v{version}        # store ships a version the others did not
      - android/v{version}
```

Naming them beats globbing: Hold the Wheel **declined** `*/v*` deliberately,
because without a namespace strip it would make a future `uploaded/v1.0.5` count
as a release of 1.0.5 and block builds of it. An explicit list cannot do that.

**Build metadata excludes a tag unless the format asks for it.** `v1.1.0+43` says
build 43 of 1.1.0 went to a tester; the version is unreleased and the next build
of it must still be allowed. Both shell guards do this with `grep -v '+'`, and
both peers said independently that *it is the metadata filter that saves us, not
the glob*. So it is a rule of the parse rather than of the pattern.

**A near-miss is reported, and this is what makes the list safe.** Any tag whose
last path segment parses as `v<version>` without build metadata, and which
matched no configured format, is named in the output as unconfigured and
ignored. Without it, somebody hand-writes `windows/v1.2.0` next year, the list
has no entry for it, and the tag is silently uncounted — the `v*`-only trap
reproduced one level up, with a config file as the thing nobody maintained. With
it, config rot is a visible state on every run.

## 6. Where the tags come from, and what happens when they cannot be had

**The failure this section exists for, which the first pass built.** `origin` was
forbidden and "no tags found" was exit 0. `actions/checkout` defaults to
`fetch-depth: 1` and `fetch-tags: false`, so a CI checkout has **no tags at
all** — every run would have reported "nothing to compare", exited 0, and
cleared the build. Forever, in the only environment that matters, because it
never ran. A sentence on stdout is not a mitigation when the exit code says
clear.

**So origin is asked, and preferred.** One read-only call —
`git ls-remote --tags origin`, filtered by the configured formats — when an
origin is configured. Its answer wins, because it is the record and the local
clone is a cache of it. This also makes the tool correct the morning after
somebody else released, which no local-refs design can be.

Every state, with the exit code it must carry, because §7 makes the exit code the
only thing a shell caller sees:

| State | Exit | Output |
|---|---|---|
| Compared against origin, clear | **0** | the highest release found, and which tag |
| Compared against origin, `X <= highest` | **4** | both versions, and the tag |
| Origin unreachable, compared against local refs, clear | **0** | the answer **and** `answered from local refs — origin unreachable` |
| Origin unreachable, local refs say refused | **4** | as above, with the same warning |
| No release tags anywhere, origin reachable | **0** | `no release tags match … — nothing has shipped` |
| No release tags locally, origin unreachable or clone shallow | **5** | `not qualified to answer` |
| A configured format is malformed, or git failed | **1** | what broke |

**4 and 5 are distinct on purpose, and 5 is the whole point of this section.**
"This version already shipped" and "I could not find out" call for different
actions — bump the version, versus fix the checkout — and this project has twice
now watched an undistinguished exit code get swallowed by `|| exitCode=$?`.
`git rev-parse --is-shallow-repository` is what separates a shallow clone from a
genuinely fresh repository.

**A skipped unparseable tag taints the pass.** AuthPass carries `vv1.5.8`, a real
typo on a real origin. Skipping it is right; passing silently afterwards is not,
because that tag may *be* the release of 1.5.8. So a pass that skipped anything
carries the warning in the pass line itself, not only in a listing below it.

## 7. Interface

```
cux_ship release check --version 1.1.0 [--continues-build 43 | --continues-commit <sha>]
```

- **stdout carries the query**: the highest released version found, and by which
  format and tag. Useful alone, and what a caller wanting only the fact reads.
- **exit code carries the policy**: the table in §6.
- `--version` is **required and never inferred**. Hold the Wheel's builds 45, 47
  and 53 all read `1.0.3+1` in `pubspec.yaml`, because the build number lives in
  a git note and the file says whatever it said at the time. Anything that
  reconstructs a version by reading a checked-out file will be confidently wrong
  there. The caller knows; this does not.

## 8. What it must not do

- **Write anything.** No tags, no fetch into local refs, no mutation. `ls-remote`
  reads; it does not change the clone.
- **Ask a store.** §1.
- **Resolve the version itself.** §7.
- **Grow a changelog check, an allocation, or a dirty-tree gate.** Those are A,
  B, C and the script's, and absorbing them is how a focused command becomes a
  second `build.sh`.

## 9. Open

**The lane discriminator** — a `--continues-*` flag against the descent test,
and if the flag, which fact it names: `--continues-build` reads best in a
script that already knows the number it is continuing past,
`--continues-commit` names what the tag actually points at. §4 argues for a
flag and this repository's philosophy agrees, but it is the owner's call and it
is the one decision that changes what a caller has to type.

**Whether `also` is the right shape** for per-platform release tags. It has the
least evidence behind it: those tags are written by hand from `promote.sh` and
nothing has ever read them programmatically. The near-miss report is what makes
getting it wrong survivable.

**Whether this is worth building at all.** With origin as the oracle it does
something shell cannot cheaply do — answer correctly in a tagless CI checkout,
and the morning after somebody else released. Without that it is a nicer parser
over the same stale cache, and the store-side `versionName` warning gains real
ground. The first is now the design, so the case is stronger than it was — but
it is still one check of four, in two repositories, and that is the honest size
of it.
