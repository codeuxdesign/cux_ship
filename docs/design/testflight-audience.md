# Which TestFlight audience holds a build

Status: **built**, §3 included — it was **open**, and it was the reason this
file existed rather than the feature being recorded only in a changelog entry.
It stays because the measurement in it is the argument for a page size that
otherwise looks arbitrary.

`appstore builds` could say whether Apple had finished *processing* a build and
nothing about who could install it. Those are different facts: Apple hands every
processed build to every internal group automatically — an explicit assignment
is refused, `422 Builds cannot be assigned to this internal group` — while an
external group receives nothing until a beta release has submitted the build and
beta review has passed it. A consumer rendering one TestFlight column per
platform therefore drew a build nobody outside had identically to one they did.

The shape of the answer is in `AppStore.buildsWithIncluded` and
`AppStoreBuild`; this file carries what the code cannot say.

## 1. Two relationships on one request

`include=betaGroups,buildBetaDetail` goes on the existing `/v1/builds` read.
`betaGroups` names the groups and each carries `isInternalGroup`;
`buildBetaDetail` carries `externalBuildState`. The alternative was a GET per
build against a listing with no cap, and `AscClient.getAllWithIncluded` already
merged `included` across pages, so pagination needed nothing.

**Measured on a live account 2026-09-14** (`design.codeux.howitwent`, 51 iOS and
72 macOS builds). Apple accepts both includes on one request and resolves
`betaGroups` for every build on both platforms. One naming asymmetry is worth
writing down because it is not guessable: `include=buildBetaDetail` is singular
and sideloads resources of type **`buildBetaDetails`**. The relationship name
and the resource type differ on this one and not on `betaGroups`, and the fake
in `build_listing_test.dart` carries the mapping for that reason.

## 2. Delivery is two facts, and reading one of them was a constant `false`

Status: **decided**, by measurement, and it is the more useful half of this file.

`inExternalTesting` first read `externalBuildState == 'IN_BETA_TESTING'` —
Apple publishes that state, and the reasoning that picked it was sound as far as
it went: approval is Apple's verdict and delivery is the group assignment, so
`BETA_APPROVED` was deliberately excluded.

**Against a real account that predicate is never true.** Across 123 builds,
`IN_BETA_TESTING` did not occur once. Apple's terminal external state after
review is `BETA_APPROVED` — 14 iOS builds, every one of them attached to the
external group `Beta Testers`, all of which external testers demonstrably had,
and all of which reported that they did not.

The original reasoning was right and its conclusion was wrong, which is the
interesting part: **approval genuinely is not delivery — but the fact that
carries delivery is the group attachment, not a second state.** So the reading
is both fields or neither:

- true when the state has cleared beta review (`BETA_APPROVED`,
  `READY_FOR_BETA_TESTING`, `IN_BETA_TESTING`) **and** at least one attached
  group is external;
- false when the state has not cleared review — no assignment makes a build in
  review installable, so the groups need not be read;
- null when either input is missing, including when the only attached group
  came back with a kind Apple withheld.

`IN_BETA_TESTING` and `READY_FOR_BETA_TESTING` stay in the set because Apple
publishes them and one account is one account. An unobserved state is not an
impossible one.

**The general shape, which is why this is here and not only in a comment:** a
derived reading over a vocabulary taken from published documentation rather than
from a response is a guess with a type annotation. It passes every test written
beside it, because those tests are written from the same documentation. `usable`
is the counter-example that makes the rule visible rather than smug — it reads a
state this package has watched arrive for a year.

## 3. `included` is capped at 50 per **response**

Status: **decided**, by measurement, and built. The cap is real; the belief
that it was a property of the *query* was the expensive part, and it was never
tested.

Same account, same request, both platforms, at the two page sizes:

| platform | builds | resolved at `limit: 200` | resolved at `limit: 50` |
|---|---|---|---|
| ios | 51 | 50 | **51** |
| macos | 72 | 50 | **72** |

Exactly 50 at the larger page on both, which is Apple's limit and not an
account quirk — and **everything at a page of 50**, which is the whole fix.
`AscClient.getAllWithIncluded` already merged `included` across pages, so a
listing that never asks for more builds in one response than the cap will carry
back cannot be truncated. Two requests per platform instead of one, against 22
missing answers.

**The 72-build column pins the cap as inclusive.** 72 builds at 50 a page is a
first page of *exactly* 50 and a second of 22, and all 50 of that first page's
details came back — a ceiling of 49 would have left exactly one hole. So 50 is
a size that fits rather than one that just fails to, and the page size is 50
rather than a cautious 49.

