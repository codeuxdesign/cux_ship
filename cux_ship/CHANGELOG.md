# Changelog

## 1.7.2

- **An individual App Store Connect key was classified as a team key.**
  `secrets exec` materialized every key as `AuthKey_<id>.p8`, and both `altool`
  and this tool's JWT builder read that prefix to decide which claims to send —
  Apple names an individual key `ApiKey_<id>.p8` and a team key `AuthKey_<id>.p8`.
  So an individual key routed through `secrets exec` was sent `iss` instead of
  `sub: user` and got a bare 401, after a full build.

  The issuer id cannot stand in for the prefix: `altool` documents
  `--api-issuer` as required alongside `--api-key`, so an individual key
  legitimately carries one too. The filename is the only signal, which is why
  inventing it destroyed the distinction.

  New optional `api_private_key_filename` carries the name Apple gave the key.
  **Absent, the behavior is exactly as before** — `AuthKey_<id>.p8` — so a
  project with a team key needs no change. A project with an individual key
  must now set it. The value is checked against `(ApiKey|AuthKey)_<id>.p8` and
  against `api_key_id`, because it becomes a filename in a directory `altool`
  searches, and a mismatched id produces a file `altool` looks straight past.

  Predates the Dart port — `with-secrets.sh` renamed identically. Found by the
  AuthPass maintainers while migrating onto `secrets exec`.

- `cux_ship_verify` is **not** released alongside this one. It has no changes,
  and the dependency on it now names the oldest version that works rather than
  the newest — bumping in lockstep made the repository unresolvable as a git
  dependency for the whole window between a commit and its publish.

## 1.7.1

From a security audit. No high-severity defects were found; these are the three
worth acting on.

- **A malformed decrypted secrets file could print its own contents.**
  `package:yaml` renders a parse error with the offending source line and a
  caret under it, and the whole exception was being interpolated into a message
  that goes to stderr — so a decrypted private key could land in a terminal or a
  CI log. It needs a hand-mangled file that still decrypts, which is why it is
  not higher, but it is the difference between an error and a disclosure. Both
  YAML error paths now print the bare reason and no source.
- **`deps update` now validates what it writes.** The version and hash come from
  GitHub over the network and were interpolated into generated Dart source
  inside single quotes, so a value carrying a quote could inject code that runs
  on the next analyze. Maintainer-only and behind a reviewed diff; two regexes
  are cheaper than relying on the review.
- **Pagination cannot carry the bearer token off-origin.** `getAll` followed
  `links.next` to whatever host it named, with the Authorization header
  attached. Reaching it would require Apple's own TLS response to be
  attacker-controlled — but "the token only goes to Apple" should be a property
  of this code rather than of Apple's response.

## 1.7.0

- **`cux_ship secrets keys`** — lists the credential names in a secrets file
  without decrypting it, says which heading each sits under, marks any name
  `secrets exec` would refuse, and ignores the `sops:` metadata block. Worth
  running before adopting a new version, since an unrecognized key stops
  `secrets exec` outright.
- **Fixes a wrong command in the bundled skill**, which is why this exists. It
  recommended `grep -oE '^[a-z_]+:|^[[:space:]]+[a-z_]+:'` for the same job, and
  that character class omits digits — so against a real file with nine
  credentials it reported four and hid five, including the entire Android
  keystore, the Play service account and the App Store private key. Every name
  it hid was one carrying key material, and the output read as a clean bill of
  health.

  The command replaces the advice rather than correcting it: it shares the
  key-walking with the parser that enforces the rules, so the two cannot drift.
  Reported by a consumer migrating from 1.5.1.

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
