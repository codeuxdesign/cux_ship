# Release notes in every store locale

Status: **built**, 29 September 2026 — `CHANGELOG.<locale>.md` beside the
changelog, `--locale` without a default, and `verify` naming where each
declared locale's notes come from.

**The defect.** On 29 September 2026 a consumer's App Store submission failed
with `409 for POST /v1/reviewSubmissionItems — appStoreVersions … is not in
valid state`. Its listing had gained a German localization — `.cux-ship.yaml`
declared `appstore: locales: [en-US, de-DE]` and the tree carried
`listings/de-DE/` — and both uploaders wrote release notes for one locale: the
App Store's `--locale`, defaulting to `en-US`, and Play's listing default
language. Apple requires "What's New" on every localization of a version
update, so the German localization had none and the version could not be
submitted. It was released after a second, listing-only run with `--locale
de-DE` wrote the English notes there by hand.

`cux_ship verify` was green throughout. Nothing asked whether every declared
locale would receive notes, and nothing in the uploaders wrote to more than
one.

## What the stores require, per locale

**App Store Connect.** "What's New in This Version" is localizable and
*required for version updates* (App Store Connect Help → Reference → Required,
localizable, and editable properties). A localization that is *absent* is
fine — Apple shows the next most relevant one, then the primary language — but
one that is *present and incomplete* blocks the submission. So the trap is
precisely a listing that gains a language. TestFlight's "What to Test" is one
`betaBuildLocalizations` record per build per locale, and Apple does not gate
a beta on every locale having one: writing it everywhere is consistency, not a
requirement.

**Google Play.** A track release carries `releaseNotes: [LocalizedText]`, up to
500 characters per language, and refuses a list that repeats a language
(*"Release notes are badly constructed or have duplicates"*). What Play shows a
reader whose language has no element is undocumented; every release to date
with one `en-US` element showed German readers the English.

## The rule: a filename, no configuration

> **`CHANGELOG.md` is the notes for every locale that has no file of its own.
> `CHANGELOG.<locale>.md` beside it is that locale's notes.** Which locales
> exist is what `.cux-ship.yaml` already declares.

The locale is spelled exactly as the store block declares it — `de-DE`,
`zh-Hans`, `pt-BR`. `docs/CHANGELOG.md` named with `--changelog` gets
`docs/CHANGELOG.de-DE.md`. A locale file is a complete changelog in its own
right: the same headings, the same bullets, the same `[android]` / `[ios,
macos]` prefixes, the same walk to an older section when a version is empty —
and the walk **never crosses files**. An empty `## 1.1.9` in the German file
means *nothing changed for German readers*, exactly as it does in English, and
falls back to German 1.1.8.

Both cases a repository actually has cost nothing:

- **Everything in one language.** No locale files. Every declared locale gets
  `CHANGELOG.md`'s section, and every run and every `verify` says so per
  locale. This is where the consumer that met the 409 is starting, by decision:
  it publishes its English notes in German until a release has notes worth a
  copy pass.
- **Translated notes.** Create `CHANGELOG.de-DE.md`. From then on a release
  whose German file lacks the version's heading is refused before anything is
  written, exactly as the English one is.

fastlane's `deliver` has the same shape — a `metadata/default/` folder whose
files fill every language without its own — and Xcode Cloud puts the locale in
the filename (`TestFlight/WhatToTest.<locale>.txt`), which is where it is here.

## Where each store writes, per locale

For a release of version V on platform P, `--release-notes <file>` is literal
text and goes to every locale; otherwise each locale L reads `CHANGELOG.L.md`
when it exists and the changelog when it does not, filtered to P, measured
against P's cap on its own, and — on Apple — stripped of emoji on its own.
`requireCommittedNotes` is handed every file that was read.

The **locale set** differs by surface, because the surfaces differ:

| Surface | Locales |
|---|---|
| App Store "What's New" | every localization Apple holds for the version |
| TestFlight "What to Test" | `appstore.locales`; `en-US` when none is declared |
| Play `releaseNotes` | the listing's default language, plus `play.locales` |

**The App Store's is Apple's own record**, because that record is what the
submission is checked against. It is read after the listing publish — which is
what creates a declared locale's localization — and so `promote` now writes the
notes *after* its listing publish rather than before it. Written before it, a
listing that gained de-DE in the same promote got its German record after the
notes went out, which is the 409 again. A declared locale Apple does not hold
is reported and not created: a record carrying "What's New" and nothing else is
the one the existing `declaredLocales` guard exists to prevent. When Apple
holds no localization at all, the write goes to the declared locales, which is
the single write of every earlier release, generalised.

**`--locale` has no default now**, and unset means the sets above. Passed, it
keeps its old meaning everywhere — one locale, that one — so a script that names
it gets what it always got. With nothing declared and no locale files, every
path writes exactly what it wrote before.

**The listing-only publish is all or nothing.** It is the one path where a
missing section is not an error — the changelog there is inferred, and an
inferred flag must not manufacture a requirement. But when a *locale* file
lacks the section, no locale gets notes and the run says which file: English
in every locale but the forgotten German one would be a silent substitution,
and notes on some localizations and not others is the state Apple refuses.

## Decisions taken with the owner

Asked before building, 29 September 2026.

