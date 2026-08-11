# Changelog

## 1.6.0

First release on pub.dev. Versions before this one were consumed as git refs;
they are in the git history and in this repository's tags.

- **Two packages instead of five.** The App Store and Play clients moved into
  `lib/src/appstore/` and `lib/src/play/` here, and the changelog parser and App
  Store metadata model moved into `cux_ship_verify`, which now has no
  dependencies at all. The split is about what a consumer's lockfile gets: a
  release machine wants googleapis and an image codec, a test suite does not.
- `lib/verify.dart` still re-exports `cux_ship_verify`, so nothing breaks — but
  a test suite should now depend on `cux_ship_verify` directly rather than
  reaching the checks through this package.
- Resolved as a pub workspace, so the repository has one lockfile and each
  package still declares ordinary hosted constraints.

## 1.5.1

- Read the headings a real secrets file groups its credentials under. `secrets
  exec` walked only top-level keys, so a file grouping values under `android:`
  and `apple:` — which is how they are actually written — was refused with none
  of its credentials found.

## 1.5.0

**Broken; use 1.5.1.** Its secrets parser refuses any grouped secrets file.

- `--app-dir` and `.cux-ship.yaml`, so a repository whose Flutter app is a
  subdirectory can use `release finish` at all. The repository owns
  `CHANGELOG.md` and `store/`; the app directory owns `pubspec.yaml`,
  `android/` and `ios/`.
- `cux_ship secrets exec` — decrypt a sops file, run a command with the
  credentials in its environment, remove them however the run ends.
- `cux_ship deps install` — fetch sops and age by pinned hash into `.bin/`.
- `api_issuer_id` is optional. An individual App Store Connect key has none,
  and requiring one ruled out the credential that scopes CI to a single app.
