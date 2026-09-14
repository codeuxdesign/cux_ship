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

- **false when the build has expired**, before anything else is read — no state
  and no attachment makes a withdrawn build installable;
- null when the state is one this version has no word for, because *not
  cleared* and *not recognized* are different facts and the complement of the
  cleared set collapses them;
- false when the state has not cleared review — no assignment makes a build in
  review installable, so the groups need not be read;
- true when the state has cleared beta review (`BETA_APPROVED`,
  `READY_FOR_BETA_TESTING`, `IN_BETA_TESTING`) **and** at least one attached
  group is external;
- null when either input is missing, including when the only attached group
  came back with a kind Apple withheld, or when the group list came up short —
  but only where the shortfall could change the answer, since one *resolved*
  external group settles it whatever else went missing.

**Listed in the order they are asked, because the order is the part that kept
being wrong.** Two of this getter's four defects were precedence rather than a
missing rule: expiry had no position because the check did not exist, and the
shortfall arm sat above the positive answer in its first draft. The five arms
above are pinned in `build_listing_test.dart` by a table of *guard against the
guards after it*, and the vocabulary the second and third arms turn on is
pinned by one row per state Apple names — a list nothing checked, which was
free to be wrong in either direction until it had rows.

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

**`included` is not the first 50 of `data`, and that is now proven rather than
suspected.** Apple's `data` order under `sort=-version` is strict numeric
descending — measured, see §4 — so "the first 50 of `data`" is a well-defined
set, and the 22 holes are not its complement: **16 of the 22 sat inside Apple's
first 50**, build 179 among them, second in the response, while builds far
below it got their details.

So whatever selects the 50 that arrive, it is not position in the listing.

**What that does and does not rule out**, because it is easy to take too far.
It does not say a page can come back holed while it is *under* the cap: 50
builds naming 50 details resolved all 50, and the 72-build read at a page of 50
resolved all 72. Demand within the ceiling has never been observed to be
truncated. What it rules out is the weaker-looking move of keeping the large
page and reading only the top of it — the sideloads do not line up with the
front of `data`, so the builds a reader asked about are not the builds whose
resources arrived.

And it makes the parser change the load-bearing half of this section rather
than its preliminary. The page size stops the holes at today's sizes; nothing
but [AppStoreBuild.unresolvedBuildBetaDetail] would notice if that stopped
being true, and since the selection rule is unknown, "it stopped being true"
is not something that could be predicted from the request.

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
reads to decide which build goes to review. It has **two** callers and both
discard the sideloaded map — that one, and `printBuildNumber`, whose output a
shell script captures to name a release; `findBuild` and therefore
`awaitProcessing` have always gone to `getAll` directly with their own query.
So both callers of the plain read are on a release path and neither wants the
audience, which is a better reason for the split than *promote is the only
one*, and is what that sentence said until review caught it. While the
delegation cost a wider response body
it was harmless; a page size of 50 would have made it four times the round
trips on the release path to protect an `included` that path does not read. So
`builds` now builds its own query, and `_buildsQuery` holds the include and the
page size together because they are one decision.

## 4. How much of the listing a read needs

Status: **decided**, and the decision is that the listing stays whole and
nothing is built. Kept because the measurements are what settled it, and
because the same question will be asked again the next time somebody counts the
round trips.

§3 made each response smaller. It did not make the *listing* smaller: every
`appstore builds` run still reads every build App Store Connect holds for the
app on that platform, following `links.next` to exhaustion — and §3 made that
four times as many requests, since the page size went from 200 to 50. Asked
whether that could be avoided by caching, or by reading fewer builds.

**The short answer is that the listing's callers need the listing.** The
consumer's grid is a join over every version ever uploaded, not a snapshot of
the current one, and paging at the cap is the cheapest *correct* read of that
question — every scheme that keeps the larger page and repairs it afterwards
costs more. What did come out of asking is two corrections to what this package
says about Apple, below, which is the better half of the section.

