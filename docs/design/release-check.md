# `release check` — has this version already gone out, asked of the repository

Status: **draft for review**, 21 August 2026. Not built.

Two repositories answer this question in shell, the answers have drifted, and one
of the two was wrong until this afternoon — it read an upload tag as a release
and would have refused a build for a release that never happened. This proposes
moving the answer into `cux_ship`, and is written after reading both guards
rather than ahead of them, because an earlier attempt at this was deferred
precisely for guessing.

## 1. The question, and who asked it

> **Given a version I am about to build, does *this repository's own record* say
> that version has already gone out?**

Asked by `tool/build.sh` in How It Went and in Hold the Wheel, on every untagged
release build. Not asked by AuthPass, ever — see §3.

**The oracle is git, and that is the whole point.** The obvious alternative is to
ask the store: Play can report the live track's versionName, and it is the
authority on what it actually holds. That was proposed and rejected, and the
reason is not convenience:

- **A store is a downstream consumer of a release, not the record of one.** A
  repository that can only answer "what did we ship" by asking Google has
  outsourced its own history to a company with no obligation to keep it.
- **There is more than one store.** Play, App Store, Amazon, F-Droid, direct
  download. If the store is the truth then there are five truths — and one
  project's real numbers say so: Play internal at 2168, Amazon at 2096, macOS on
  a sequence of its own. Nothing reconciles those except the repository.
- **A build must work without credentials or a network.** A guard that weakens
  when a token expires is a guard that is absent exactly when a release is being
  rushed.
- **It is the failure this whole toolchain keeps finding.** *The thing you can
  query is not the thing that governs you.* A store API answers about itself, at
  one moment, per destination.

The store's refusal stays where it belongs: the **last** line, not the first. It
decides what it accepts, and it will keep doing that whatever this says.

## 2. What it replaces — one check of four, and not the others

`tool/build.sh` runs four checks in this area. Only the last is a version
comparison, and a design that swallows the others would delete real work:

| | Check | Path |
|---|---|---|
| **A** | the tag and `pubspec.yaml` must not disagree | tagged |
| **B** | the tag must exist on `origin` | tagged |
| **C** | an untagged HEAD is refused | untagged — Hold the Wheel only; How It Went deleted it |
| **D** | the version must exceed the highest released | **untagged only** |

**`release check` takes D. A, B and C stay in the script**, where the pubspec and
the working tree are. A is a two-sources-of-truth check, B a reachability check,
C a policy gate — none is about what has been released.

**D fires only on the untagged path, in both repositories.** This is the
non-obvious part and it was nearly designed away. The untagged case is the
internal track: every commit on `main` publishes, carrying whatever version
`pubspec.yaml` says, with no tag. That is the only route by which a version can
silently go backwards. On the tagged path, A already catches the disagreement,
and firing there as well would refuse rebuilds of an already-uploaded commit.

So the command is invoked *in place of* D, in the same branch, and is not "a
check to run before every release".

## 3. Who does not want it, and why that is final

AuthPass has **no version-level guard at all**. Its guards ask each store how
high a build number it holds, and its policy is that a version is never spent —
same version with a higher build is the ordinary path on every platform.

That is not abstention, it is structure: AuthPass's release is per-destination,
while its git record is deliberately one `uploaded/` tag per commit, so git
*cannot express* which destinations hold what. A git-oracled check is therefore
a tool for repositories whose release is a single event. Theirs is not.

**This is recorded so it is not re-litigated**, and it has one consequence for
scope: the `(version, buildNumber)` tuple comparison that `BUILD-TAGS` §6 asked
for was asked for *by AuthPass*. With AuthPass out, both remaining consumers want
plain version comparison — a released version is spent. **The tuple is therefore
not built.** It is one `--build` flag away if a consumer ever wants
same-version-higher-build, and building it now would be a second reader nobody
has asked for.

## 4. The comparison

Given `--version X`:

1. Collect every tag matching a configured release format (§5).
2. Parse each into a `Version`; skip what does not parse (§6).
3. Take the **highest**.
4. Refuse when `X <= highest`.

**Against the highest, never against a tag named for X.** Asking "does
`vX` exist" answers *no* for a version that was attempted, failed, and had its
tag deleted — and then ships it behind a higher one. That nearly published 1.0.1
after 1.0.2 was live, and it is the reason the shell version is written the way
it is.

