# Store metadata and changelogs: what to build

Status: **decisions pending**. The analysis is settled; three decisions below
need a yes or a no, and two questions raised at 23 locales are undecided.
Nothing here is implemented, with one amendment: the TestFlight-group section
is built as of 25 August 2026 — see the note that closes it, including where
the implementation diverged from the sketch.

The research behind it examined Play, App Store Connect, Microsoft Partner
Center, Amazon, Samsung, Huawei, snapcraft, F-Droid, debian and fosshub, plus
the prior art — fastlane `deliver`/`supply`, Triple-T gradle-play-publisher,
StoreBroker, AppStream, Crowdin pipelines.

## The finding that reorganizes the question

**Nine stores are not nine variants of one problem. They are three transport
patterns, and the pattern decides when metadata freezes.**

| Pattern | Stores | Freezes | Because |
|---|---|---|---|
| **API-push** | Play, App Store, Microsoft, Amazon, Samsung, Huawei | at push, from committed state | the listing lives server-side |
| **Pull-from-repo** | F-Droid, IzzyOnDroid | at the release tag's commit | fdroidserver scans the checkout of the tagged commit |
| **Baked into the artifact** | snap, deb, AppStream, msix | **at build, by construction** | the metadata is *inside* the artifact |
| *(no listing model)* | packagecloud, fosshub | — | artifact hosts |

This dissolves an argument three of us were having. One position had proposed
freezing release notes into the build, and two had proposed reading them from
committed state at upload; the correct number of freeze points is **three**, and
which applies is a property of the channel rather than a policy anyone chooses.
Freeze-at-build is not a position for snap and deb — it is physics.

**The second load-bearing distinction is source format versus wire format.**
Humans author version-keyed, per-store-family sources. Renderers emit whatever
each channel eats: `changelogs/<versionCode>.txt` for F-Droid, a `whatsNew`
string for App Store Connect, a `releaseNotes` text on the track release for
Play, a `<release>` block for AppStream. Arguing about *the* key for
*the* metadata is what produced the disagreement; there are two representations
with different owners.

## What is shared, and what can never be

One workflow across nine surfaces is achievable only as one **authoring and
verification** workflow. Transport degrades into per-store adapters,
irreducibly — the auth models alone guarantee it (a Google service account, an
Apple JWT, Entra ID, Login with Amazon, a Samsung-signed JWT, an AGC token)
before the resource models differ at all.

The genuinely shared core: the field/locale/limits model and its offline
validation, changelog resolution and platform filtering, rendering to wire
formats, the ownership rule — present means owned, absent means left alone,
deletion is explicit — the provenance record, and the locale-code table below.
Transport is not in it, and neither is anything under *rejected*.

And the count deflates on inspection. Of the surfaces examined: two are live
today; one (F-Droid) is satisfied by AuthPass's existing tree plus one rendered
file; snap is half a surface — `snapcraft upload-metadata` pushes exactly
summary, description and icon, and screenshots have no API or CLI at all; two
(packagecloud, fosshub) have no listing model; the remaining four — Microsoft,
Amazon, Samsung, Huawei — wait on a shipping decision. All four do have real
submission APIs that can edit listing text and screenshots programmatically —
none can create an app, and Microsoft's `msstore` CLI currently updates free
products only — so decision 3 below is a choice, not a limitation.

## Three decisions

An earlier shape of this document had six. One was deleted as a mistake that
had worn three costumes — coupling the *release record* to the notes text,
which also surfaced as an embedded-text payload and an over-specified read path
before anyone pressed on it — because the text already has two authoritative
homes: **the store is the record of what it showed, git is the record of what
we wrote, and the tag only joins the artifact to its commit.** The other two
merged into a neighbor or moved down to the named needs. What follows is what
survived being read by someone who had not watched it accrete.

### 1. Fix the two measured defects

**Skip unchanged images on the Play push.** Every upload calls
`images.deleteall` per image type per locale and re-uploads every file, with no
comparison. Measured in **How It Went**: three image types and six files, so
three deletes and six uploads, at one locale. **Hold the Wheel** carries five
types and fourteen files. Multiply either by **AuthPass's 23 locales** and it is
the deciding number — the exact figure there is theirs to state, and an earlier
draft of this document invented one by applying How It Went's count to
AuthPass's locales, which is the mistake this paragraph now exists to avoid. Play's `Image` resource carries `sha1`/`sha256` and `cux_ship`
already calls `images.list` and discards the result. Whether Play's digest
matches the bytes sent is already answered: fastlane's `supply` ships
`sync_image_upload` doing this comparison in production. If it ever fails to
match, the check degrades to today's behavior and is no worse.