### The listing does not shrink, and the account is too young to prove it

**An expired build stays listed** — `AppStoreBuild.expired`'s own dartdoc says
so, and it is a flag rather than a removal — so the row count is the account's
whole upload history and grows at the upload cadence forever.

Measured 2026-09-14 on `design.codeux.howitwent`, both platforms:

| | |
|---|---|
| builds | 51 ios, 72 macos |
| expired | **zero, on both** |
| oldest upload | 2026-08-16 |
| newest upload | 2026-09-14 |

The account is thirty days old and TestFlight expires at ninety, so nothing on
it *can* have expired yet. Two things follow, and the second is the
uncomfortable one:

- **`filter[expired]=false` would cut nothing today.** It is a real future
  lever — from 2026-11-14, the account's first expiry, it would hold the
  listing to ninety days of
  uploads instead of all of them — and there is currently no account to
  measure it against. Whether Apple accepts the parameter at all is still
  unanswered.
- **"an expired build is still listed" has never been observed.** It is this
  package's belief, stated in a dartdoc, and the first opportunity to check it
  is that same November date. The whole of this section's *growth* argument
  rests on it, so it is worth checking before acting on it: if Apple in fact
  drops expired builds from the listing, the listing plateaus on its own at
  ninety days of cadence and the growth problem does not exist.

At 72 builds in 30 days and a page size of 50, today's cost is **two requests
per platform**. That cadence is 2.4 builds a day, so **a year from now** the
account holds roughly 950 — the 72 it has plus 876 more — and the listing costs
**nineteen** requests per platform per run. Every figure in this section counts
that way: *in a year* means the total the account has reached, not one year's
uploads on their own. The problem is real and it is not yet urgent, which is
the honest summary.

### Caching is the wrong shape, and it is the shape §3 is about

The fields worth reading — `processingState`, `expired`, `betaGroups`,
`externalBuildState` — are exactly the mutable ones; they are what the listing
is *for*. A cached row is stale data indistinguishable from fresh data, which
is §3's conflation with *stale* wearing *current*'s clothes rather than
*truncated* wearing *absent*'s.

Nor is there a cheap way to keep one honest. App Store Connect publishes no
`ETag` or `If-Modified-Since` on these collections to revalidate against, and
no `uploadedDate` range filter to fetch only what is new — so a cache would
need an invalidation rule of its own invention. The one class of build that is
safely frozen (past its ninety-day expiry) is derivable locally from the
immutable `uploadedDate` and saves no request, because the request is what
would tell you the rest.

### Apple's ordering, measured — and two of this package's claims were wrong

Measured 2026-09-14 by overriding the sort key on a throwaway branch and
printing the raw `data` order to stderr, which is the only way to see it: the
model sorts the payload before any caller does, and `--json` takes no sort
override.

**`sort=-version` is numeric, not lexical.** Strict numeric descending over all
72 macOS builds — under a lexical sort `98`, `94` and `75` would have led the
response, and they sat at positions 51 to 53, below `100` and `101`. Three
comments in this package said otherwise, one of them citing it as a
twice-made mistake; they are corrected, and `read-api.md` carries a dated note
because it argued from the same belief.

**Where the lexical claim came from, because it is instructive.** It entered in
`02aa183` (6 August 2026, "Add tool/asc_upload, an App Store Connect client"),
as an inline comment beside a defensive client-side sort in `printBuildNumber`
— in the same commit that wrote the client by hand over `package:http`. It
cites no response and no account. It is an assumption written in the voice of
an observation, which is the form that survives review, and `8356844` then
promoted it to a twice-made mistake and copied it into `read-api.md` and
`AppStoreBuilds.builds`. Nothing measured it until 2026-09-14, thirty-nine days
later.

**And it is almost certainly a confusion between two different version
numbers** — the one this repository names as *the single easiest thing to get
wrong here*, at [AppStoreBuild.buildNumber]. Two adjacent facts are true:

