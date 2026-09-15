# When did a version actually reach the public?

Status: **built**, 15 September 2026 — `cux_ship storefront released`, its own
`storefront.released` document, and exit code 6.

**The question App Store Connect cannot answer.** A release train's grid says
*where* each version is per store — `LIVE`, `IN REVIEW`, `PENDING DEVELOPER
RELEASE` — and had no way to say *when the public got it*. That is the one
column a human reading the grid asks for first, because it is the only one that
answers "did the thing I shipped on Tuesday actually go out on Tuesday".

## Why the authenticated API is not the answer

`appStoreVersions` carries two dates and neither is this one:

| attribute | what it is |
|---|---|
| `createdDate` | when the *version record* was created, in Prepare for Submission — typically days or weeks before release, and set by whoever first typed a version number into the console |
| `earliestReleaseDate` | the floor a scheduled release may not go out before. **Null for a manual release**, which is every release this tooling makes |

Apple's own forum thread has this unresolved with a filed feedback asking for
the field: <https://developer.apple.com/forums/thread/695330>.

**The `appStoreVersionPhasedRelease.startDate` workaround does not apply
here.** It exists only when phased release was enabled, and this package
creates a phased release only under `--phased`, which the consumer that asked
for this leaves off. So on a normal release there is no phased-release resource
to read a date off.

And **cux_ship carried no date field at all** on the App Store version side
before this: `AppStoreVersionEntry` is versionString / appStoreState(+Raw) /
releaseType(+Raw) / copyright / editable / buildNumber / buildNumberAsInt /
display. Nothing in `lib/src/appstore/` read a date; `earliestReleaseDate`
appeared only in prose around the `SCHEDULED` release type.

## The public storefront does answer it

Unauthenticated, one GET, no credential of any kind:

```bash
curl -s 'https://itunes.apple.com/lookup?bundleId=design.codeux.howitwent&country=us'
```

returns, among sixty other keys:

```
version                    1.1.6
currentVersionReleaseDate  2026-09-10T21:48:31Z
releaseDate                2026-08-25T07:00:00Z
trackId                    6802083801
trackName                  How It Went
kind                       software
```

`currentVersionReleaseDate` is the answer. `releaseDate` is the app's *first
ever* release and is a trap — see §"Apple's names do not survive".

## Its own subcommand, its own kind, its own counter

**`cux_ship storefront released`, and not a field on `appstore versions`.**

