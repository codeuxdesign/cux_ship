# Promoting writes the release tag, and one method writes it

Status: **draft**, 21 August 2026. Not built.

A promotion is the moment a version becomes released. The tag records exactly
that. They are two commands today, so something has to glue them — and the glue
is where the duplication lives.

## 1. What each consumer glues, and what it costs

| | promotes with | tags with |
|---|---|---|
| How It Went | `cux_ship play promote` (`promote.sh:204`) | ~40 lines of shell (`promote.sh:215–252`) |
| Hold the Wheel | `cux_ship … promote` | `cux_ship release finish` (`promote.sh:324`) |
| AuthPass | its own uploaders, six destinations `cux_ship` does not drive | nothing |

Three consumers, three answers, for one operation that always follows the same
one.

**And the shell copy carries a comment saying so.** `promote.sh:215` opens:

> This block had the defect `cux_ship` 3.3.0 fixed on its own tag path, and this
> copy is the one that could reach the bad state on purpose.

So the duplication is known, and was kept for a real reason — see §5. That is a
better starting position than an accident: there is a stated disagreement to
resolve rather than an oversight to tidy.

**It also carries a claim that is now known to be false.** `promote.sh:246`:

> Pushing one origin already holds at this commit is a no-op; one it holds at a
> different commit is rejected

That is the sentence deleted from `provenance.dart` in 3.4.2, false for the same
reason: two clones minting annotated tags for one commit produce two different
tag *objects*, and git rejects the second with wording that reads like a
collision. The consequence here is milder than it was there — the retry path
below it is written correctly — and the sentence stands in more places than
this document first counted: **`release finish`'s own push path carries it
too**, near-verbatim in the comment above the tag push
(`cux_ship/lib/src/release.dart`), and that path still treats any rejected
push as fatal without asking origin what its tag names. Three copies, two
languages, two repositories; 3.4.2 fixed one.

That is the argument for consolidating, sharpened by the count: the fix made
once in 3.4.2 **did not even reach the other tag path in the same package**.
One method is the only shape in which the next such fix reaches every writer.

## 2. What is proposed

**One method, two ways to reach it.**

```dart
/// Records that [version] reached [target] at [commit].
ReleaseTagResult recordRelease(Git git, {
  required Version version,
  required String target,
  required String commit,
  required TagKindConfig config,
});
```

- **`play promote` and `appstore promote` call it** after a successful
  promotion, with the target they just promoted to. No flag to remember, no
  second command to forget.
- **`cux_ship release tag` exposes the same method** for everything else:

**The first bullet reverses a documented promise, and owes it an argument.**
`play/cli.dart`'s header specifies promote as touching no git — *"tagging and
bumping is a separate, once-per-release step rather than something each
store's promote repeats"* — written so that two stores can publish the *same*
version, which is impossible if either one moves it. Both halves of that
reason survive the reversal: `recordRelease` never bumps, so the version still
does not move; and §4's second row makes the per-store repeat safe rather
than forbidden — the second store's promote finds the tag at its commit and
ensures it is pushed, not a second tag. What does not survive is the header
itself, which must be rewritten when this is built. A comment that outlives
its truth is exactly the defect §1 just counted three copies of.

```
cux_ship release tag --version 1.1.0 --target amazon --commit <sha>
```

**The standalone form is not an afterthought; it is half the point.** `cux_ship`
drives two stores, and a consumer's destinations outgrow that: Hold the Wheel
or How It Went may add a direct download, a Microsoft Store listing, an F-Droid
build, none of which will ever have a promote command. A tag family that only
works for the two stores that happen to have promote commands is a tag family
that records a fraction of what shipped — and worse, records it *unevenly*, so
the gaps look like versions that never went out.

AuthPass's eight destinations, six self-driven, are the extreme of that shape —
but not this command's audience, and saying otherwise would contradict
`release-check.md` §3: its release is per-destination, its git record is
deliberately one tag per commit, and it has no moment at which a *version*
becomes released for this command to record. Per-destination release names are
exactly the record it declined for cost. That door reopens on the condition
both documents already name — a real question that needs per-store records —
and not before.