- a marketing version sorts wrongly as a string — `1.0.10` below `1.0.9` —
  which is why `release.dart` parses semver rather than comparing text;
- comparing `CFBundleVersion`s as Dart strings is wrong — `"9"` above `"10"` —
  which is the bug a consumer actually shipped.

Neither is a fact about Apple's sorting. `sort=-version` on `/v1/builds` orders
`attributes.version`, which is `CFBundleVersion` — the `180` in `1.1.7+180`,
assigned by `cux_buildnumber` and not by Apple, and a bare integer on every
account this package has read. The hazard that belongs to the *marketing*
version was carried onto a field that is not one, and Apple sorts it as the
number it is. So the false step was inferring a remote system's behaviour from
a local type's, and the local type's hazard is real, which is what made it
sound.

**The client-side numeric sort stays, and its real justification is narrower
than its old one.** What was disproved is *lexical for integer build numbers*.
`CFBundleVersion` need not be an integer — Apple accepts `1.2.3` — and how
Apple orders those against each other is untested on any account, so a package
that deleted the comparator on the strength of this would be trusting an
ordering it has only ever seen the easy case of.

**`sort=-uploadedDate` is accepted, and genuinely applied.** That it returned
the same order as `-version` proves nothing on an account where build numbers
rise with upload time — an ignored parameter looks identical — so two further
requests settled it: `sort=uploadedDate` returns the exact reverse of all 72,
and `sort=nonsenseKey` returns

```
400 … 'nonsenseKey' is not a valid sort value — (sort)
```

Apple validates sort keys and refuses unknown ones by name, so a key that
passes validation *and* inverts under a sign change is one it applies. A
bounded read can therefore order server-side, by either key.

### A bounded listing is technically possible and is ruled out on the consumer's numbers

With the ordering measured, `sort=-version&limit=N` returns the newest `N`
builds by build number, server-side, in one request — and for `N` at or below
the cap the sideloads all arrive, so the audience comes with it. That is
**one request per platform at any account size**, against `ceil(B / 50)` today:
two now, nineteen at a year of this cadence.

**It is still wrong, and the margin is two days.** The consumer's grid is not a
snapshot; it is a join of the whole listing against every `uploaded/vX.Y.Z+N`
tag in its repository — 108 tags, nine rendered rows, back to version 1.1.0.
The oldest build it needs is 122, which is rank 26 of 51 on iOS and **rank 45
of 72 on macOS**. At `limit: 50` that is five builds of headroom, and at the
measured 2.4 builds a day it runs out in about two days. The row would then go
blank rather than error — *no build for this version* wearing the clothes of
*I did not read far enough*, which is §3's defect reappearing in the consumer.

That is the argument that bites; the one below is the general one.

§3's non-positional finding does not block that. It rules out keeping the large
page and reading the top of it; it says nothing against asking for a small page,
which is demand inside the ceiling and has never been observed to truncate.

Two things are genuinely owed before it is built, and neither is a blocker so
much as a thing to be honest about:

- **Dotted build numbers are untested.** The ordering measurement covers 72
  integers. If Apple orders `1.2.3`-style `CFBundleVersion`s in a way the
  client-side comparator disagrees with, a bounded read returns the wrong `N`
  and the local re-sort cannot repair it — it can only reorder what arrived.
  That is the one case where bounding turns a cosmetic disagreement into a
  missing build.
- **It narrows what `appstore.builds` answers**, and that is the real cost.
  Today the document carries every build Apple holds; bounded, it carries `N`.
  `newestBuildNumber` and `newest` survive, `newestUsable` survives unless more
  than `N` consecutive newest builds are unusable, and `build("34")` starts
  answering null for a build Apple still holds. A consumer asking about an
  older build would get *no such build* where the truth is *not read*, which
  is this document's recurring failure with a new face.

