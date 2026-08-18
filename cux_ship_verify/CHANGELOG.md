# Changelog

## 1.9.0

**`checkPlayTree`** — the Play listing tree, offline. Text limits, the two
images Play requires at exact sizes, screenshot edge bounds and counts, and the
distinguished locale in `details/default_language.txt`, which the App Store has
no equivalent of. Play was covered for release-note length and nothing else.

The icon and feature graphic are checked unconditionally rather than being
things a caller asks for. They are Play's rules rather than a project's choice,
and a caller that could omit them would let a missing icon pass.

**`checkDataSafetyFile`** — the data safety CSV, **structure only**. Whether the
answers are true is a question about a particular app and this cannot answer it.
Nothing to specify either: the file is Play's own export and every row carries
its own answer requirement, so it is validated against itself rather than
against a copy of Play's rules that would rot.

Includes an RFC 4180 subset reader, because this package has no dependencies and
is not getting one for this. It refuses what it cannot parse — an unterminated
quote swallows every row after it, and a parser that shrugged would report a
truncated file as a complete one.

**`ReleaseProblem` moves to its own file** so a checker can sit beside the model
it checks without the import becoming a cycle. It is still exported from
`cux_ship_verify.dart`; no consumer changes.

### What is not covered, said plainly

**Localized graphics fall back to the default language**, so only the locale
others fall back to is required to carry the icon, the feature graphic and the
declared screenshot types. That behaviour is documented by Play and was
confirmed from the documentation independently of the author's reading — but
**every repository that reviewed this release publishes a single locale**, so no
real listing has ever exercised it. The synthetic trees in
`play_metadata_test.dart` are the whole of the evidence.

This is recorded rather than left implicit because "reviewed by three projects"
would otherwise read as covering it. It does not. The first consumer to publish
a second locale is the first real test of that rule.

### On numbers, and whose they are

Both kinds appear in `play_metadata.dart` and they are labelled: Play's limits
are cited as Play's, and this package's policy floors say so. A hardcoded value
nobody can change needs provenance *more* than a configured one — the first
project that legitimately disagrees will file it as a bug, and a number with no
source can be neither defended nor dropped.

Two checks were written, run against a real store-accepted listing, and deleted
before shipping, along with Play's published aspect-ratio rule. Each would have
failed a listing the store is serving. See cux_ship's 3.2.0 entry.

## 1.8.0

- **`review-notes.md` is read from the metadata tree**, as
  `AppStoreMetadata.reviewNotes`, and checked against Apple's 4000-character
  limit here rather than at upload — the same reason release-note length is
  checked here: Apple refuses an over-long note *after* an archive has been
  transferred.

  Two things it does that a plain read would not, both because the file is
  written for two audiences:

  - **Everything after `<!-- not for Apple -->` is cut.** A review-notes file
    accumulates checklists and reasoning belonging to whoever maintains it, and
    uploading it wholesale sends Apple an internal to-do list. A marker makes
    the split structural rather than something the next person has to remember,
    and an HTML comment is invisible wherever the file is rendered.
  - **The markdown is flattened to plain text**, because Apple's field is plain
    text and a reviewer seeing literal `##` and `**` reads carelessness in the
    one document whose job is to argue the opposite. Deliberately three
    substitutions rather than a renderer: heading hashes, bold markers, and the
    angle brackets that stop a bare URL being auto-linked.

  A file that is entirely below the marker is an error rather than an empty
  note, because that is a mistake in the file rather than a decision.

## 1.7.1

No changes. Released alongside `cux_ship` 1.7.1, which the two packages move in
step with.

## 1.7.0

No changes. Released alongside `cux_ship` 1.7.0, which the two packages move in
step with.

## 1.6.0

First release on pub.dev, and the first version of this package that is worth
depending on directly. Earlier versions were consumed as git refs and only
reachable through `package:cux_ship/verify.dart`, which meant a test suite
pulled the whole release CLI — googleapis included — to check the length of a
release note.

- **No dependencies at all.** The `CHANGELOG.md` parser (previously
  `cux_ship_notes`) and the App Store metadata tree loader (previously
  `cux_ship_appstore/metadata.dart`) moved here. Both are pure `dart:io` and
  `dart:convert`, both are the model of a store input rather than a client for
  one, and having them here is what lets the CLI depend on this package instead
  of the other way round.
- New public libraries: `package:cux_ship_verify/release_notes.dart` and
  `package:cux_ship_verify/metadata.dart`. The checks stay at
  `package:cux_ship_verify/cux_ship_verify.dart`.