This is a **different Apple product** from App Store Connect. It is the
storefront: undocumented, rate-limited, with no published schema, no
deprecation policy, and known cases of the date being wrong
(<https://developer.apple.com/forums/thread/710663>). App Store Connect is a
documented REST API with a versioned surface.

Folding this into `appstore.versions` would put both behind one `schema`
promise, and the day the storefront drifts — a renamed key, a shape change, a
response that stops being JSON — it takes the versions read down with it. A
consumer would lose the answer to *"which build does the store hold"*, which is
authenticated, documented and working, because an undocumented endpoint moved.

**Its own kind fails in its own lane.** `storefront.released` counts its schema
separately, exactly as [json-output.md](json-output.md) argues for the other
kinds: one counter per kind, so a change here never tells a consumer of
`appstore.versions` to re-read anything.

The subcommand is named for what it describes rather than for the mechanism —
the same rule that made `appstore.listing-diff` not `appstore.dry-run`. It is
not called `lookup`, which would name Apple's endpoint, and not `version`,
which would sit one letter from `appstore versions` and invite exactly the
confusion this section exists to prevent.

**The group holds one subcommand today, which is ordinary here** — `screenshots`
and `manifest` each hold one too.

**And `storefront` names an Apple thing only.** Google Play has a public
listing with an "Updated on" date, and it is HTML on a web page; there is no
API behind it. Nothing should ever be added under this group for Play — see
§"Play has no equivalent", which is written down precisely because a group
named for a store-neutral noun invites somebody to try.

## It consumes no credential, and the argv says so

Every other read the consuming train makes is spawned as:

```
secrets exec --only <credential> -- tool/ship appstore versions --json …
```

Its `_appstore()` helper prepends that unconditionally. **This read must not go
through that helper and must not be wrapped in `secrets exec` at all.**

`--only` exists so that `--store play` never places an Apple key
([only-selector.md](only-selector.md)). A read that places *no* key is the same
principle one step further, and the place it has to be visible is the command
line — because that is what a person reads in a log after a failure, and what
`secrets exec` itself reports on. A credential-free read wrapped in a
credential placer is indistinguishable, from outside, from one that needs the
credential.

That is also why this is not a subcommand of `appstore`: every member of that
group loads an App Store Connect key, and a credential-free read sitting among
them would read as one that had simply not got to the auth step yet.

**Nothing here places, reads or requires an environment variable.** There is no
`--only` selector for it, and there is nothing for one to select.

## It answers per app, not per platform — measured

This was the constraint most at risk of being assumed, so it was measured. The
app is a universal purchase, listed for iOS and macOS under one bundle id.

```bash
# identical output, all four:
curl -s '…/lookup?bundleId=design.codeux.howitwent&country=us'
curl -s '…/lookup?bundleId=design.codeux.howitwent&country=us&entity=software'
curl -s '…/lookup?bundleId=design.codeux.howitwent&country=us&entity=macSoftware'
curl -s '…/lookup?id=6802083801&country=us&entity=macSoftware'
```

All four return `resultCount: 1`, the same `trackId 6802083801`, the same
`version 1.1.6`, the same `currentVersionReleaseDate`, and `kind: "software"`.
**`entity` is a parameter of `/search`, and `/lookup` ignores it.**

So the Mac half was asked for through `/search`, which does honour `entity`:

```bash
curl -s '…/search?term=How+It+Went&country=us&entity=macSoftware&limit=10'
```

It **finds the app** — one result, because it is available on the Mac — and the
result is the *same record*: `kind: "software"`, `trackId 6802083801`, version
1.1.6, the same date. There is no separate Mac record, no second trackId, and
no second date.

**Conclusion: for a universal purchase the storefront holds one product, and it
cannot be asked per platform.** The document therefore describes **an app**,
and has **no `platform` field** — which is structural rather than documentary:
a consumer cannot accidentally fill two per-platform grid columns from it,
because there is nothing in the document to key them on.

`kind` is carried, as `productKind`, and it is the only platform-adjacent
signal there is. **It names the record's product type, not a platform**:
`software` for this app even though it runs on the Mac, and `mac-software` for
a Mac-only listing (measured against `com.apple.dt.Xcode`, which comes back
`mac-software`). Reading it as "this is the iOS release" is wrong for exactly
the universal-purchase case this whole section is about, so it is carried raw
and named for what it is rather than turned into a platform enum. That is a
deliberate departure from [json-output.md](json-output.md) §"A store's
vocabulary arrives twice", and the departure is the honesty: our own vocabulary
over this field would be a vocabulary of platforms, and there is no platform
here to name.

**What a caller with two genuinely separate listings does.** A project that
ships its Mac app under its own bundle id has two records and can ask twice —
once per bundle id — and `productKind` is how it confirms which it got. That is
the only shape in which a per-platform answer exists, and it is a property of
how the app was listed rather than something this command can offer.

**`--bundle-id` defaults to the *iOS* identifier** read from the project, since
that is the one a universal purchase is listed under. A separately-listed Mac
app needs the flag.

## `--country`, with a default, and the failure it can cause

**A flag, defaulting to `us`.** The storefront is per region, and `country` is
what chooses which one answers.

Not inferred from the machine. Inference would make the same command answer
differently on a developer's laptop and on CI, which is the class of bug this
repository keeps paying for; `us` is a value somebody chose, visible in the
argv and overridable.

**The date was measured identical across six storefronts** — `us`, `de`, `jp`,
`gb`, `au`, `br` — all returning 1.1.6 at `2026-09-10T21:48:31Z`. That is
evidence about one app's release, not a promise: an app rolled out to regions
on different days would presumably differ, and nothing here has measured one.

**The hazard worth naming: an app not sold in `--country` answers
`resultCount: 0`**, which is indistinguishable from an app that has never been
released anywhere. So a project whose app is not available in the US storefront
must pass `--country`, and would otherwise be told, every run, that it has
never shipped. This is the main reason the flag exists rather than the value
being hard-coded, and the command's `--country` help says so.

An unrecognized country is Apple's own **HTTP 400** and is reported as a
failure, not as an absence.

## Absence is an answer, and it gets both halves

An app the storefront does not know returns **HTTP 200** with
`{"resultCount":0,"results":[]}`. That is not an error, and reporting it as one
would put a readiness check on the commonest path of a not-yet-released app
into the same bucket as a network failure — the exact defect
[`noSuchVersionExit`](../../cux_ship/lib/exit_codes.dart) was cut for.

So both halves are given:

- **Exit code 6, `notOnStorefrontExit`.** A new number rather than reusing 5,
  by README.md's stated rule that an existing code never changes meaning and a
  new condition takes a new number. "App Store Connect holds no version named
  1.1.8" and "the public storefront has never heard of this app" are different
  conditions with different next actions, and a caller branching on one number
  for both would report a version that has not been created yet and an app that
  has never shipped as the same sentence.
- **The document is still printed**, with `app: null` and a `display` line
  saying so.

**That second half is a deliberate exception to json-output.md §"stdout is the
document", which says errors leave stdout empty.** It is not an exception to
the rule; it is the rule applied to something that is not an error. The
distinction that section draws is between a *failure*, where prose on stderr is
the report, and an *answer*, which belongs in the document. Absence is an
answer — and the practical consequence is that the consumer renders `display`
rather than composing its own "not released yet" sentence, which is the entire
reason `display` exists.

`appstore wait-previews` already took this shape for the same reason: it prints
a document on the path where there is nothing to report, because "no output"
is not something a decoder can be asked to accept from a command that
succeeded.

## Apple's names do not survive, and that is the argued half

[json-output.md](json-output.md) and `AppStorePreviewEntry` both keep Apple's
field names, deliberately, so a reader can hold the document beside Apple's
reference page. **That argument does not reach here, because there is no
reference page.** The storefront is undocumented; there is nothing to hold it
beside.

What there is instead is legacy iTunes Store vocabulary — an app is a "track" —
and one name that is actively dangerous:

| Apple's key | ours | why |
|---|---|---|
| `currentVersionReleaseDate` | `versionReleasedDate` | when the public got **this** version. The answer. |
| `releaseDate` | `firstReleasedDate` | the app's **first ever** release. Reads as *the* release date and is not. |
| `trackId` | `appleId` | the numeric app id App Store Connect calls the Apple ID |
| `trackName` | `appName` | |
| `trackViewUrl` | `storeUrl` | |
| `kind` | `productKind` | and the envelope already has a `kind` |

Every one of those carries Apple's key in its own dartdoc, so the mapping is
one hop away and lives beside the field rather than in a table here that would
drift.

`releaseDate` → `firstReleasedDate` is the row that earns the whole table. A
consumer reaching for "the release date" and getting the app's launch date
would render a plausible, wrong answer in the one column this document exists
to fill, and nothing would look broken.

**Both date fields read correctly in isolation**, which is this repository's
rule for derived and paired fields alike: `versionReleasedDate` and
`firstReleasedDate` cannot be read in the wrong order, because neither name
leaves anything for the other to disambiguate.

**Strings, not `DateTime`** — json-output.md §"`uploadedDate` stays a string".
Apple already spells these ISO-8601, and `DateTime.toIso8601String` is not the
string Apple sent.

## No retry, unlike the App Store Connect client

`AscClient` retries 429 and 5xx, because a long upload that dies on Apple
having a bad minute has thrown away real work. This read is one GET, and
nothing is lost by it failing — so a 429 is **reported**, naming the rate limit,
rather than retried behind the caller's back. A retry loop here would turn the
one fact a caller needs ("you are asking the storefront too often") into a
delay they cannot see.

## Play has no equivalent, and none should be invented

Confirmed from Google's own reference for `edits.tracks`
(<https://developers.google.com/android-publisher/api-ref/rest/v3/edits.tracks>):
`TrackRelease` is name / versionCodes / releaseNotes / status / userFraction /
countryTargeting / inAppUpdatePriority. **There is no timestamp anywhere in the
resource**, and the Edits API cannot list past edits — an edit is a transaction
that is committed and gone.

The public Play listing shows "Updated on", and reaching it means scraping
HTML. That is a different kind of dependency from an undocumented JSON endpoint:
no stable shape at all, and a change is a layout change rather than a schema
change.

So the grid's Play column has no release date and should say nothing rather
than approximate one. Written here rather than nowhere because the symmetric
shape is what a reader of this document will reach for next, and
`docs/CONTRIBUTING.md` §"A claim about both stores is checked against both" is
the rule that says to check it rather than assume it.

## The consumer's answer to the per-platform question

Asked and answered after this shipped, and recorded because §"It answers per
app, not per platform" proves what the *storefront* does and this is what the
consumer does about it.

**One universal purchase, one bundle id** — `design.codeux.howitwent` for both
platforms. The train passes one identifier and puts `--platform ios|macos`
beside it, which is an App Store Connect axis this endpoint does not have. So
the release date **gets its own group with a single column**, and the
per-platform App Store columns carry nothing. Someone who later wants to split
it has to delete a group rather than edit a cell.

That is the absence of `platform` doing the work it was left out to do: the
grid's shape carries *per app, not per platform* structurally, rather than as a
judgment call somebody re-makes.

## No `readAt`, and the staleness it would not have fixed

Apple's lookup is CDN-cached, so version 1.1.6 twenty minutes after 1.1.7 went
live is indistinguishable from 1.1.7 not being out yet. A timestamp saying when
*this* read happened was considered and is **not** carried.

**The half that had to be in the document already is.** `version` says which
version the date belongs to, which makes misattributing 1.1.6's date to 1.1.7
impossible rather than merely unlikely — see [StorefrontAppEntry.version]'s
doc comment. What is left is a *rendering* decision about how confidently to
show a cached answer, and that belongs to whoever draws the cell: the consumer
shows the read's own elapsed time beside it. A `readAt` here would be this
package restating something the caller already knows — it spawned the process.

## One app may have several store listings

Raised while this was in review, and recorded as a constraint on future change
rather than as work: one app can need **several store listings** — a beta
listing beside a production one, as separate console entries under separate
identifiers.

`storefront released` is already right for that, and the reason is worth
naming so it is not lost: **the identifier is an argument, and a caller can
loop.** Nothing here is keyed by *project*.

So the shape not to add later:

- **No inferred single bundle id that cannot be overridden.** The `--bundle-id`
  default reads one from the project as a convenience, and the flag wins — that
  stays the relationship. A default that a caller could not step around would
  make "the app" a property of the repository, which is the assumption this
  section exists to refuse.
- **No document-level cache keyed by project.** A cache keyed by identifier is
  fine in principle; one keyed by project would answer the second listing with
  the first's record, which is the failure this is written down to prevent.

## What this does not decide

**Whether the date is ever wrong, and what to do about it.**
<https://developer.apple.com/forums/thread/710663> reports
`currentVersionReleaseDate` disagreeing with what the console shows. Nothing
here has reproduced it, and nothing here compensates for it. The document says
what the storefront said; a consumer showing it beside an
`appstore.versions` state has both halves and can notice a disagreement, which
is more than either has alone.

**Whether a phased release changes the answer.** A phased release reaches
different users on different days, and what `currentVersionReleaseDate` means
under one is unmeasured — plausibly the day phase 1 started, plausibly
something else. The consumer leaves `--phased` off, so this has not come up.
Recorded so nobody reads the field as "when everybody got it".