### The alternative that narrows less, and costs more

Read the whole listing **without** includes, then ask for the audience of the
newest few through `/v1/builds/<id>/buildBetaDetail` — a read
`reportExternalBuildState` already makes one build at a time. The listing stays
complete, so every accessor keeps answering what it answers now and only the
*audience* is bounded, which is a narrowing the model can already express:
`betaGroups: null` means *this read did not ask*.

Every option counted the same way, at 72 builds with `N` of 20:

| | requests | now | in a year |
|---|---|---|---|
| **today** — page at the cap | `ceil(B / 50)` | **2** | 19 |
| the old, wrong page size | `ceil(B / 200)` | 1 | 5 |
| bounded listing | `1` | 1 | 1 |
| bounded enrichment | `ceil(B / 200) + N` | 21 | 25 |
| large page, backfill the holes | `ceil(B / 200) + holes` | 23 | — |
| detail only where an external group is attached | `ceil(B / 200) + 14` | 15 | — |

**Only the bounded listing beats paging at the cap, and it is the one that is
wrong.** Every scheme that keeps the 200-build page and repairs the truncation
afterwards costs an order more, because a repair is a request per build and a
page is a request per fifty. That is worth having in a table: 4× the round
trips of a wrong answer looks like something to optimise until the alternatives
are counted.

Bounded enrichment is kept in the list because it is the only one that costs
nothing semantically — the listing stays complete and only the *audience* is
bounded, which the model can already express, `betaGroups: null` meaning *this
read did not ask*. It is simply not worth 21 requests.

### The general argument, which outlives this consumer's tag list

*Which build does each testing group have* looks like a question a small read
could answer, and a bounded listing cannot answer it even when the caller wants
only that. Delivery to an external group is not recent by construction: if
nobody has shipped externally for three months, that group's current build is
two hundred rows down. A newest-`N` read finds nothing attached and the column
renders empty — *nobody outside has anything*, where the truth is *I did not
read far enough*.

**Bounding is only safe for a question whose answer is guaranteed to sit near
the top of the ordering being bounded, and neither question here is.** The
consumer's is anchored to a tag list going back nine versions; the general one
is anchored to whenever somebody last shipped. That is the durable form of the
two-day number above, and it is why this is decided rather than deferred.

### Decided: nothing is built, and the listing keeps its price

`appstore builds` goes on answering *every build Apple holds* at
`ceil(B / 50)`. That is the honest price of the question, and §3 is why it is
not `ceil(B / 200)`: the cheaper page returned a wrong answer for 22 of 72
builds. The alternatives that keep the larger page and repair it afterwards are
worse anyway — backfilling the 22 missing details is 23 requests against 2, and
fetching `buildBetaDetail` only for the 14 builds with an external group is 15.
**Paging at the cap is the cheapest correct read of this question**, which is
worth stating because 4× the round trips of a wrong answer invites a second
look that this saves.

**A per-group read would be an addition with no caller, so it is not built
either.** It is a genuinely better answer to *who has what right now* — roughly
`1 + (external groups)` requests, flat in build count — but the consumer that
prompted this needs the historical join and would still read the full listing,
so it would save nobody anything today. `read-api.md` records what this package
does with a surface that has no known caller, and it is not to keep it.

Two measurements make the shape of that read cheaper to revisit, so they are
recorded rather than discarded. **Internal attachment is universal**: 51 of 51
iOS builds and 72 of 72 macOS builds carry the internal group, so
*the internal group's current build* is not a group question at all — it is the
newest processed build. External attachment is real data, 14 builds on each
platform, spanning 53 to 180. And **beta groups are app-wide, not
per-platform**: this account has exactly two, and both platforms' builds
reference the same two, so a four-column `internal × platform` grid cannot come
from groups — the platform split has to come from the builds.