**Refuse to publish release notes from a dirty changelog.** In **How It Went**,
`upload.sh` and `promote.sh` both read the working tree under a header stating
*"the working tree is not consulted at all"*; in **Hold the Wheel**, both do the
same without the false header. Either way unreviewed text can ship, and
`promote.sh` is the path that reaches real users.

**Scope it to the files the notes were resolved from**, with `CHANGELOG.md` as
the current instance rather than the definition. AuthPass's notes never come
from a `CHANGELOG.md` at all — they resolve from per-locale
`changelogs/<versionCode>.txt` and a cross-store CSV, 23 locales of them. Stating
the guard in terms of one filename would need rewriting the day the fastlane
dialect arrives.

The guard is the whole fix, and reading from `git show HEAD:CHANGELOG.md`
instead would be over-specification: the two are byte-identical whenever the
file is clean, and the refusal makes the dirty case unreachable. Scope it to
those source files and nothing wider, give it no override — committing costs
seconds and an override reopens the hole — and put it inside `cux_ship` beside where the changelog is
already loaded and length-checked. One implementation for three repositories,
and `upload.sh`'s header becomes *true* rather than deleted.

What it deliberately does not fix: a `dist/` built on one machine and published
from another still takes the publishing clone's committed notes. That is the
requirement — committed means reviewed — and chasing the cross-machine case is
where the deleted decisions came from.

### 2. Only a promotion to the public audience touches the listing

**A listing write on Play is a publication.** `edits.listings.update` and
`edits.images.upload` take `(packageName, editId, locale)` and **no track**:
there is one listing per app per locale, shared by production and every test
track, and committing the edit makes it public. Only `releaseNotes` is
per-track.

**So reasserting it on every upload has exactly two states**, and neither is
good. Either the committed listing already equals what production should say —
in which case the write does nothing — or it differs, in which case an
internal-track upload publishes copy describing a version nobody can download.
The cadence is safe precisely when it is useless.

Worse, the convention that would make it safe — *the listing always describes
production, never stage it* — forbids committing listing copy alongside the
feature that motivates it, and reinstates the keep-two-things-in-step-by-
remembering this tooling exists to remove. It is not an edge case either: it is
the first release cycle that overlaps another one. 1.1 in beta, 1.2 uploaded to
internal, and the public page now describes 1.2.

**The rule, and it is one bit:**

> **Only a promotion to the public audience writes the listing. Every other
> command validates and reports; none of them writes it.**

"Will this touch the public listing?" — "Am I promoting to production?"

**The qualifier is load-bearing and an earlier draft left it out.** `play
promote --track beta` is a promote and reaches open testing, not production; a
rule saying *any* promote publishes would republish the listing there and
reproduce the defect one track over. On Play the public audience is
`production`; on the App Store it is the review submission. A promotion into
closed or open testing observes and reports exactly as an upload does.

One bootstrap case sits outside the rule and is named here rather than left to
be discovered: before the first production release — an app living in open
testing only — no qualifying promotion exists, yet Play requires a complete
listing before an open track can publish at all. The first listing goes up by
the explicit act, `--listing-only`, not by a cadence.

**Uploads observe rather than write, which is stronger than the cadence it
replaces.** Every upload runs a read-only diff of the committed tree against
what the store holds — `listings.get`, and `images.list` with the digest
comparison decision 1 already buys — and says so in its plan:

```
listing: repo differs from console in fullDescription (en-US) — publishes at next promote
listing: console holds an edit not in the repository
```

Drift prevention needed frequent **observation**; the old design gave it
frequent **writing**, and the whole defect lives in that gap. Observation costs
nothing and publishes nothing. It is also strictly better at the job: the old
cadence silently overwrote a console edit, where this names it and leaves
someone to decide which side is right.

**The stores agree more than this document assumed.** App Store Connect
*mandates* promote-time — the listing is `appStoreVersionLocalizations` under an
`appStoreVersion` that does not exist until then. Play merely *permitted*
earlier, and permission was never obligation. TestFlight has no listing at all;
`appstore upload` writes `betaBuildLocalizations` — `whatsNew`, per build — which
is release notes, not a listing.

