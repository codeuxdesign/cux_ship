# Changelog

## 1.8.0

**A minor version that changes the secrets file's shape.** The number is
deliberate rather than an oversight: three projects use this, all owned by one
person and all checked out side by side, and none of them had a reason to
depend on 1.x meaning anything yet. A 2.0.0 two days after 1.0.0 would have
claimed a stability that never existed. Read this section as the breaking one it
is — the migration is at the end and takes about ten minutes per project.

- **The file's shape is now a schema, not a naming convention.** Credentials
  live at a position in a declared tree rather than being recognized by their
  name, and one walker reads that tree. `secrets keys` and `secrets exec` call
  it and differ only in whether they keep the values, so "is this recognized"
  has exactly one answer.

  This replaced six defects with one cause — three consumers each recovering
  structure from a string, slightly differently. Among them: a complete Android
  keystore that validated, reported nothing amiss, and **set no environment
  variables at all**; and `secrets keys` reporting a file as refused that
  `secrets exec` accepted, with the test meant to pin them comparing one set to
  itself and therefore unable to fail for any input.

- **Any credential can appear more than once, under a name.** An app that ships
  to the App Store, notarizes a direct download and signs a `.pkg` has three
  Apple certificates; one that keeps a scoped upload key alongside an Admin key
  for reading the portal has two API keys of different kinds. Previously the
  vocabulary could express one of each.

  Instance names never become variable names — uppercasing is not injective, so
  `dist` and `dist_p12` would mint the same variable. Selection fills the fixed
  names instead: exactly one instance is the default, two or more must be named
  with `--keystore` or `--api-key`, and a name that is not in the file is an
  error listing what is, rather than a fall back that would run an Admin-gated
  read with a scoped key.

- **Certificate kinds are a closed set** — `distribution`, `developer_id`,
  `mac_installer` — so `developr_id` is refused. Keystore, profile, token and
  ssh key names are the project's own, which is the one level no schema can
  police.

- **`api_private_key_filename` is replaced by `kind: team | individual`**, and
  the filename is derived from it and the id. The filename is the only signal of
  which claims Apple is sent; storing it as well meant a third copy that could
  disagree with the other two, which is why 1.7.2 had to cross-check them.

- **`tokens:` and `ssh_keys:`** hold what this tool will never understand — an
  artifact host, a deploy key. Each declares the variable it exports, validated
  as `[A-Z][A-Z0-9_]*` and refused if it collides with a name materialization
  sets, so a token cannot quietly redirect `ANDROID_KEYSTORE_PATH`.

- **`placed:` holds files the build reads from the working tree**, with
  `secrets place`, `secrets clean` and `secrets pack`. Some credentials are
  source — a compiler and an analyzer read them from fixed paths — so they
  cannot live in a temp directory and cannot vanish when a command exits.

  Their guarantee is a different one and weaker, and it is stated rather than
  implied: not *plaintext never outlives the run* but **plaintext never enters
  history**. A target is refused if it is not ignored, if git already tracks it
  (`.gitignore` does not apply to tracked files, so one `git add -f` makes a
  path publishable forever), if it crosses into a submodule, if it leaves the
  repository once symlinks are resolved, or if it is a symlink or a directory.
  All three verbs compare content: `place` refuses to overwrite an edited file,
  `clean` removes only what still matches, and `pack` re-encrypts an edit back.

- **`apple.profiles` is gone from `.cux-ship.yaml`.** The secrets file names the
  profiles; a second declaration of one fact is a second thing that can drift.
  `apple.signing: manual | automatic` stays, because it is a repository-level
  choice and not derivable from which blobs happen to be present — and it
  decides more than it sounds like: `-allowProvisioningUpdates` is a portal
  write and an individual key cannot read the portal at all, so automatic
  signing requires a team key that reaches every app in the team.

- **`path`, `env` and `kind` are stored in cleartext**, so `secrets keys` and
  the placement pre-flight work with no identity. That is a real disclosure — a
  path tells a reader where a project keeps things — and it buys a pre-flight
  that needs no key. Enforced both ways: the walker refuses an encrypted value
  in those fields and names the `unencrypted_regex` to add, and a schema whose
  secret-bearing field took one of those names fails the test suite.

### Migrating a project

Environment variables are unchanged, so **nothing that consumes credentials
needs editing** — `build.sh`, `upload.sh` and Gradle keep reading the same
names.

1. Add to `.sops.yaml`, under the rule that matches your secrets file:

   ```yaml
   unencrypted_regex: '^(path|env|kind)$'
   ```

2. Restructure the file. Needs the age identity, because sops binds each value
   to its key path — a textual rename fails authentication. Plaintext never
   touches disk:

   ```sh
   sops -d secrets/release.yaml \
     | <your restructuring> \
     | sops -e --filename-override secrets/release.yaml /dev/stdin \
     > secrets/release.yaml.new && mv secrets/release.yaml.new secrets/release.yaml
   ```

   | 1.7.x | 1.8.0 |
   | --- | --- |
   | `keystore_p12_base64`, `keystore_password`, `key_alias` | `android.keystores.<name>.{base64, password, key_alias}` |
   | `play_service_account_json_base64` | `android.play_service_account.json_base64` |
   | `api_key_id`, `api_private_key_base64`, `api_issuer_id` | `apple.api_keys.<name>.{id, private_key_base64, issuer_id}` |
   | `api_private_key_filename` | `apple.api_keys.<name>.kind: team \| individual` |
   | `distribution_p12_base64`, `distribution_p12_password` | `apple.certificates.distribution.{p12_base64, password}` |

3. Run `cux_ship secrets keys`. It needs no identity, reports every credential
   by path, and names anything half configured — so it will tell you whether the
   result is right before you try to build with it.

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