**And the universal attachment has a declarative cause, which turns a repeated
claim into data.** The sideloaded `betaGroups` resource carries
`hasAccessToAllBuilds: true` on the internal group and `null` — not `false` —
on the external one. So *Apple hands every processed build to every internal
group*, a sentence this package has been repeating from Apple's documentation
since the audience work began, is a flag on the wire that could be read. It is
not read today and nothing needs it; it is recorded because the next person to
want the internal column has a better answer available than an empirical 72 of
72, and because `null` rather than `false` on the group that does not have it
is this document's own distinction appearing in Apple's data.

### What else the group resource carries

`cux_ship` keeps a group's `name` and `isInternalGroup` and discards the rest
at parse time, so the narrowing is this package's rather than the wire's. What
Apple actually sends, measured 2026-09-14: `createdDate`, `feedbackEnabled`,
`hasAccessToAllBuilds`, `iosBuildsAvailableForAppleSiliconMac`,
`iosBuildsAvailableForAppleVision`, and a public-link family
(`publicLinkEnabled`, `publicLinkId`, `publicLinkLimitEnabled`,
`publicLinkLimit`, `publicLink`). The group's `relationships` — `app`,
`builds`, `betaTesters`, `betaRecruitmentCriteria` — are links-only with no
`data`.

**Nothing dates a delivery.** `createdDate` is the group's own, and there is no
per-build timestamp on the group or on a build's `betaGroups` relationship. So
*when did external testers get this* cannot be answered from the read this
package already makes, and adding it would be a new question rather than a free
field — which is what the probe was for, and the answer being no is worth the
same as the answer being yes.

### What a build's attributes carry, and what they do not

Measured the same way, all 72 macOS builds: `version`, `uploadedDate`,
`expirationDate`, `expired`, `processingState`, `minOsVersion`,
`lsMinimumSystemVersion`, `computedMinMacOsVersion`,
`computedMinVisionOsVersion`, `iconAssetToken`, `buildAudienceType`,
`usesNonExemptEncryption`. Two of those bear dates, and they are the upload and
the expiry.

**There is no modification timestamp on a Build, which settles incremental sync
by removing its precondition rather than failing it.** The plan was to sort
newest-modified-first, hold a watermark, and page until reaching it. The
question posed against that was the careful one — not *does a Build carry a
modification timestamp* but *does it move when a related resource changes*,
since `externalBuildState` lives on `buildBetaDetail` and the audience is a
relationship, so a timestamp tracking only the Build would sit still while both
facts this listing reports change. **That question never gets asked, because
there is no field to ask it of.** It is recorded in its careful form anyway:
the crude version would have been satisfied by an upload-only timestamp, which
is the likelier trap and the one that would have shipped a sync silently
missing every overnight approval.

**`buildAudienceType` is `APP_STORE_ELIGIBLE` on all 72 and is not a shortcut.**
It describes store eligibility rather than testers, so despite the name it does
not answer who has the build. Written down so the next reader does not spend
the request finding out.

**Caching belongs to the consumer, for a better reason than statelessness.**
The argument against it here was staleness, and opt-in caching with a stated
age answers that. What does not survive the move is *invalidation*: a
per-read spawned CLI can only invalidate on age, which is the weakest rule
available, while the caller that just ran an upload knows it invalidated the
store. The cache belongs where the writes are, not where the reads are.

**Progress reporting would report on the part that is not slow.** A `status`
run spawns five reads and takes about 50 seconds, most of it Dart startup
rather than HTTP. If it is ever built, the requirement is already fixed: `==> `
prose on stderr, which is this package's existing convention and which the
consumer's panel already parses as a phase milestone, with the document
untouched on stdout. NDJSON would need a parser on both sides to be no better.

**`filter[expired]` is closed as *wrong*, which is a stronger answer than the
two this section reached on the way to it.** It was first written down as *too
early* — nothing has expired yet — and then, worse, as *not needed*, on the
grounds that every build carries an `expirationDate` so expiry is derivable
client-side. **That second reason was a conflation and is retracted.**
`filter[expired]` was a lever on how many builds *come back*; deriving expiry
from a field requires the build to be in the response already, so it does
nothing whatever for request size. The two facts are unrelated and one was
being used to close the other.