**Adding a build to a TestFlight group is a promotion, and should be spelled as
one.** Today it is `appstore upload --beta-group <name>`, which conflates *ship
these bytes* with *give them to this audience*. But it is the same operation
Play calls promotion — an existing build, no upload, a wider audience — and the
machinery is already there: `appstore promote` resolves a build by
`--build-number` or takes the newest Apple holds, and `addToBetaGroup` needs
only the app, the build and the group.

Spelling it as a promotion buys three things. The stores stop needing separate
mental models — *promote widens the audience of a build that already exists*,
everywhere. The shared model is that verb and nothing below it: Apple's groups
are membership a build can hold several of at once, where Play's tracks carry a
release that supersedes its predecessor, and promote must not paper over that
difference the day someone asks it to "replace" a build in a group. A build can be given to an external group days after upload without
re-uploading, which is not expressible today. And the listing rule falls out of
it rather than being asserted: promotions to the public audience publish,
promotions to a group do not, on both stores and for the same reason.

`--beta-group` at upload stays, as the convenience it is. What changes is that
it stops being the *only* way to reach a group.

Not modelled when this was written, and named as the gap it was: external
TestFlight groups require **Beta App Review**, which is separate from App
Store review and appeared nowhere in this tooling.

**Built, 25 August 2026, diverging from the sketch above in one place worth
recording.** This section proposed carrying groups on `promote`, whose build
resolution defaults to the newest Apple holds. What shipped is a sibling verb
instead — `appstore beta-release --build-number N --beta-group <name>` — with
`--build-number` **required**, on the `wait` precedent: a release to testers
is a release of a *specific* build, and "newest" would release somebody
else's upload. That default is right for promote's own job, where the newest
processed build is the one being shipped, and wrong for reaching back to a
build uploaded days ago — which is exactly the case this section called "not
expressible today". It is expressible now; that sentence is retired, just not
spelled `promote`.

The rest landed as sketched, and further. `promote --beta-group` and `upload
--beta-group` both carry the full external flow — one implementation behind
all three spellings — and Beta App Review is modelled rather than named as a
gap: the flow forks on the group's kind, internal staying assignment-alone
and byte-identical to what it always was, external reasserting the Beta App
Description (`store/appstore/listings/<locale>/beta_description.txt`,
present-means-owned like every listing field, absent leaving the console's
text alone), submitting for beta review idempotently, and reading back
`externalBuildState`. And "promotions to a group do not publish" stopped
being a sentence this document asserted about code that disagreed: promote
had been resolving the inferred listing tree and publishing it before the
group block ran, then printing "the listing is untouched" — the inference is
now suppressed under `--beta-group`, which is what makes the rule above true
in code rather than only here.

**One thing stays on upload, deliberately.** `--listing-only` remains the
explicit escape for *fix the live page now* — an act rather than a cadence. On
the App Store that act is bounded by the store rather than the tooling: outside
a version in preparation, only promotional text and app-info fields can change
without shipping a new version, which is why the `store/appstore/` README
routes seasonal copy through `promotional_text`.

**The data-safety declaration used to stay too, and no longer does.** The
reason it stayed was sound and is unchanged — marketing copy ahead of
production is wrong, while a data-safety declaration ahead of production is the
*compliant* direction. What that argument settles is *ordering*, and it was
read as settling *coupling*: because sending early is safe, sending it with
every upload looked free. It is not. Play files every send as a change awaiting
review whether or not an answer moved, and exposes no read of what it holds, so
nothing can send only on a difference. An app uploading weekly collected one
pending review per upload against a declaration nobody had touched.

So it is `cux_ship play data-safety`, its own verb. An upload still *checks*
the declaration, which is the part that belongs on the frequent command; it
sends nothing. Being early is still the compliant direction — the command is
just run on purpose rather than as a side effect, which is what the rest of
this document says about acts versus cadences.

**The residual case, which is the same defect one hop later.** Promoting 1.1
while trunk's listing already describes 1.2 republishes the skew at promote
time. The listing is trunk-owned, like the changelog, so this is the ordinary
state-against-a-shipped-version situation and takes the ordinary escape:
promote from the release branch or tag. Two things make it survivable — promote
is already interactive, and its confirmation should show the listing state it is
about to publish, so skew is visible before the yes; and release notes never
skew, being version-keyed.

