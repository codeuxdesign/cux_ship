# Store metadata and changelogs: what to build

Status: **decisions pending**. The analysis is settled; six items below need a
yes or a no. Nothing here is implemented.

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

An earlier shape of this document had six. Three of them were one mistake in
three costumes — coupling the *release record* to the notes text, when the text
already has two authoritative homes: **the store is the record of what it
showed, git is the record of what we wrote, and the tag only joins the artifact
to its commit.** What follows is what survived being read by someone who had not
watched it accrete.

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
that one file, give it no override — committing costs seconds and an override
reopens the hole — and put it inside `cux_ship` beside where the changelog is
already loaded and length-checked. One implementation for three repositories,
and `upload.sh`'s header becomes *true* rather than deleted.

What it deliberately does not fix: a `dist/` built on one machine and published
from another still takes the publishing clone's committed notes. That is the
requirement — committed means reviewed — and chasing the cross-machine case is
where the deleted decisions came from.

### 2. Close the one workflow gap: publish the App Store listing at promote

`--no-metadata` on upload is correct, because publishing a listing reads the
`appInfos` record that App Store Connect locks during review — which would make
giving testers a build mid-review impossible.

But "published deliberately, by hand" means in practice *never*, and the listing
drifts by default: the exact failure the Play side is engineered against. The
consumption point already exists — `appstore promote` creates the new
`appStoreVersion`, which is when version-scoped fields can be written without
meeting the lock.

After it the two-store workflow is one sentence: **the release action reasserts
the listing; the upload action never touches it.**

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

The image dedupe answers "why is every upload 138 image operations", measured at
AuthPass. The dirty guard answers "how did unreviewed text reach a store", which
happened here. A deleted decision — recording which commit the notes came from —
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

## One cadence rule, everywhere it is possible

**Reassert the committed listing on every release.** Not because it changed —
because a source of truth nothing routinely pushes drifts from the console with
nobody noticing, and the store replaces rather than merges.

snapcraft supplies the cautionary tale from the other direction: one manual
web-UI edit silently disables its metadata-push-on-release. That is
the failure this cadence exists to prevent, observed in a system that chose the
other default.
