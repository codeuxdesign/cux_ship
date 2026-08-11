# Changelog

## 1.7.2

No changes. Released alongside `cux_ship` 1.7.2, which the two packages move in
step with.

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