Rejected: version-keying the listing source (`store/play/1.2/…`). It grafts a
version dimension onto app-state to solve a rare case the release-branch
mechanism already covers, at the cost of a merge burden on every release
forever.

### 3. Build nothing else until a need is named

Not now, and not until a shipping decision names a store. Every adapter is a
standing liability exercised twice a year against a schema somebody else
changes; fastlane, with hundreds of contributors, still ships its App Store
screenshot sync marked beta.

When a need does arrive, the honest bridge for a new store is a **rendered
submission pack** — per-field text pre-validated against that store's limits,
images against its dimensions, and a paste order — not an API client. For a
store that never justifies an adapter, that is the permanent answer rather than
a stopgap.

The named needs, each conditional on an event rather than standing:

- **Teach the Play loader the fastlane dialect** — when AuthPass migrates onto
  this tooling. `metadata/android/<locale>/…` is a de-facto interchange format:
  F-Droid and IzzyOnDroid scan it, the Amazon and Huawei fastlane plugins mirror
  it, Crowdin configs target it. This repository keeps `store/play/` either way;
  nothing external reads it and it carries `details/`, `data-safety.csv` and a
  stricter present-means-owned validation that the fastlane layout has no place
  for.
- **`listing render --target fdroid`** — when AuthPass's F-Droid path moves
  over: resolve the version's notes per locale into
  `changelogs/<versionCode>.txt`, committed before the `fdroid-v` tag is pushed.
- **`listing render --target snap|deb|appstream`** — the baked-format category,
  invoked from inside the build, because the channel freezes there.
- **A locale-code table** — Crowdin's `%locale%`, Play's BCP-47, Apple's codes,
  Samsung's `languagecode` and Huawei's do not agree, and every adapter would
  otherwise rediscover it. The concrete breakers, from AuthPass's tree:
  `zh-CN`/`zh-TW` where Apple wants `zh-Hans`/`zh-Hant`, and `he-IL` where
  Play's API has historically wanted the legacy `iw`. `pt-BR`/`pt-PT` work
  everywhere, but by the luck of BCP-47 agreeing rather than by anything
  designed.

## Two questions that only exist at many locales

Neither is visible in a repository with one locale, and both are the first thing
that happens at 23. Raised by AuthPass reading this from that side; **both are
undecided.**

**Partial translations are the steady state, not an edge case.** With Crowdin,
a locale routinely has `title.txt` and no `short_description.txt`, or a
half-translated update. Present-means-owned plus a partial locale means pushing
gaps over a listing that was previously complete. The shared validation model
needs a per-locale completeness rule — push a locale only when complete and
skip-and-report otherwise, or something else, but *decided* rather than
whatever the loader happens to do.

**The ownership rule needs its grain stated.** *Present means owned, absent
means left alone* — per store, per locale, or per field per locale? At 23
locales there will eventually be console-managed locales beside repo-managed
ones: a volunteer edits Samsung's Korean listing directly. Per-field-per-locale
is probably the intent; one sentence would make it so, and its absence is the
kind of thing that gets decided by accident on the first push that meets it.

## A test for anything proposed later

**Every record should name the question it answers, and who asked it.**

The image dedupe answers "why does every upload re-send every image" — measured
here, and multiplied by 23 locales at AuthPass. The dirty guard answers "what
stops unreviewed text from reaching a store" — today nothing does, an
acknowledged defect in two repositories. A deleted decision — recording which commit the notes came from —
answered "which commit did this text come from", and when finally pressed nobody
had ever asked it and `git log -- CHANGELOG.md` could already answer it.

That is the difference between the parts of this design that survived a first
reading and the parts that did not.

## What is explicitly rejected

**A canonical cross-store description, rendered per store.** The
30-, 80- and 4000-character fields are different *genres*, not different
lengths, and auto-adaptation writes bad copy. Per-store divergence — the macOS
description that says "drag onto the window" where iOS says "share sheet" — is
an editorial act and belongs in separate files. AuthPass's cross-store CSV earns
its keep only because of 23 Crowdin locales; a single-locale repository gets a
generation step and nothing else.