Nothing about the standalone form touches a store. It is git only, needs no
credentials, and is usable from any script that knows it just published
something.

## 3. Where the commit comes from

`--commit` explicitly, always available. But a promotion usually should not need
telling, because **the upload record already knows**: `uploaded/vX.Y.Z+N` names
the commit that build was built from, which is the whole reason it is written
before the store is contacted.

So `play promote`, pointing a track at versionCode *N* of version *X*, can
resolve *N* to its commit through `tag.upload`'s format, and tag the commit that
actually produced the artifact being promoted rather than whatever HEAD happens
to be. That is the same distinction `UploadRecord.commit` documents and the same
one that has already shipped wrong code elsewhere.

When no upload record exists — recording off, or an artifact from before it was
enabled — `--commit` is required and its absence is an error rather than a
fallback to HEAD. HEAD during a promotion is very often *not* the promoted
commit; that is the normal case, not the exotic one.

## 4. Bare or qualified: the tool can decide, and today nobody does

`SHIPPING.md` specifies `<qualifier>/vX.Y.Z` for "one version that reached stores
from different commits", with bare `vX.Y.Z` as the norm. **It has never been
written** — the form was specified and never used, because deciding when to
qualify was left to a human and the situation is rare enough that nobody has
been in it yet.

The tool can decide it mechanically, because it has the only fact needed:

| Existing `vX.Y.Z` | What this promotion writes |
|---|---|
| absent | `vX.Y.Z` at this commit |
| present, **this** commit | nothing new; ensure it is on origin (§5) |
| present, **another** commit | `<target>/vX.Y.Z` at this commit — this *is* the divergence |

The third row is what `promote.sh` currently turns into a warning and a request
that a human "retag deliberately once you know which one shipped". The tool
knows which one shipped: the one it just promoted, to the target it just
promoted to. Recording it is strictly better than asking.

**The first column is asked of origin, not of the clone.** The §5 lesson
applies at the decision, before it applies at the push: a clone that has not
fetched since another machine promoted sees no `vX.Y.Z`, takes the first row,
and mints a bare tag origin already holds at another commit — and the
rejection then arrives *after* the wrong decision, downgraded to a warning by
§5, leaving the divergence unrecorded and two machines each holding their own
`vX.Y.Z`. So the existing-tag question is
`git ls-remote origin 'refs/tags/vX.Y.Z^{}'` where an origin is configured,
local refs otherwise — the same oracle rule `release-check.md` §6 arrived at
from the reading side. And a bare-tag push rejected because origin names
another commit is the third row discovered late, resolving to the same action:
qualify.

**The cost, stated:** the bare tag then means *the first target to promote this
version*, which is a little arbitrary — and only as good as the first writer.
A bare tag hand-written at the wrong commit (HEAD during a promotion, which §3
calls the normal mistake) is enshrined by this rule as the norm, with the
correctly-resolved commit filed as the exception; no entry lies about what it
points at, but which name reads as *the* release was decided by whoever tagged
first, right or wrong. The alternative — qualifying both once a second target
diverges — would mean rewriting a published tag, and a record that gets
rewritten stops being a record. So the bare tag stays where it landed and the
divergent one is qualified.

**The qualifier is a target, not a platform**, and this is the command that
makes that possible: promote knows the destination it just moved a build to,
which a separate tagging step has to be told. Divergence happens at the target
— Play internal at 2168 while Amazon holds 2096 is one platform and two states —
so `android/vX.Y.Z` cannot express what `playstore/…` and `amazon/…` can. Target
implies platform; platform does not imply target.

**One vocabulary, shared with `tag.upload`.** If per-store upload records are
ever adopted (`upload-record-scope.md`), `uploaded/playstore/v1.1.0+69` and
`playstore/v1.1.0` must use the same word for the same destination. Two
taxonomies for one concept is how `android/v1.0.0` ends up sitting next to
`uploaded/playstore/…` with nothing able to relate them.

## 5. Push semantics: the disagreement worth resolving in one place