**`<=`, and equality is the case that matters.** `sort -V` cannot distinguish
"the same" from "newer", so the shell tests equality separately. Dart has a real
`Version` with a working `>`, which makes it easy to port this as `X > highest`
and silently stop refusing the exact case — the same version going out twice —
that the check mostly exists for. It is `>=` that is wrong to write, and `<=` in
the refusal that is right.

## 5. What counts as a release tag

From `tag.release`, which already exists and already defaults to `v{version}`.
A tag is a release of version *V* when substituting *V* into a configured format
reproduces the tag exactly — a literal template match, no globbing.

**Multiple formats, because the two repositories legitimately differ:**

```yaml
tag:
  release:
    formats:
      - v{version}            # the default, and Hold the Wheel's only one
      - ios/v{version}        # How It Went also tags per platform,
      - macos/v{version}      # written by promote.sh when one store ships
      - android/v{version}    # a version the others did not
```

Listed rather than globbed, and that is deliberate. Hold the Wheel **declined**
`*/v*` this afternoon on purpose: without a namespace strip it would make a
future `uploaded/v1.0.5` count as a release of 1.0.5 and block builds of it. An
explicit list cannot do that, and makes "what counts as a release here" a
question the config answers.

**Build metadata excludes a tag unless the format asks for it.** `v1.1.0+43`
says build 43 of 1.1.0 went to a tester; the version is unreleased and the next
build of it must still be allowed. Both shell guards do this with `grep -v '+'`,
and both peers independently said the same thing: *it is the metadata filter that
saves us, not the glob*. So it is a rule of the parse rather than of the pattern.

## 6. When it cannot tell

The failure this document is most afraid of, because it is the one this project
keeps finding: **a check that reports success when it did not run.** The shell
version has it — `grep -v` exits 1 on empty input, `|| true` swallows that, and
an empty `HIGHEST_RELEASED` skips the comparison entirely.

Three states, three different outputs, none of them silence:

- **No release tags at all** — a new repository, or a fresh shallow clone that
  fetched none. Exit 0, and say so: `no release tags match … — nothing to
  compare`. Never a bare pass.
- **A tag matches the shape but not the version grammar** — AuthPass carries
  `vv1.5.8`, a real typo on a real origin. Skipped, named in the output, and not
  a crash: one malformed tag must not take the check down, and must not be
  counted either.
- **The comparison ran** — print what it compared against, always. A pass that
  does not name the highest release it beat is indistinguishable from a pass that
  found nothing.

A shallow clone deserves its own sentence, because it is the likely production
shape of "no tags found" and it is not the same as "nothing has shipped". If
`--depth` has hidden the tags, the check is not qualified to answer and should
say that rather than clear the build.

## 7. Interface

```
cux_ship release check --version 1.1.0
```

- **stdout carries the query**: the highest released version found, and by which
  format and tag. Useful on its own, and it is what a caller wanting only the
  fact can read.
- **exit code carries the policy**: `0` clear, a **dedicated** non-zero for
  *already released*, `1` for operational failure. Distinct because this package
  has just learned that lesson twice — `uploadCollisionExit = 3` exists because
  an undistinguished `1` is what `|| exitCode=$?` wrappers swallow.
- `--version` is **required and never inferred**. Hold the Wheel's builds 45, 47
  and 53 all read `1.0.3+1` in `pubspec.yaml`, because the build number lives in
  a git note and the file says whatever it said at the time. Anything that
  reconstructs a version by reading a checked-out file will be confidently wrong
  there. The caller knows; this does not.

## 8. What it must not do

- **Write anything.** No tags, no fetch, no `origin` contact of any kind. It
  reads local refs and answers.
- **Ask a store.** §1.
- **Resolve the version itself.** §7.
- **Grow a changelog check, or an allocation, or a dirty-tree gate.** Those are
  A, B, C and the script's, and the temptation to absorb them is exactly how a
  focused command becomes a second `build.sh`.

## 9. Open, and honestly open

**Whether this is worth building at all.** Both reviewers arrived at the same
doubt from opposite seats, and it deserves to be at the front rather than the
back: the regression this catches is a *display* version going backwards, Play
does not police `versionName`, and a warning at the upload chokepoint would catch
it too. The reason to prefer this is §1 — that the repository should be able to
answer for itself — and that is an architectural position rather than a
measurement. If it turns out a store-side warning is what actually gets used,
then this never needing to be written is the right outcome and not a failure.

**Whether `formats` is the right shape**, or whether per-platform release tags
should be modelled some other way. It is the part with the least evidence behind
it: How It Went writes those tags by hand from `promote.sh`, and nothing has ever
read them programmatically.
