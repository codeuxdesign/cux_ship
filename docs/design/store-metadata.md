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

This dissolves an argument three of us were having. Two positions had proposed
freezing release notes into the build, and one had proposed reading them from
committed state at upload; the correct number of freeze points is **three**, and
which applies is a property of the channel rather than a policy anyone chooses.
Freeze-at-build is not a position for snap and deb — it is physics.

**The second load-bearing distinction is source format versus wire format.**
Humans author version-keyed, per-store-family sources. Renderers emit whatever
each channel eats: `changelogs/<versionCode>.txt` for F-Droid, a `whatsNew`
string for Play, a `<release>` block for AppStream. Arguing about *the* key for
*the* metadata is what produced the disagreement; there are two representations
with different owners.

## Decisions

### D1 — Skip unchanged images on the Play push. **Recommend: yes.**

Today every upload calls `images.deleteall` per image type per locale and
re-uploads every file, with no comparison. Six deletes and six uploads here at
one locale; **138 and 138 at AuthPass's 23**. Play's `Image` resource carries
`sha1`/`sha256` and `cux_ship` already calls `images.list` and discards the
result.

The open question — whether Play's returned digest matches the bytes sent or a
re-encoding — **is already answered**: fastlane's `supply` ships
`sync_image_upload` doing exactly this comparison in production. If it ever does
not match, the check degrades to today's behavior and is no worse.

This needs no format, no model and no decision about any other store.

### D2 — Read release notes from committed state, refusing a dirty file. **Recommend: yes.**

`upload.sh` and `promote.sh` both pass the **working-tree** `CHANGELOG.md`,
under a header stating *"the working tree is not consulted at all"*. Uncommitted,
unreviewed text can ship; a `dist/` built on another machine publishes this
machine's notes against that artifact. `promote.sh` is the worse of the two,
being the path that reaches real users.

Read from `HEAD`'s committed copy, refuse when `git status -- CHANGELOG.md` is
non-empty. Late-written notes stay possible — which is the workflow — and
unreviewed notes stop being possible.

### D3 — Record the notes' source commit in the `uploaded/` annotation. **Recommend: yes.**

Two facts about one release, both auditable: `builtSha` — what was built — and
`notesSha` — where its description came from. AuthPass proposed this; it is a
record without a mechanism until D2 exists, and trivial once it does.

Scope: the second commit names where the **notes** came from. Listing changes
are ordinary git history and need no place in a build's provenance record. A
listing-only push gets a log line, not a tag.

### D4 — Teach the Play loader the fastlane layout. **Recommend: yes.**

`metadata/android/<locale>/…` is a de-facto interchange format: F-Droid and
IzzyOnDroid scan it, the Amazon and Huawei fastlane plugins mirror it, Crowdin
configs target it, and AuthPass already uses it as its source. One loader with
two dialects is cheaper than migrating AuthPass or rendering one tree into the
other on every push.

This repository keeps `store/play/`, which nothing external reads and which
carries things the fastlane layout has no place for — `details/`,
`data-safety.csv`, and a stricter present-means-owned validation.

### D5 — Publish the App Store listing at promote. **Recommend: yes, before the next App Store submission.**

`--no-metadata` on upload is correct: publishing a listing reads the `appInfos`
record that App Store Connect locks during review, which would make giving
testers a build mid-review impossible.

But "published deliberately, by hand" means in practice *never*, and the App
Store listing drifts by default — the exact failure the Play side is engineered
against. The consumption point already exists: `appstore promote` creates the
new `appStoreVersion`, which is when version-scoped fields can be written
without meeting the review lock.

**This closes the one real gap in "one workflow for both stores."** After it the
rule is symmetric and sayable in a line: *the release action reasserts the
listing; the upload action never touches it.*

### D6 — Build no store adapters, and no cross-store canonical format. **Recommend: yes — that is, build nothing.**

Not now, and not until a shipping decision names a store. Every adapter is a
standing liability exercised twice a year against a schema somebody else
changes. Fastlane, with hundreds of contributors, still ships its App Store
screenshot sync marked beta.

When a store does arrive, the honest bridge is a **rendered submission pack** —
per-field text pre-validated against that store's limits, images pre-validated
against its dimensions, and a paste order — not an API client. Manual paste from
a validated pack is most of the value at a fraction of the cost, and for a store
that never justifies an adapter it is the permanent answer rather than a stopgap.

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

**A screenshot capture pipeline.** Screenshots are the real scaling cost —
per-locale times per-device-class, and they rot: a listing screenshot here was
publishing a fixed grammar bug within two days. But capture is the expensive
half and it is a *build* problem, not a store problem. Keep the
debug-build-plus-seed recipe per repository.

## If nothing above is done

The strongest case against all of it, stated at full strength because most of it
survives: two of the three repositories have one locale and two stores, and the
cross-store problem exists in production only as AuthPass's F-Droid-plus-Crowdin
arrangement, which works today without `cux_ship`. The only *measured* pain is
the image re-upload and the working-tree changelog read — D1 and D2, a dedupe
and a dozen lines.

That argument wins against everything in the future tense and loses to D1–D3,
which fix defects rather than hypotheticals.

## Later, at a named need

- `listing render --target fdroid` — resolve the version's notes per locale into
  `changelogs/<versionCode>.txt`, before the `fdroid-v` tag is pushed. Needed
  when AuthPass's uploads move onto this provenance path.
- `listing render --target snap|deb|appstream` — the baked-format category,
  invoked from inside the build because the channel freezes there.
- A locale-code table. Crowdin's `%locale%`, Play's BCP-47, Apple's codes,
  Samsung's `languagecode` and Huawei's do not agree, and every adapter would
  otherwise rediscover that.

## One cadence rule, everywhere it is possible

**Reassert the committed listing on every release.** Not because it changed —
because a source of truth nothing routinely pushes drifts from the console with
nobody noticing, and the store replaces rather than merges.

snapcraft supplies the cautionary tale from the other direction: one manual
web-UI edit permanently disables its metadata-push-on-release, silently. That is
the failure this cadence exists to prevent, observed in a system that chose the
other default.