The real reason is the one this section already established about bounding, and
it applies unchanged: **filtering expired builds out breaks the consumer's grid
by the same mechanism, on a date that can be named.** That grid needs build 122
for its 1.1.0 row; build 122 was uploaded 2026-08-28 and Apple gives its expiry
as 2026-11-26. From that day `filter[expired]=false` drops it and the row loses
its cells — *no build for this version* wearing the clothes of *I filtered it
out*. The first build on the account expires 2026-11-14, so the window in which
this looks harmless closes in under two months.

So expired builds are not noise to be filtered; they are **history the caller
asked for**, exactly as the old builds a bounded read would have dropped.

### The ninety days is measured, nothing depends on it, and nothing would notice

`expirationDate - uploadedDate` is ninety days on all 72 builds without
exception. That is a fact about Apple's retention policy today, and **there is
no mechanism in this package that would notice if it changed** — no test can
assert against Apple's policy, and the two detectors this branch added work
because they compare things *within one response*, which a retention period has
no counterpart for.

The correct response to *nothing would notice* is not to build a detector for
it. It is to make sure nothing depends on it, and to say so out loud:

- **`expired` is Apple's own boolean**, read straight off the build, so a
  changed period is reported correctly with no arithmetic of ours involved.
- **`expirationDate` is per-build and on the wire**, so any caller wanting *how
  long until this expires* reads Apple's answer rather than computing one.
- **Nothing computes with ninety.** It appears in two dartdocs as context, and
  it used to appear in a user-facing error — `appstore beta-release` telling an
  operator that *TestFlight builds last 90 days* — which is now that build's
  own `expirationDate`, reported rather than asserted.

That last one is the whole of the risk and it was worth removing: a constant
stated in prose, that no test reads and no reader can disprove, is precisely
the shape `sort=-version` was wrong in for thirty-nine days. The number stays
recorded here as a measurement with a date on it, which is a different kind of
claim from a number the code speaks as though it knows.

**The one thing still resting on documentation** is that an expired build stays
*listed* at all. No build on this account has ever expired; 2026-11-14 is when
that becomes checkable, and §4's growth argument is what rests on it.

### The failure mode this section is actually an example of

Every other correction in this document fell to the same remedy: stop reasoning
and ask the store. The page size, the lexical sort, the universal internal
attachment, `unresolvedBetaGroups` being complete — each was a belief a live
request overturned, and each is an argument for measuring earlier.

**This one was a measurement, and the error was downstream of it.**
`expirationDate` is on the wire, ninety days exactly, all 72 builds: correct,
observed, and not in dispute. The mistake was concluding from it that
`filter[expired]` was unnecessary — a lever on *how many builds come back*,
closed by a fact about *what is computable once a build is already in the
response*. Two different questions, one answering the other, and the
measurement's authority carried the reasoning past two reviewers who had spent
six rounds being sceptical of everything else.

So the narrower rule, which is the one this section is worth keeping for: **a
measurement closes the question it measures, and the step from there to a
conclusion is ordinary reasoning with no special protection.** A number with a
date on it makes the sentence containing it *sound* measured. The probe-first
habit does nothing about that, because the probe was run and came back right.

What caught it was somebody asking *are you sure, and how would we notice* —
about the retention period, not about the conclusion. That is the check with no
process behind it, which is why it is written down here rather than turned into
a rule.

The reason to write all this down rather than act on it is the one §3 earned
the hard way: the previous change to this request was made against a
measurement, and the measurement is what made it right. The measurements here
say the option exists and that it is not yet worth taking — which is a smaller
claim than the ones above, and the one thing in this section that would change
on its own, without anybody touching the code.
