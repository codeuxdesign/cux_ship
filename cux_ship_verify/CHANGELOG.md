# Changelog

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