This is the stated reason the shell copy exists, and it is a real difference:

- **`release finish` fails the caller when the push fails.** Correct there:
  nothing has shipped, and an unpushed tag protects nothing.
- **A promotion tag must only warn.** The release has already gone out. Failing
  the command after the store has accepted turns a bookkeeping problem into a
  red release, and invites a re-run of a promotion that already succeeded.

So `recordRelease` **warns and does not fail** — and that is a property of *when
it runs*, not a preference. From a promote it runs after the store said yes, by
construction. The standalone form has no store in the loop, so there
"after the release" is documented intent rather than construction — §6's
boundary with `release finish` is what keeps a script that has not shipped
anything yet from reaching for the one tagger that only warns.

Which makes "created locally but not pushed" a state this deliberately produces,
and therefore one it must recover from. Two rules, both already learned:

- **Push on both paths**, not only the one that created the tag. The old shape
  found the tag locally on every later run, called it already-done, and never
  pushed it — so the tag existed on one machine and nowhere a later reader
  looks, including `build.sh`'s already-released gate.
- **A rejected push is not a collision.** Ask origin what its tag names —
  `git ls-remote origin 'refs/tags/<name>^{}'`, dereferenced, because comparing
  tag *objects* reports a collision on every parallel promotion and never on a
  real one. This is 3.4.2's fix, and the shell copy is where it has not landed.

And the warning must name what heals it, because **an unpushed release tag is
invisible to everything that reads the record** — `release-check.md`'s oracle
is origin, so a warned-and-forgotten push failure leaves the next build of
this version unrefused on every machine but this one, and after the *last*
promotion of a version no later store's promote comes along to re-push it. The
remedy the warning names is re-running the same promotion: safe by §4's second
row, which exists precisely so that the retry pushes instead of shrugging.

## 6. What this replaces, and what it does not

**Replaces:** `promote.sh:215–252` in How It Went, and the separate
`release finish` call in Hold the Wheel's promote path.

**Does not replace `release finish`.** That command bumps a version, commits it,
and tags a release *before* anything ships — a different moment with different
correctness rules, which is exactly why the push semantics differ. If anything
this sharpens it: `release finish` goes back to being about finishing a version,
and stops being the thing a promotion script reaches for because it was the only
tagger available.

**Does not decide what a release tag means.** How It Went tags at upload by
convention; Hold the Wheel tags at promotion by automation. This command is what
you call *when you decide a version is released*; it does not tell you when that
is. Encoding one repository's answer would be encoding a habit — see
`release-check.md` §4 for where that goes wrong.

## 7. Open

**Which promotions count.** `play promote` takes `--track`, defaulting to
`production` but accepting any — and a promotion to `beta` widens an audience
without releasing anything. Firing `recordRelease` on every promote encodes
*any promotion is a release*, which is false for Play and unexamined here.
Production only? A config key? This is §6's "what a release tag means"
question arriving through the side door: refusing to answer it and then wiring
the write to an event that takes a track parameter is not neutral yet, and
§2's "no flag to remember" holds only once this is settled.

**The target vocabulary.** `playstore` or `play`? `appstore` or `ios`/`macos` —
noting iOS and macOS are separate targets on one store, with separate build
numbers, which is the case that breaks a platform-shaped vocabulary. It must be
settled with `tag.upload`'s, not separately. And the qualified shape needs a
home in config: §4 writes `<target>/vX.Y.Z` with the prefix pulled from thin
air, while `tag.release` today holds only `enabled` and `format` — whether the
qualified form is a second format key or a fixed derivation from the bare one
is part of the same decision.

**Whether `recordRelease` should also be reachable from `upload`.** It should
not — an upload is not a release, and `uploaded/` already records it. Named here
because it will be proposed.

**Whether the divergence rule in §4 is too clever.** It writes a qualified tag
without being asked, on a condition the operator may not have noticed. The
alternative is refusing and making them run `release tag --target` by hand,
which is honest and slower. §4 argues for deciding; this records that the other
answer is defensible.
