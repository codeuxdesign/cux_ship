# Release and rollout state: what a publishing tool should answer

Status: **proposed**, 10 September 2026 — **implemented on a branch and not
merged**, which is a state the index has no word for.

`tool/status.sh` has four: `open`, `proposed`, `decided`, `built`, and
`design_status_test.dart` fails a document that invents a fifth, so this line
cannot say what is actually true. `built` would claim something that has not
landed; `proposed` understates a Play half that is written, tested and twice
reviewed. **`proposed` is the one to be wrong with**, because it understates
rather than overstates and the correction is a commit away — where a premature
`built` is a claim `tool/status.sh` exists to keep honest, believed by anyone
reading the index rather than the file. Move it to `built` when this merges.

Recorded rather than fixed: whether the vocabulary wants a fifth word is a
question about the index and not about this document, and answering it here
would be a design changing the tool that reports on it.

Read against 4.3.0 as published, which is the version that settled the shape
anything new here has to fit into. The
document is deliberately three answers rather than one, because the three parts
of "release and rollout state" have three different verdicts and a single
status line would flatten them:

- **Play's rollout fraction** — a hole in a document this package already
  publishes. Proposed, with a shape.
- **The App Store's review state** — one defect in what shipped:
  [`AppStoreState`](#in_review-is-not-in-the-vocabulary-and-that-is-a-defect-in-430)
  does not name `IN_REVIEW`, so the exact state this task is about arrives as
  `unknown`. Four enum members, and — after four drafts, one of which was built
  and then removed — **no derived field at all**. That is the one place this
  document argues against the convention it otherwise follows, and the
  argument is a table the consumer produced rather than anything reasoned here.
- **A wait for either** — not built, and §"The wait" is the recorded reason.
  See its own status line.

[json-output.md](json-output.md) §Scope names this task and defers it in one
sentence. This is that sentence, argued.

## What already exists, and it is more than the re-file assumed

Checked against 4.3.0 rather than 4.2.0, because the thing that might have
invalidated a design here has already happened: `--json` shipped, a consumer
ported onto it, and two pre-releases were spent proving the format.

**The vocabulary is largely there.** `AppStoreState` names twelve of Apple's
states and `PlayReleaseStatus` names all five of Play's, each with a permanent
`unknown` and the store's own word beside it in a `*Raw` sibling.
`PlayReleaseEntry.serving` already answers "is this rollout stopped" without a
caller comparing Google's status strings, and `AppStoreVersionEntry.editable`
already answers "would a write be accepted" without a caller learning Apple's
dozen.

**So this is not a greenfield feature.** Three of the four things somebody would
reach for already exist, and what is left is narrower and better evidenced than
"make rollout state readable" suggests. Naming what is *not* missing is most of
what stopped this from being built twice as large as it needs to be.

## Does this belong in a publishing tool at all

The objection is real and worth stating in its strongest form: *"where is my
release" is a console's job, App Store Connect and the Play Console answer it
with more fidelity than one API read can, and a tool that answers it badly is
worse than one that does not.*

It is decisive against a dashboard, and decisive against a wait — §"The wait"
is where it lands and what it kills. It is **not** an argument against the read,
for one reason:

**The fraction is not a new capability. It is a field of a record this package
already reads, parses, renders and publishes, and drops on the floor.**
`playTrackFrom` reads Play's `TrackRelease` and takes three of its seven
fields — `name`, `status`, `versionCodes`. `userFraction` is one of the four it
discards, and it is the one that decides whether the `status` it *does* carry
means anything. A 1% staged rollout and a finished one are both `serving: true`
today, which `serving`'s own doc comment says in as many words.

So the question is not "should this tool grow a rollout report". It is "should
the document it already prints stop being silently incomplete about the record
it is a document *of*". Framed that way the console argument does not reach it:
nobody thinks `versionCodes` belongs in the console rather than in `play tracks
--json`.

**And the honest limit is a labelling problem, not a scope problem.** A bare
"20%" *can* say something false — Play's `countryTargeting` restricts a release
to a set of countries, and 20% of a targeted rollout is not 20% of the track's
audience. That is an argument for what the field is called and what its doc
comment refuses to claim (§"What the number is not"), not for omitting a number
Play sends and this package throws away.

## The Play half: `userFraction` is a hole in a document we already publish

`TrackRelease.userFraction` in googleapis 16.0.0, which is the version this
workspace resolves:

> Fraction of users who are eligible for a staged release. 0 \< fraction \< 1.
> Can only be set when status is "inProgress" or "halted".

**That sentence is Google's, and the chain is worth naming because the whole
value space below leans on it**: it is written by `discoveryapis_generator` from
the Android Publisher v3 discovery document into googleapis' dartdoc. Two
caveats travel with it. It is phrased as a constraint on what may be *set*, so
it binds a write directly and a read only by inference — and **nothing in this
repository has measured it.** There is no observation of a live account here,
unlike the App Store states next door, which are measured and say so.

**So the design must not depend on it, and does not** — see
§"What the range buys, and what does not depend on it" below. That section
exists because a reviewer asked where the range came from and could not check
it from outside, which is the right question to have asked: it is the one claim
in this change sourced entirely from a dependency's generated comment.

`PlayTrackRelease` does not carry it, so `PlayReleaseEntry` cannot, so a caller
spawning `play tracks --json` cannot tell a 1% rollout from a finished one
through this package at all.

### The justification is the halted case, and it is not the one this started with

**The obvious citation is the consumer's own `docs/SHIPPING.md` §12, and it is
the weaker half.** Quoted in full, because the correction below turns on its
exact scope:

> **One limitation, stated rather than hidden: a 1% staged rollout reads
> exactly like a finished one.** `inProgress` is treated as reaching testers,
> because a staged rollout is being served — to some of them. Distinguishing a
> rollout that has barely begun would need Play's `userFraction`, and
> `PlayTrackRelease` does not carry it, so this is an upstream ask against
> `cux_ship` rather than something `status` can decide.

**That is a limitation of a sentence, and the fraction would not even fix it.**
Asked what would change, the consumer went and read its own code: the caveat is
produced by a function that speaks only when `serving != true`, and
`inProgress` is `serving: true`. So the case §12 documents prints **nothing
today and would still print nothing** with the fraction in hand — using it
there is a new code path that speaks when nothing is wrong, and a decision
nobody has made about when a status report volunteers. On the `internal` track
it compares against, staged rollouts barely arise. The consumer's own verdict:
*"I would probably not build that."*

**The second case is `halted`, and it is a defect rather than a wish** — though
not one this package has to fix, which the correction two paragraphs down
concedes. The same consumer renders, for a halted release:

> The internal release serving 169 is halted — testers are being given the
> release before it.

If Play halted at 20%, **that sentence is false for one tester in five.** They
have 169 and are staying on it: the rollout stopped, it did not roll back. The
report tells an operator nobody has the build while some people do, which is
worse than the vagueness it replaced. `serving == false` is genuinely not
enough.

**And the fraction is not what fixes it, which is a correction to the sentence
that stood here before.** This said the fraction is what makes the report true
rather than merely less wrong. It is not: the consumer's own honest version
needs no new field at all —

> the rollout stopped, so some testers have it and the rest are on the release
> before it

— which is true at 5% and at 95%, and which landed on that consumer's `main`
ahead of anything here. **What `audienceFraction` buys that sentence is
exactness, not correctness.** A defect this package can fix and a defect this
package's consumer can fix without it are different arguments for building
something, and the second is the weaker one.

**The discovery is a separate fact from the fix, and only one of them is
independent.** The fix needed nothing from this work. The *finding* did: that
sentence was not spotted by its author reading their own code, it surfaced
while they answered a question asked from here — *is `halted` with a fraction
interesting to you, or is `serving == false` enough?* — and answering it
honestly meant going and reading what the caveat actually said. Which makes it
evidence for **the question** rather than for the field, and that is a
distinction this section needs, because its whole job is to say that this
defect is not a reason to build one.

**The distinction is worth keeping because the two are different kinds of
evidence.** §12 is a sentence its author chose to write; the halted defect is a
bug in shipped code, found by asking a question about `halted` that neither
side had asked. One is an opinion held by the consumer and the other is a fact
about it, and a design that cites the first when the second is available has
cited the weaker one.

**And the justification moved three times while the field stayed the same,
which is worth naming rather than presenting as the last one having been
obvious.** It ran §12, then `halted`, then the grid — and each move happened
because a question was asked, not because the field was re-argued. That admits
two readings and the honest thing is to give both. It might be robustness: three
independent reasons, and the field survives losing any one. It might equally be
a design looking for a justification, which is what it would look like from
outside, and the shape a reviewer should be suspicious of.

**What settles it either way is that only the third is the kind of evidence
this repository accepts.** §12 was a stated limitation and the fraction would
not have fixed it. `halted` is a real defect and the consumer can fix it
without this package. The grid is a call site that renders a number
unconditionally and has nowhere to get one — read-api.md §"No field is missing"
says *needs* and *uses* come back as different lists and only the second is
evidence, and the grid is the only one of the three that is on the second list.
Had it not arrived, the honest answer would have been to record the two weaker
cases and not build.

**And the provenance of that settling claim belongs beside it, because it is
the weakest link in the paragraph above.** "The grid is on the second list" is
a fact about a repository this one cannot read, supplied by the party whose
call site it is — who said so unprompted, in these terms: *"the grid is my call
site, so 'the only one on the second list' is a claim about my tree that I
supplied."* Nothing here verifies it. A reviewer who wants to be suspicious of
this section should be suspicious of that sentence specifically, and the check
is cheap: the grid either renders a percentage in an `inProgress` cell or it
does not.

**Score the three uses honestly, because they are not equal:**

| | |
|---|---|
| `halted` + fraction | **Wanted** — makes a sentence *exact*. It does not make it correct; see the correction below. |
| `inProgress` + fraction | **Wanted, and this is the call site.** The answer changed mid-design; see below. |
| `userFraction` raw | **Unread by this consumer and load-bearing anyway.** Not the same kind of unread as `uploadedDate`; see §"What the range buys". |

**The middle row was "not yet" for most of the time this was being written, and
how it moved is worth more than where it landed.** The reasoning for "no" was
sound and is quoted above: the caveat speaks only when `serving != true`, so an
`inProgress` release produces no line and a fraction would sit unread. That is
still true *of the caveat*. What changed is that a second reader arrived — a
summary grid, in flight while this was being designed, which renders every
destination **unconditionally** rather than only when something is wrong. In
that cell an `inProgress` release reads `2132 (20%)`, and there is nothing to
decide about when a report volunteers because it always does.

**Two consequences worth carrying past this document.** First, both of the
consumer's answers were honest and one of them was wrong within a day —
"unread" and "would not read" are facts about a tree at a moment, and a design
that treats either as durable has mistaken a snapshot for a preference. That is
the same shape as read-api.md §"No field is missing", where *what a consumer
needs* and *what a consumer uses* came back as different lists — here they came
back as different lists **at two different times**, which is the harder version.

Second, it does not license guessing. The grid is a real reader with a real
cell, not a hypothetical; the correction arrived because the question was asked
twice, not because either side speculated about what might be wanted later.

**Two fields, and the reason is the one already in this file's neighbour.**
[json-output.md](json-output.md) §"A store's vocabulary arrives twice" is about
enums, where our reading can be `unknown` and the store's word is the whole of
what is known when it is. A number has no such failure — but it has the other
half of the same argument, which is that *ours is a reading and theirs is
authoritative*, and here the reading invents a value the store never sent:

- **`userFraction`** — Play's own `double?`, exactly as sent, `null` exactly
  when Play sent none. Spelled with Play's key rather than as a `*Raw` sibling,
  because ours is called something else and the name is therefore free. There is
  no `audienceFractionRaw`, which would be a third name for two facts.
- **`audienceFraction`** — this package's answer, and the derived field.

### The derived field, and what it is for

The hole `userFraction` alone leaves is that **Play omits it exactly when it
means one.** A completed rollout carries no fraction, so a caller that renders
`userFraction` gets `null` for the release that reached everybody and has to
learn from Google's documentation that null-with-`completed` means 100% — which
is the deferral the derived-field convention exists to end.

    completed          → 1.0
    inProgress         → userFraction        (null if Play sent none)
    halted             → userFraction        (the fraction it stopped at)
    draft              → 0.0
    statusUnspecified  → null
    unknown, absent    → null

Same three-valued honesty as `serving`, for the same reason, one line further
down: a derived field cannot be less honest than the field it is derived from.

### What the range buys, and what does not depend on it

`0 < fraction < 1` makes the table above a set of *unique* values: `1.0` can only
mean `completed`, `0.0` can only mean `draft`, and anything strictly between is
Play's own number. That uniqueness is what makes `audienceFraction` readable
without a companion field, and it rests on a sentence quoted from a dependency
and measured by nobody here.

**So the obvious worry is what happens when it is wrong** — if Play ever
answered `1.0` for an `inProgress` release at full rollout, `audienceFraction`
would be `1.0`, the same number this package infers for `completed`, and the
inference and the measurement would collide.

**They do not, and the discriminator is `status`.** The derivation is a
function of `status` and `userFraction`, and **both of its inputs travel in the
document**, so a caller can always see which branch produced the number:
`status: completed` means the `1.0` is this package's, `status: inProgress`
means it is Play's. That holds whatever Play sends, because it does not depend
on the value at all.

**An earlier draft of this section said the discriminator was `userFraction`'s
nullness, and that was wrong in a way worth keeping on the page**, because the
mistake is the one this whole section is about. Nullness discriminates only
while Google's sentence holds in its *second* half — *set only for `inProgress`
and `halted`*. Let Play set `userFraction: 1.0` on a `completed` release and
ours reads `(completed, 1.0, 1.0)` where a full rollout reads
`(inProgress, 1.0, 1.0)`: the fractions are identical and nullness has stopped
telling them apart. **The draft defended against half of an unverified sentence
using the other half of the same unverified sentence** — which is exactly the
circularity that made the range worth citing in the first place, committed one
paragraph after citing it. Found in review, not here.

`status` is subject to none of that: it is always present, this package reads it
independently, and no claim about the *value* of the fraction bears on it.
Nullness survives as a convenience — the common case where a reader can tell at
a glance — rather than as the guarantee.

**Which is a second argument for carrying `userFraction` at all, and a better
one than the first.** §"Two fields" justifies it by convention — theirs is
authoritative, ours is a reading. That is true and it is an appeal to house
style. This one is a property: **the pair is correct under an assumption the
package cannot verify, where either field alone is only correct while the
assumption holds.** A consumer that reads only `audienceFraction` is taking the
range on trust; one that reads the pair is not. It is pinned by a test, and the
mutation that fails it is folding the raw field into the derived one — which is
exactly the simplification somebody will propose.

**So `userFraction` is unread and load-bearing, and those are compatible.** The
scoring table above filed it beside `uploadedDate` on the first pass, and the
consumer that priced it low corrected that itself once the property was clear:
an unread field that makes a *pair* verifiable is not the same kind of unread as
one nobody has needed. `uploadedDate` could be deleted tomorrow and cost a
reader nothing; deleting this one would leave `audienceFraction` correct only
while a sentence in a dependency's generated dartdoc keeps being true.

**The rule that falls out, since this repository keeps meeting it:** "no
consumer reads it" is an argument against adding a field and **not** an argument
against a field that makes another one checkable. Unread is a fact about
callers; load-bearing is a fact about the document.

### Why it is not called `rolloutFraction`, and the argument that does not hold

`rolloutFraction` is the better-sounding name and it is the wrong one — **but
not for the reason the first draft of this section gave**, and the failed
argument is kept because it is the more tempting one and somebody will reach
for it again.

**The argument that does not hold** was that `rolloutFraction: 0.2` on a
`halted` release is `mayBecomeUsable` all over again: a pair correct in only
one reading order, `serving: false` beside a number that sounds live. The
consumer that actually paid for `mayBecomeUsable` rejected the analogy, and is
right to. `mayBecomeUsable: false` on a healthy `VALID` build was *wrong* read
alone — it said "give up" about a build that was fine. `rolloutFraction: 0.2`
read alone is not wrong: a fifth of the audience has it, halted or moving. All
that is off is that *rollout* connotes motion. That is a weaker fault, and an
analogy this repository would eventually check and find did not hold.

**The argument that does hold is `completed`.** `audienceFraction` asks *who
has this build*, and under that question `completed → 1.0` is obviously right.
Under `rolloutFraction`, `1.0` on a completed release is odd — there is no
rollout; it is over. **The derivation is what makes the name earn itself, and
it earns it at `completed` rather than at `halted`:** the one state where this
package answers something Play declined to say is the state where only one of
the two names can say it without contradicting itself.

`halted` is then a consequence rather than the argument — *the fraction of the
track's audience that has been given this release* is true there too, because
users who already took it keep it, so nothing about `serving: false` beside it
has to be read in a particular order. That is a nice property of the name and
not the reason for it.

### What adding it exposes about `serving`, which is a correction rather than a change

`serving`'s doc comment says it answers whether a release *"is in front of any
of the track's audience"*, and it returns `false` for `halted`. Those two are
not the same statement: a halted release **is** in front of the fraction that
already installed it — Google's own wording is *"Users who already have these
APKs are unaffected"*.

The boolean is right and the sentence is wrong. What an operator asking "is this
rollout stopped" means is *still being handed to new users*, which is what
`serving` computes and what its `halted → false` row is for. So the fix is the
wording, not the switch, and it is worth doing **in the same change** rather
than later: the imprecision is invisible while nothing beside it measures the
audience, and `audienceFraction` is precisely the field that puts a number next
to the claim and makes the two visibly disagree.

This is `docs/CONTRIBUTING.md` §"A claim about both stores is checked against
both", one level down — a sentence written about a shared verb that is true of
some of its cases.

### What the number is not

Three refusals, in the doc comment rather than here, because a number carried
without them is read as more than it is:

- **Not a fraction of the app's users.** It is a fraction of the *track's*
  audience, and an `internal` track's audience is a list of e-mail addresses.
- **Not adjusted for `countryTargeting`.** Play can restrict a release to a set
  of countries; this package reads neither that field nor its
  `includeRestOfWorld` flag, so a targeted rollout's fraction is a fraction of
  the targeted set. Recorded as a known omission rather than closed here,
  because carrying country targeting is a second document shape and nobody has
  asked for it.
- **Not a promise about ordering.** Play chooses which devices are eligible.

### Display

The release line is composed in `PlayTrackRelease.lineOn`, and `display` text is
outside the schema promise, so this costs nothing to change and is the half a
human actually reads:

    internal: "1.4.0" codes=[1234] inProgress 20%

Rendered only when there is a fraction to render, so a `completed` release's
line is unchanged.

**The percentage therefore reaches an operator twice, and that is correct
rather than duplicated.** An earlier draft of this paragraph said the consumer
"prints `display` verbatim rather than re-rendering", which is half of what it
does and the half that flatters this document. It does both, deliberately and
in two visibly separate registers: `display` prints unchanged in a detail block,
and the *field* feeds a summary grid above it that is explicitly a re-rendering
— the grid says `LIVE` where the block below says `READY_FOR_SALE`.

So `display` is not the delivery mechanism *instead of* the field. The rule
`display` protects is narrower than "do not re-render": it is that a caller must
not re-render **this listing** and present the result as this command's output.
A summary in a different register, sitting beside the verbatim block rather than
replacing it, is not that — and it is the reader that made `inProgress` worth a
number two paragraphs up.

## The App Store half is not symmetric, and the asymmetry is the design

The tempting shape is "do for Apple what we did for Play". It is wrong twice
over, and both are worth writing down because both would otherwise be
re-derived by whoever picks this up.

### `IN_REVIEW` is not in the vocabulary, and that is a defect in 4.3.0

`AppStoreState` names twelve members. `IN_REVIEW` is not among them — read the
enum: no member carries it as its `appleValue`, so `AppStoreState.read` falls
through to `orElse: () => unknown`.

**The consequence is that the exact state this task is about is the one the
vocabulary cannot say.** A version Apple is looking at right now decodes as
`appStoreState: unknown, appStoreStateRaw: "IN_REVIEW"` — and `unknown`'s own
doc comment tells the reader this means *"Apple sent a state this version does
not name"*, which reads as a state nobody has seen. This repository has seen it:
`IN_REVIEW` appears twice in `app_store.dart`'s comments, once in `cli.dart`, and
seven times in `app_info_states_test.dart`. It was never a stranger; it was
never added.

**The evidence is about the spelling, not about the resource, and that
distinction is `AppStoreState`'s own.** Its doc comment says these words govern
two different rules — a version's and an `appInfos` record's — and the sightings
above are on the `appInfos` side. What they establish is that the *word* has been
in front of this package for months, which is all that is needed: `AppStoreState`
reads whatever string Apple sends under `appStoreState`, and the two resources
send the same strings.

Three more the repository already writes out and the enum does not name:
`PROCESSING_FOR_APP_STORE` and `PENDING_APPLE_RELEASE`, from the same test's
list of states it deliberately refuses to write to, and
`REPLACED_WITH_NEW_VERSION`, a string constant in `publishedAppInfoStates` in
the same file as the enum's sibling lists.

**`NOT_APPLICABLE` is in that test list too and is deliberately left out**, on a
distinction worth stating because it is the difference between evidence and a
sighting: that list's last entry is `SOME_STATE_APPLE_HAS_NOT_SHIPPED_YET`, an
invented string. A list containing a fabricated value is evidence that the
package refuses what it does not recognise, and is not evidence that any
particular entry in it is real. Four states with independent sightings go in;
the fifth waits for one.

**And the rule that looks like it forbids the fix does not.** `documents.dart`
says *"Members are never added because a store added a value"*, and the argument
is that a Dart switch must be exhaustive, so growing the enum on Apple's release
schedule breaks a consumer's build on Apple's timing rather than on this
package's. That argument is about *Apple adding a value*. These are values Apple
has always had and this package never named, and the precedent for adding one on
evidence is inside 4.3.0 itself: `accepted` carries the comment *"Named on a
consumer's evidence rather than this repository's"*.

**The members, and a derived field beside them whose extent is the whole
question.** This took three drafts and the two rejected ones are kept, because
each was rejected by an argument the next one had to survive.

**Draft one: `withApple`** — `true` for `WAITING_FOR_REVIEW`, `IN_REVIEW`,
`PENDING_APPLE_RELEASE` and `PROCESSING_FOR_APP_STORE`, `false` where the next
move is the developer's. Rejected: those are all "wait" and they are not the
same sentence. `IN_REVIEW` is *Apple is judging it*; `PENDING_APPLE_RELEASE` is
*Apple approved it and is publishing it*. A boolean answering "wait" for both
hides the difference between a release that may still be rejected and one that
cannot, which is `usable` hiding `needsNewUpload` one resource over.

**Draft two: the members and no derived field at all**, on the reasoning that
the distinction *is* the answer and a caller can write the comparison. Rejected
by the consumer, and by its own strongest convention: *"one bit is often the
wrong number of bits"* cuts **both** ways, and draft two had too few fields
rather than too few bits. `appStoreState == AppStoreState.inReview` is right on
the day it is written and wrong for however long the submission sits in the
queue first — the same one-case-too-narrow error as `usable`, moved out of the
package and into every caller.

**Draft three: `underReview`, scoped to exactly the states where Apple's
decision is still pending** — `WAITING_FOR_REVIEW` and `IN_REVIEW`, and nothing
else. Draft one's objection does not reach it, because `PENDING_APPLE_RELEASE`
is `false` and correctly so: review is over. Draft two's objection does not
reach it, because the caller writes no comparison at all. It was built, tested,
and observed failing under two mutations.

**Draft four, and the one that ships: the four members, and no boolean.** Draft
three was removed. The reason is not a better argument — it is the renderer.

### The boolean was removed, and what killed it was a table

Asked whether its report wanted one cell reading "waiting on Apple", the
consumer answered that it wants the opposite, and produced what it actually
renders:

| Apple's state | its cell |
|---|---|
| `READY_FOR_REVIEW` | `READY` — not submitted |
| `WAITING_FOR_REVIEW` | `QUEUED` |
| `IN_REVIEW` | `REVIEW` |
| `PENDING_DEVELOPER_RELEASE` | `APPROVED` — waiting on a human |
| `PENDING_APPLE_RELEASE` | `RELEASING` |

**Five outcomes where a boolean has two.** `underReview` merges rows two and
three, which is *less* than that report already distinguishes — so it is not
too narrow, in the way the third draft's flag warned it might be. It is the
wrong shape at every extent: draft one merges four of those rows, draft three
merges two, and the right number to merge is none.

**Which makes draft two's rejection wrong, and worth saying so plainly.** Draft
two was killed by the consumer's *endorsement* of a boolean, and that
endorsement was reasoning about a field rather than about a renderer — by the
consumer's own account, *"arguing about where to draw a line I had spent
yesterday deciding not to draw"*. A stated intention is weaker evidence than a
call site, this document said so when it recorded one, and then let it outweigh
a call site anyway.

**The thing that travelled was the argument, not the field.** The
`READY_FOR_REVIEW` distinction — written down here to justify draft three — was
carried back into the consumer's own open pull request, where it found a live
defect: `'WAITING_FOR_REVIEW' || 'READY_FOR_REVIEW' => 'QUEUED'` reported an
*unsubmitted* version as queued with Apple, so an operator would have waited on
a review Apple had never been asked for. Applying it a second time found a
second: `PENDING_DEVELOPER_RELEASE` and `PENDING_APPLE_RELEASE` sharing one
`APPROVED` cell, which is `usable` collapsing "processing" and "rejected",
rebuilt in a display vocabulary by the tree that paid for it the first time.

So the reasoning that justified the boolean fixed two bugs, in a repository this
one cannot see, **and the boolean itself has no call site and is not expected to
get one.** Those are separable, and this section is the record that they were
separated. The value was in naming the states and saying why they differ; a flag
over them was the part that added nothing.

**What ships is what was asked for.** Four members. The consumer reads
`appStoreStateRaw` with a catch-all, so `IN_REVIEW` decoding as `inReview`
rather than `unknown` makes its existing reader more useful without it changing
a line — and a caller that wants two of these states together writes its own
switch, where it can equally want three or five.

*This half is a defect report as much as a design.* If the rest of this document
is not built, this part still is.

**What would reopen the boolean**: a caller that wants the union and keeps
getting it wrong. The one caller there is wants the opposite, in writing, with
the table above.

### Apple's phased release: what it would cost, and the fraction not to invent

Status: **open**, 10 September 2026. The cost is measured below and the
fraction rule is settled; what is missing is a consumer that reads it.
`--phased` is a flag on `promote`, and nothing in this repository establishes
that anyone passes it.

`cux_ship appstore promote --phased` **writes**
`/v1/appStoreVersionPhasedReleases` and nothing in this package ever reads it
back. So the Apple analogue of a staged rollout is a thing this tool can start
and cannot observe — which is a sharper gap than Play's, and a more expensive
one to close.

**Cost, measured rather than guessed.** `AscClient.getAll` follows `links.next`
and accumulates `body['data']`; it discards `body['included']` entirely.
`appStoreVersions` is a `getAll`. So carrying the phased release means either

- teaching `getAll` to collect `included` across pages — a change to the one
  client every read in this package goes through, for one caller; or
- one `GET /v1/appStoreVersions/{id}/appStoreVersionPhasedRelease` per version,
  against a list with no cap.

Neither is large and neither is free, and the second is an N+1 over an unbounded
listing, which is the shape `listScreenshotTypes` already caps at three for the
same reason.

#### The first bullet's cost is one line in one test file, and "measured" above was not

Written when this section was, and wrong — it says *"a change to the one client
every read in this package goes through"*, which sounds like 23 call sites and
ten fakes and is none of them. Corrected by running it rather than by re-reading
it:

- **The 23 existing `getAll` call sites are untouched**, because the shape that
  carries `included` is a *new method* rather than a changed return type.
  `getAll` returns `List<Map<String, dynamic>>` and every caller wants exactly
  that; a caller that also wants `included` is a different caller.
- **Seven of the eight fakes are untouched too**, because they declare
  `noSuchMethod` and Dart therefore permits a member they do not implement.
- **The eighth is `beta_release_test.dart`'s, which does not**, and fails with
  `Missing concrete implementation`. One line.

**And the prediction that produced that list was also wrong, which is the part
worth keeping.** The guess going in was *zero* — `noSuchMethod` everywhere, no
fake affected. Probing it found the one that has no escape hatch. So the
sentence above is not "cheaper than recorded" reasoning replacing "more
expensive than recorded" reasoning; it is the third estimate, and the only one
that came from running the compiler.

**What is left is not cost.** The real work is a fake that carries `include`
semantics *across pages*, which `docs/CONTRIBUTING.md` §"A fake must carry the
semantics the tested branch selects on" requires and which a single-page fake
cannot express. That is real and it is ordinary.

#### Decided: the build ships, the phased release does not

Status: **decided**, 10 September 2026 — and the two halves went different ways
for the reason this section was written to force, which is that they were
priced together and only one of them has a caller.

**The build number ships.** `AppStoreVersionEntry` carries `buildNumber` and
`buildNumberAsInt`, `appstore versions` asks for `include=build`, and the
rendered line gains ` build 169` where Apple named one. The consumer's summary
grid is the call site: it printed a bare `LIVE` because the versions listing
carried no build, and said so in its own source — *"the released build is a fact
only Apple holds"* — which was true and is now recoverable.

**The phased release does not.** Same request could carry it, at
`include=build,appStoreVersionPhasedRelease` and a second resolver. Nobody
passes `--phased` and the consumer confirmed it has no plan to, so it stays
what read-api.md §"No field is missing" calls unproven — and *cheap* is not an
argument for adding a field to a published document.

**What the measurement changed, and it is not the cost.** Asked to run one
request against a live account, the consumer answered the three questions below
and a fourth nobody had asked: **the included `builds` resource carries the
build number itself**, in its `version` attribute, rather than only an id. So
this was never one request plus an N+1 — it is one request, and the "expensive"
half of the pricing above never existed. `expired`, `expirationDate` and
`processingState` ride along in the same payload; none is carried, because
`AppStoreBuildEntry` already answers for those from the builds listing and two
sources for one fact is the collision this format avoids on purpose.

**And one question came back unanswerable, which constrains the design rather
than delaying it.** Every version on that account is `READY_FOR_SALE` with a
build attached, so nothing exhibits a version Apple names *no* build for. The
un-included shape is measured — `relationships.build` with `links` and no
`data` key — but whether a genuinely buildless version says `"data": null` or
also omits the key is not. So `buildNumber` reports a null rather than
diagnosing one: an earlier draft would have printed *"this package asked
wrongly"* on stderr when the key was absent, and that would fire on an
unsubmitted version — a false alarm in the state an operator is most likely to
be looking at. It becomes answerable for free at this repository's next
release, the moment a `PREPARE_FOR_SUBMISSION` version exists.

**A `containsKey` branch to tell those two apart was written and deleted**, and
by the rule rather than by taste: the mutation that removed it passed every
test, because both arms produced null. Expressive code that guards nothing is
not a guard, and the distinction is now a comment in `reads.dart` beside the
line that does not act on it.

#### What blocked this until it was measured, and it was one sentence about Apple

`include=` demonstrably works in this package's hands — `appInfos` uses it for
categories and the age-rating declaration — and the `build` relationship
demonstrably exists, because `app_store.dart` `PATCH`es it on submit. What
nobody here can check is whether `build` is an *includable* relationship on the
`appStoreVersions` listing specifically. There is no live account behind this
repository and no recorded payload to read it out of.

**That matters more than it sounds, because of how it would fail.** A version
with no build attached and a query Apple silently ignored both produce
`buildNumber: null` — so a dead field would look exactly like a working field
answering honestly, in a document a consumer decodes. *"A store the output said
nothing about reads as a store with nothing wrong"*, one resource over.

**There is a way to tell them apart, and it is already measured here.**
`app_store.dart` records, against a live account, that a bare read returns **no
`data` key for a relationship at all**, and that adding `?include=` is what puts
one there. So an un-included read is *detectable*: `relationships.build` without
a `data` key is this package having asked wrongly, and `"data": null` is Apple
saying there is no build. Given that, `appstore versions` can say so on stderr
rather than emit a null — which converts the dangerous silent failure into a
loud one and makes the field safe to build.

**Whether that idiom generalises from `appInfos` to `appStoreVersions` was the
question**, and it took one request against a real account:

```
GET /v1/apps/{appId}/appStoreVersions?filter[platform]=IOS&include=build&limit=5
```

Run by the consumer, read-only. It does not 400; `included` comes back carrying
`builds`; and the two shapes are exactly the ones `appInfos` showed —
`relationships.build` with `links` and **no `data` key** without the include,
and `"data": {"type": "builds", "id": …}` with it. The idiom generalises.

**Recorded because the shape of the answer matters more than the answer.** The
blocker was never the cost, which this section had overstated twice; it was a
sentence about a third party that nobody here could check, in a package with no
live account behind it. That is a class of blocker this repository will meet
again, and the way through it was not more reasoning — it was asking somebody
who could run the request.

**And that cost is shared, which is the finding that should move this section
when somebody picks it up.** A second ask arrived while this was being written:
the consumer wants a summary grid where an App Store cell reads `LIVE (169)`
rather than bare `LIVE`, and Play can already do it because a track carries
`versionCodes`. Apple's version record carries no build — but
`appStoreVersions` **has** a `build` relationship and this package already
`PATCH`es it on submit, in `app_store.dart`'s "attached build" write. A
relationship that can be written can be read.

So `included` is not one client change for one caller. It is one client change
for **two related resources on the same listing** — the phased release and the
build — and pricing either against its own cost overstates both. Whoever takes
this up should price them together, and should expect that doing so moves this
section from *open* rather than confirming it.

Not built here, because neither is rollout state and the build number is a
want rather than a need: the consumer priced it itself as *"if it is not cheap,
say so and I will ship the bare `LIVE`"*.

**And the fraction is the thing not to build.** Apple's phased release carries
`phasedReleaseState` (`INACTIVE`, `ACTIVE`, `PAUSED`, `COMPLETE`) and
`currentDayNumber`, and **not a percentage**. The day-to-percentage table — 1%,
2%, 5%, 10%, 20%, 50%, 100% — is in Apple's support documentation, not in the
API response.

So a derived `audienceFraction` on the App Store side would be **a number this
package invented**, and it would be silently wrong the day Apple changes a
schedule it has never promised. Play *sends* the fraction; Apple sends a day
number. The two stores are not symmetric here, and the document should not
pretend they are: **the App Store side carries the state and the day, and no
fraction.**

That is `docs/CONTRIBUTING.md` §"A claim about both stores is checked against
both" as a design rule rather than a prose one — a field justified by "Play has
it" is a claim about the shared verb, written in whichever store the author had
in mind.

## The wait: not built, and this is the reason

Status: **decided**, 10 September 2026. Not built, and this section is why.

The re-file is right that the asymmetry is the design point, and right that
*"no events for `appstore wait`"* must not be generalised into *"no wait ever
needs typed progress"*. Processing is a state nobody wants a reading of; a
staged rollout climbing to 100%, or a version sitting in review for two days, is
the opposite.

**And the conclusion runs the other way.** *Because* the intermediate state is
the answer, a wait is the wrong container for it. A wait's contract is *block
until it is over, then exit* — which delivers the terminal state and discards
every intermediate one. A caller that wants to know it is at 20% wants a read it
can call at a moment of its choosing, not a process that will tell it only when
the answer is 100%.

Four things follow, and any one of them is enough:

1. **Nothing is blocked on it.** `appstore wait` exists because the next step
   genuinely cannot run: `what-to-test` and `beta-release` refuse a build Apple
   has not processed. Nothing refuses on a rollout percentage. The run that
   submitted the version is over — the artifact is uploaded, the notes are
   written, the tag is pushed.
2. **The duration is wrong for a process.** Processing is bounded:
   `awaitProcessing`'s own doc predicts 5–15 minutes and it carries a 45-minute
   timeout as the backstop, and two runs reported from the consumer's account
   came in at 44 s and 135 s — a figure from outside this repository, which
   measures nothing here. Review and rollout are hours to days. A CI job that
   sits for two days is a runner held for two days, and every honest
   orchestrator for a multi-day poll — cron, a scheduled workflow, a person at a
   terminal — calls a *read*.
3. **The stores already notify.** Apple e-mails on a review state change; the
   Play Console shows a rollout. This is where the console argument at the top of
   this document lands with full force: a `wait` here would be a worse copy of a
   notification that already exists, where a *read* is not a copy of anything —
   it is a field this package's own document promised to carry and does not.
4. **It would need an event schema that §Scope already killed on evidence.** The
   consumer spawns `appstore wait`, streams stdout to a log, heartbeats on the
   last line and consumes only the exit code. A rollout wait built to that same
   call site would be a wait whose only typed output is the one thing this
   section says it must not be — the terminal state.

**What replaces it is not nothing.** A read that carries the fraction is exactly
what a caller polls on its own schedule, and it composes with the scheduler the
caller already has. That is the whole of the "waitable" half of the re-file, and
it is answered by the readable half.

**What would reopen this**: a step in a release that genuinely cannot proceed
until a rollout reaches a threshold — a second store's promotion gated on the
first one's rollout completing, say. That is a real shape and nobody here has
it.

## What this does not decide

**Whether any of it goes into `read.dart`.** It should not, and
[read-api.md](read-api.md) §"What is left of the surface" is why: `--json` won
for the three reads, the consumer ported, its second entrypoint is deleted.
Adding rollout state to the library would spend a permanent API promise on a
surface whose own open question is whether it should have existed —
json-output.md §"What this does not decide" states exactly this consequence, in
advance, as the reason to do `--json` first. It was done first. The consequence
holds.

**Whether `schema` bumps.** It does not: every field proposed here is optional
and additive, which is [build-manifest.md](build-manifest.md) §Compatibility and
is the convention `--json` adopted unchanged.

Adding `inReview` and its siblings to `AppStoreState` is not a wire change
either, **and it is worth saying why in both directions, because only one of them
is obvious.** Backwards is the easy one: a document written before the addition
carries `"unknown"`, which stays a member. Forwards is the one that would sink
this if it were false — a *new* document says `"inReview"` and an *older*
consumer's `documents.dart` has never heard of it. It decodes as
`AppStoreState.unknown` rather than throwing, because `documents.g.dart` passes
`unknownValue: AppStoreState.unknown` to `$enumDecode`, and `appStoreStateRaw`
carries `IN_REVIEW` beside it. So an old consumer reading a new document lands
exactly where it lands today, which is the same place the enum's permanent
`unknown` member was put there to reach.

What it **is** is a source-breaking change for a Dart caller with an exhaustive
`switch` over `AppStoreState` — a different thing from a wire break, and one that
belongs in the changelog rather than in the schema number.

**Asked of the only Dart consumer there is, and grepped rather than recalled:
no such switch exists.** `AppStoreState` appears exactly once in that tree, in a
test fixture calling `.read()`. So this needs no pre-release on its account,
which is the question 4.3.0's own pre-release dance exists to make somebody ask.

**Two things in that answer are worth keeping, because both are evidence about
the conventions rather than about this change.** The consumer's newest reader
switches on `appStoreStateRaw` — the *string* — with a catch-all falling
through to Apple's own word, so the four members change nothing for it and its
`IN_REVIEW` handling keeps working either way. That is name-a-few-and-fall-back-
to-raw, arrived at independently on the consumer's side, which is some evidence
the two-vocabularies convention is right rather than merely ours.

And the one switch over a cux_ship enum that does exist there — over
`PlayReleaseStatus`, in the function that explains why a release is not serving
— carries a wildcard arm, so it is not exhaustive either. Worth knowing before
anybody adds a member to *that* enum on the strength of this section: the
argument above is about `AppStoreState`, and the fact that it also happens to
hold next door was checked rather than assumed.

**Whether `countryTargeting` is ever carried.** Recorded as a known omission,
not refused.