**Age ratings and data safety in a shared model.** Programmatic almost nowhere:
Play's data-safety form and the IARC questionnaire have no API, Apple's is
Apple-specific JSON, OARS exists only in the AppStream world. These stay
per-store files, and the "what no API can set" tables in the store READMEs
remain the right artifact.

**Recording the notes' source commit in the `uploaded/` annotation.** Proposed,
then deleted, and the reasoning is worth keeping. It is redundant in every case
where it resolves — the tag's own tagger date plus `CHANGELOG.md` reconstructs
the text — and useless in every case where it would have mattered, because a
notes commit that reached nowhere is exactly the one whose sha dangles, and a
dangling sha in annotation text recovers nothing. It also cost more than it
weighed: it produced a confusion about whether two tags existed and a
false-alarm about garbage collection, both questions *about the field* rather
than about anything it protected.

**Embedding the published notes text in that annotation.** The repair for the
dangling sha, and worse. The resolved text already differs per store — Apple
strips emoji, Play does not — and would differ per locale, 23 of them at
AuthPass. Decisively: the `uploaded/` tag is written by the **first store that
succeeds**, so at write time the other stores' text does not exist yet, and
embedding one store's notes would silently imply it was all of them. "The
published text" is not one thing to record.

**Play store listing experiments — not because we chose to skip them.** There
is no API. Checked in the generated `androidpublisher` v3 surface rather than
inferred: **zero occurrences of "experiment"**, and the edit resources are apks,
bundles, countryavailability, deobfuscationfiles, details, expansionfiles,
images, listings, testers and tracks. Console only, and a long-standing request
rather than an oversight — the Play developer community carries a thread titled
*"Where is the API for store listing A/B tests?"*.

**The interaction is what matters, and it is the shape this document already
distrusts.** A running experiment is console-owned state the repository cannot
see, exactly like Play's managed-publishing toggle and snapcraft's metadata
switch. What `promote` publishing the committed listing does to a live
experiment is unknown and unqueryable, because there is nothing to ask.

That is an argument for the read-only diff rather than against anything: an
experiment *is* drift — the console holding something the repository does not —
so `listing: console holds an edit not in the repository` is the line that
surfaces one. The failure to avoid is somebody running an experiment for two
weeks, promoting a release, and never learning which of the two ended it.

**A screenshot capture pipeline.** Screenshots are the real scaling cost —
per-locale times per-device-class, and they rot: a listing screenshot here was
publishing a fixed grammar bug within two days. But capture is the expensive
half, and it is an authoring problem, not an upload problem. Keep the
debug-build-plus-seed recipe per repository.

## If nothing above is done

The strongest case against all of it, stated at full strength because most of it
survives: two of the three repositories have one locale and two stores, and the
cross-store problem exists in production only as AuthPass's F-Droid-plus-Crowdin
arrangement, which works today without `cux_ship`. The only *measured* pain is
the image re-upload and the working-tree changelog read — decision 1, a dedupe
and a guard.

That argument wins outright against everything in the future tense, which is why
decision 3 is to build none of it. It loses to decision 1, which fixes defects
rather than hypotheticals, and it defers rather than defeats decision 2 — bought
at the next App Store submission.

## Observe on every contact, write only when going public

**Drift prevention needs frequent observation, not frequent writing.** An
earlier shape of this document asked for the committed listing to be reasserted
on every release — not because it changed, but because a source of truth nothing
routinely pushes drifts from the console with nobody noticing, and the store
replaces rather than merges.

The instinct was right and the mechanism was wrong. Writing frequently is
publishing frequently, and on Play that means publishing whatever trunk happens
to say to a public page serving a version that may be two releases behind.
Reading frequently costs nothing, catches the same drift, and reports it instead
of silently resolving it in trunk's favor.

snapcraft still supplies the cautionary tale, and its lesson survives intact:
one manual web-UI edit silently disables its metadata-push-on-release, so the
publish path had a silent off-switch. Promote-time publishing has none — it is
automatic at promote and toggled by nothing.

Worth knowing and deliberately not used: Play's **managed publishing** console
toggle can hold listing changes for manual release. It changes the semantics of
every edit commit app-wide, it is console state the repository cannot see, and
internal-track releases bypass it regardless. A silent console toggle governing
publication is the snap failure wearing Play's colors, and this design needs
nothing from it.