**And it retracts a piece of evidence this document was resting on.** §2 counts
36 iOS builds `READY_FOR_BETA_SUBMISSION` and 14 `BETA_APPROVED` — which is 50,
not 51 — and the odd one out, build 67, was read at the time as a live instance
of a genuinely absent `buildBetaDetail`, and welcomed as such because it meant
the null arm had been seen rather than merely written. At `limit: '50'` it
resolves like every other build. **It was the cap, and there is now no observed
instance anywhere in 123 builds of a build Apple holds no detail for.** The null
arm stays — Apple documents the relationship as optional and one account is one
account — but it is defensive rather than evidenced, and the difference matters
to anyone deciding later what it is safe to delete.

That is the same mistake this section is about, one level up: an absence was
read as a fact because the thing that produced it was invisible.

**`limit[buildBetaDetail]` was never tried and no longer needs to be.** It was
the obvious-looking lever — App Store Connect does accept per-relationship
limits — and it is for *to-many* relationships, which `buildBetaDetail` is not.
The page size costs one extra round trip and has no ceiling of its own to meet
later.

**The two relationships in one `include=` behave completely differently at
scale, and that is why it was invisible.** `included` holds *distinct*
resources: this account has two beta groups in total, so `betaGroups` never
approaches the cap and resolves for all 123 builds. `buildBetaDetail` is one
resource per build and passes the cap at build 51. Whichever one is
spot-checked looks correct.

**Which 50 arrived was not the sorted order.** On macOS the absences fell at
positions 1, 5, 6, 13 … 71 of a newest-first listing, and four of the 22 were
attached to the external group — including build 179, the second-newest. The
builds a reader most wants an answer about were as likely to be missing as any
other.

That is an observation about a response Apple no longer sends this code, and it
is kept for one reason: it rules out the cheaper-looking remedy of *read the
first N and stop*. Had the truncation been a tail, a listing that asked about
the newest few builds would have been correct by accident, and the page size
would have been an optimisation rather than a fix.

**Why this was worse than a missing feature.** `AppStoreBuild.externalBuildState`
documents its null as *not known*, and a build Apple holds no detail for and a
build whose detail was truncated out of the response arrived as the same null.
Absence and failure wearing each other's clothes, which is the thing the rest of
this package spends paragraphs refusing one field at a time — and note that the
refusal was written for `betaGroups`, the relationship that did not need it.

### What was built

**The parser stopped collapsing *named but not received*, and that came first.**
A truncated relationship still names an id in its `data`; only the resource is
missing from `included`, and `_relatedOne` and `_relatedMany` both mapped that
to the same value as *no relationship at all*. They now answer
`(named:, resolved:)` and `(resolved:, unresolved:)`, and `AppStoreBuild`
carries `unresolvedBetaGroups` and `unresolvedBuildBetaDetail`.

This was the minimum whatever the remedy turned out to be — nothing can act on
a shortfall the parser cannot see — and it is sharper on the many side, where
an unresolved group list read as `[]`, *attached to nothing*, a positive claim
rather than a null. §2's predicate answered a confident `false` off it, and now
answers null.

**Then the page size, which made the shortfall unreachable rather than
handled.** `AppStore.buildsWithIncluded` asks for 50 builds a page because the
cap is 50 per response. That leaves the parser change as a *detector* rather
than a code path anything normally takes, which is deliberate: nothing in the
request tells Apple the two numbers are meant to be equal, so a lowered ceiling
or a third sideloaded resource per build would start truncating again, and the
listing now says `state not sent` instead of quietly answering null.

**A backfill was designed and not built.** One GET per missing build against
`/v1/builds/<id>/buildBetaDetail`, which `reportExternalBuildState` already
does one build at a time, for the builds whose detail did not arrive and no
others. It was the fallback if the cap had turned out to be per query. It was
not needed, and the hypothesis that made it unnecessary cost one line and one
live run to test — which is the order to do these in.

**The fake had to learn the cap**, or the remedy's guard is unreachable from
every test — `docs/CONTRIBUTING.md`'s rule that a fake carries the semantics the
tested branch selects on, applied to a truncation instead of a filter.
`_FakeClient.includedCap` models it per response and per relationship, and
that is load-bearing rather than decorative: with the cap removed from the fake,
`limit: '200'` passes the end-to-end test that exists to catch it. That was
observed, not assumed.

**The trap, which was real and narrower than it looked.** `AppStore.builds`
delegated to `buildsWithIncluded` and dropped the map, which is the arrangement
`getAll` has over `getAllWithIncluded`. It is also what `appstore promote`
reads to decide which build goes to review — and `promote` is its only caller,
`findBuild` and therefore `awaitProcessing` having always gone to `getAll`
directly with their own query. While the delegation cost a wider response body
it was harmless; a page size of 50 would have made it four times the round
trips on the release path to protect an `included` that path does not read. So
`builds` now builds its own query, and `_buildsQuery` holds the include and the
page size together because they are one decision.
