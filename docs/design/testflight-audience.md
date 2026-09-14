# Which TestFlight audience holds a build

Status: **built**, and see §3, which is **open** and is the reason this file
exists rather than the feature being recorded only in a changelog entry.

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

## 3. `included` is capped at 50 per relationship

Status: **open**.

Same run, same request, both platforms:

| platform | builds | `buildBetaDetail` resolved | absent |
|---|---|---|---|
| ios | 51 | 50 | 1 |
| macos | 72 | 50 | 22 |

Exactly 50 on both, which is Apple's limit and not an account quirk.

**The two relationships in one `include=` behave completely differently at
scale, and that is why it was invisible.** `included` holds *distinct*
resources: this account has two beta groups in total, so `betaGroups` never
approaches the cap and resolves for all 123 builds. `buildBetaDetail` is one
resource per build and passes the cap at build 51. Whichever one is
spot-checked looks correct.

**Which 50 arrive is not the sorted order.** On macOS the absences fall at
positions 1, 5, 6, 13 … 71 of a newest-first listing, and four of the 22 are
attached to the external group — including build 179, the second-newest. The
builds a reader most wants an answer about are as likely to be missing as any
other.

**Why this is worse than a missing feature.** `AppStoreBuild.externalBuildState`
documents its null as *not known*, and a build Apple holds no detail for and a
build whose detail was truncated out of the response arrive as the same null.
Absence and failure wearing each other's clothes, which is the thing the rest of
this package spends paragraphs refusing one field at a time — and note that the
refusal was written for `betaGroups`, the relationship that did not need it.

**The information to separate them is on the wire and is thrown away.** A
truncated relationship still names an id in its `data`; only the resource is
missing from `included`. `_relatedOne` and `_relatedMany` both map that to the
same value as *no relationship at all*.

What a fix has to do, in order:

1. **Make *named but not received* representable.** Nothing else is possible
   until the parser stops collapsing it, and it is the minimum: it converts a
   false silence into a stated absence. `_relatedMany` has the same hole and it
   is sharper there, because an unresolved group list reads as `[]` — *attached
   to nothing* — which is a positive claim rather than a null, and §2's
   predicate then answers a confident `false`.
2. **Backfill the missing details** through `/v1/builds/<id>/buildBetaDetail`,
   which `reportExternalBuildState` already does one build at a time, for the
   builds whose detail did not arrive and no others. That keeps §1's
   no-extra-round-trip property for the common case and is correct in the
   uncommon one.
3. **Do not merely raise the cap.** `limit[…]` may be accepted on related
   resources, but it has its own ceiling and an account with 300 builds meets
   it again — the same defect deferred to a bigger account, and deferred past
   the point where anyone remembers to look.

**And the fake has to learn the cap**, or step 2's branch is unreachable from
every test — `docs/CONTRIBUTING.md`'s rule that a fake carries the semantics the
tested branch selects on, applied to a truncation instead of a filter.

**The trap in step 2, which is worth naming before somebody walks into it.**
`AppStore.builds` delegates to `buildsWithIncluded` and drops the map, which is
the arrangement `getAll` has over `getAllWithIncluded`. It is also what
`appstore promote` reads to decide which build goes to review. A backfill
written into `buildsWithIncluded` therefore fires on the promote path, where
nothing wants the audience — turning a release-critical single request into up
to twenty-two follow-up GETs, each of them a new way for a promotion to fail.
Today that delegation costs only a wider response body. The enrichment belongs
behind something the audience reader asks for and `builds` does not.