- **Translate at all?** Not yet. English everywhere is the default the
  consumer wants; per-language files are for later, and the design does not
  have to know in advance.
- **Can `verify` require a locale file?** No flag and no key. Creating the file
  is the requirement; from then on a missing section in it is a problem, and
  `verify` names every locale that is on the default on every run.
- **`--release-notes` with several locales?** The literal text goes to every
  one, and the flag's help says so. The flag is for a repository that keeps one
  file, which has made no per-locale decision to honour.
- **A localization Apple holds that nothing declares?** Written with the
  default notes, with a line naming it. A localization with no "What's New"
  blocks the submission; one carrying the default text is merely untranslated.
  Keeping the release submittable wins over "present means owned" here, and the
  line is what keeps the choice visible.
- **The platform-name check** ships in the same pull request, as its own
  commit.

## What `verify` reports

`checkLocaleChangelogs` in cux_ship_verify, run by `verify` over the declared
locales (`appstore.locales ∪ play.locales`, or `en-US` when neither declares
any):

1. **A locale file without the shipping version's heading** — a problem,
   `CHANGELOG.de-DE.md § 1.1.9`, with *"or delete the file to publish
   CHANGELOG.md's notes to de-DE"*. The "forgot to translate this release" case.
2. **A locale file over a cap**, named as itself. German runs longer than
   English, so it meets Play's 500 first — on the push that adds it.
3. **A locale file for a locale nothing declares** — a problem. The likeliest
   cause is a misspelt filename, `CHANGELOG.de.md` beside `de-DE`, which would
   otherwise be a translation silently ignored.
4. **A dangling symlink** where a locale file would be — a problem, by name.
   `File.existsSync` reports it absent, and absent now means "publish the
   default".
5. **A declared locale with no file** — not a problem. One `checked notes` line
   per locale, `de-DE ← CHANGELOG.md (no CHANGELOG.de-DE.md)`, the same line an
   upload prints.

## What was turned down

**A symlink, `CHANGELOG.de-DE.md -> CHANGELOG.md`.** It says "German gets the
English notes" as a filesystem object, which is what the absence of the file
already says — one file per locale whose whole content is "same as the
default", configuration written where nothing validates it. git checks a
symlink out on Windows as a one-line text file, and there is nowhere to write a
comment. A link that resolves is harmless — the same file read twice — so it is
not refused; a link to nothing is, which is why `DanglingLink` is its own case.

**A `.cux-ship.yaml` key** — `notes: {de-DE: path}`, or a fallback switch. It
would only restate the convention, or choose between fallback and refusal, and
the file's presence already makes that choice per locale with a diff a reviewer
can see. The locale *set* is the one thing that needs declaring, and it is
declared already; a key would be a second place for it to be wrong.
`config.dart` is unchanged. If a repository one day needs a locale file
somewhere the convention cannot reach, that is the moment for a key, with that
repository as the reason.

**A translation step at upload time.** Text produced during the run has been
read by nobody, which is the hole `notes_source.dart` closed with no override.
Translation belongs before the commit — a consumer's script drafting the new
section of `CHANGELOG.de-DE.md`, read by a human, checked by `verify`,
committed. cux_ship gains nothing by knowing about it.

**Per-locale sections inside one `CHANGELOG.md`.** Mixes languages in a file a
German reader would scroll through, gives a translation tool nothing per-file
to work on, and `### de-DE` would need a new grammar, since any `##` heading
already ends a section.

## The platform-name check

A related guard over the same parser, found the same day: an unscoped
*"Drag files in on Android"* reached two uploaded builds before a reader caught
it. App Review Guideline 2.3.10 rejects metadata naming other mobile platforms,
and an entry without a prefix reaches every store — a rule documented, until
this change, only in a private regex's comment.

`checkPlatformNames`, run by `checkChangelog` over every file, reports an entry
that reaches `ios` or `macos` *after filtering* and names Android, Google Play
or the Play Store, word-bounded and in any case. So an `[android]` entry is
fine, a `[macos]` one is reported against macOS alone, and *androids* or a bare
*Play* are not hits. Every section is checked, not only the newest, because the
fallback walk can publish an older one. The reverse — an entry reaching Android
that names iPhone — is allowed by Play, and this tool has no channel for a
style warning, so it is not checked.

## Open: the Beta App Description is still one locale

Status: **open**.

`--beta-description` and `listings/<locale>/beta_description.txt` still write
one locale — `--locale`, or `en-US` without it. Written per declared locale, a
`--beta-description` file would overwrite a German description somebody
maintains in App Store Connect with the English one, which is a "present means
owned" violation the release-notes design does not have to make. Apple's test
information page asks for the description per language; whether TestFlight
refuses an external group over a language that has none is unmeasured. Taken up
when a consumer's external beta meets it.

## Open: what the stores show a locale with no notes

Status: **open**.

Three things this design depends on less than it would like to, and none is
documented: what TestFlight shows a tester whose locale has no "What to Test";
what Play shows a reader whose language has no `releaseNotes` element; and
whether Play refuses an element for a *supported* language the listing lacks —
`play/cli.dart` asserts it, and the only documented refusal is for a language
Play does not support at all. The design never sends one either way:
`checkPlayTree` requires every declared locale of an uploaded listing.
`play promote` loads no tree, so there the declaration is trusted.
