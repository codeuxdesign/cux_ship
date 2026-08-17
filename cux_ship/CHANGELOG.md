# Changelog

## 2.2.0

- **`cux_ship appstore await`** exposes the wait that `appstore upload` already
  did internally. Uploading and waiting can now run on different machines,
  which matters because the wait is a poll against a REST endpoint that needs
  no Xcode, no keychain and no signing material — only the API key — while the
  runner that built the artifact is billed at 10× for being macOS. It also
  finishes `--skip-waiting`, which until now said a caller would wait later and
  left nothing to wait with.

  `--build-number` is required rather than defaulting to the newest build: the
  point of waiting elsewhere is to wait for a *specific* build, and "newest"
  would succeed on somebody else's upload. The three outcomes keep the meanings
  `upload` gave them — success, the 422 for a build Apple refused, and the
  timeout that names where the reason actually is.

- **Every certificate's remaining life is reported at import**, by
  `keychain exec`, in the words the developer-account audit already uses.
  A profile carries its own expiry and a certificate carries `notAfter`; they
  are independent, and nothing read the second. A profile valid for a year that
  embeds a certificate dying next week passed every check and failed inside
  codesign — and a project on automatic signing had no profile to check at all.
  Reported for every certificate imported, not only the one that signs, because
  an installer certificate expiring is a `productbuild` failure at the end of a
  Mac App Store run. A warning, never a refusal.

## 2.1.0

- **The App Store review contact comes from the environment**, as
  `APPLE_REVIEW_CONTACT_FIRST_NAME`, `_LAST_NAME`, `_EMAIL` and `_PHONE`, and is
  sent with every review-notes write.

  **Not from the metadata tree, and the asymmetry is deliberate.** Every other
  listing field is a file beside `info/`; a name, an e-mail address and a mobile
  number are one person's, they are the same person's across every project using
  this package, and at least one of those projects is a public repository. A
  phone number in git history outlives whatever the repository's visibility was
  on the day it was committed, and unlike a leaked key it cannot be rotated. The
  environment keeps the choice with each project — a sops file, a CI secret, a
  shell — which is where every other credential here already lives.

  All four or none: a partial set is refused before anything is written, since
  Apple wants them together. The phone is checked against the format Apple's own
  rejection describes — `+` then the country code — because that refusal
  otherwise arrives mid-push with several fields already landed.

  Sent on create *and* update, which is the part that is not guessable: creating
  a review detail with notes alone succeeds, and updating one is then refused
  without the whole contact. So the second push of an unchanged file failed
  where the first had worked.

- **`appstore upload --metadata` now publishes review notes**, from
  `review-notes.md` beside `info/` and `listings/`, into
  `appStoreReviewDetails.notes` on the version.

  **This is the piece of a listing whose absence costs a review cycle rather
  than a rejection.** An app with no content of its own — anything that needs
  the user's own files before it shows anything — opens to an empty screen, and
  a reviewer with no sample data concludes it does nothing. That comes back days
  later as "we were unable to evaluate your app", with nothing to fix, and it is
  invisible beforehand because every other part of the listing uploaded fine.

  The notes are created where the version has none and patched where it has
  some — with the contact above sent alongside either way.

  Parsing, the marker that keeps internal checklists out of it, and the
  4000-character check are `cux_ship_verify` 1.8.0 — so `cux_ship verify` fails
  an over-long note with no network at all.

## 2.0.0

**The Play service account is passed as a path, not as JSON.** `secrets exec`
now writes the account to a file and exports
`GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH`. `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` is
**gone** — not deprecated, not exported alongside.

### Why

A Google private key reached four public CI logs. An xcode script build phase
writes its whole environment into the build log, and a public repository's
action logs are public, so a variable holding a key printed the key. It was the
only credential this package passed by value; every other one was already a
path, and no other one leaked. That is not a coincidence, and it is the rule
this release makes universal:

> A secret passed as a value can escape through anything that echoes its
> environment. A secret passed as a path cannot.

1.9.0 and 1.9.1 mitigated it by letting a caller withhold the credential from
commands that cannot need it. That was worth having and it is still here, but it
was never the fix: withholding is not compositional. Each layer can speak for its
own child and no further, so a `secrets exec` nested inside a `keychain exec`
reintroduced the value for its own subtree — and "build under `keychain exec`,
upload under `secrets exec`" is the natural shape, so the mitigation failed
exactly where the pattern was most idiomatic. A path cannot be reintroduced in a
form that matters, because what comes back is a filename in a temp directory
that has already been removed.

### Migrating

One line per consumer. Read the file instead of the variable:

```diff
- echo "$GOOGLE_PLAY_SERVICE_ACCOUNT_JSON" > /tmp/sa.json
- supply --json_key /tmp/sa.json
+ supply --json_key "$GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH"
```

**There is deliberately no window in which both are exported.** A window is the
only variant in which something can quietly keep using the by-value path: the
key stays in every consumer's environment for its whole duration while the
release notes claim it was removed, which converts a known problem into a
believed-solved one. It is less safe than either alternative, not a middle
course between them.

Not migrating is loud rather than silent. An unmigrated consumer finds the
variable unset and dies on its first line naming the cause — which is the
criterion this package already applies elsewhere, and the reason the new name is
`…_PATH` rather than the old name with new meaning. A consumer reading a path
from a variable still called `…_JSON` would post a filename to Google and fail
at the API, describing neither the file nor the script.

## 1.9.1

**Withholding did not survive being nested, which is the composition 1.9.0's own
notes recommend.** `cux_ship secrets exec -- cux_ship keychain exec -- build`
gave the build every credential the file holds, including the Play service
account private key by value — the exposure `keychain exec` was added to close,
reintroduced by the documented way of using it. Upgrade if you nest them. A
project with `keychain exec` outermost was never affected.

Two causes, and the second is the instructive one:

- Declining to *add* a variable does nothing when it is already there. The
  environment begins as a copy of this process's own, so under nesting the outer
  command has already placed every credential. Withheld families are now
  **removed**, however they arrived.
- Removing them from the map did not remove them from the child.
  `Process.start` merges the map into the parent's environment unless
  `includeParentEnvironment` is false, so every deletion was restored from this
  process's own environment — exactly the case that matters, since under nesting
  the parent is what holds the credential.

The second was invisible from inside: the `removed from the environment` line
printed the correct full list throughout, because it reports what this process
did to a map rather than what the child received. Only reading the child's own
environment showed otherwise.

### A limitation this does not fix

**Withholding does not propagate downward through a second `secrets exec`.** The
natural shape —

```
cux_ship keychain exec -- sh -c 'build && cux_ship secrets exec --api-key k -- upload'
```

— builds without a Play credential and then, for the duration of the upload
child, has one again: the inner call loads the file fresh and withholds nothing.
That is correct for an uploader that needs it, and it means the by-value private
key is present at exactly the moment most likely to be wrapped in CI logging.

This is not fixable by adding more withholding, and the attempt would be worse
than the disease — a `secrets exec` that withheld the Play account by default
would break every Android upload that does not know to ask, which is all of
them. **The fix is to stop passing it by value at all**, exporting a path like
every other credential here, and that changes the contract and belongs to the
next major version. Until then, an Apple build should not be wrapped around a
Play upload in a job whose log is public.

- The reserved-name collision guard is derived from the withholding table rather
  than listed beside it. They were the same nine names written twice, and drift
  is silent in both directions: a name missing from the guard lets a project
  token overwrite a real credential, and one missing from the table leaves a
  secret in a child's environment the caller believes it withheld.

## 1.9.0

**Purely additive.** Nothing in the 1.8.0 secrets contract moves, and a project
that does not sign Apple builds sees no difference.

- **`cux_ship keychain exec -- <command>`** runs a command with the project's
  Apple signing identity in a keychain that is created for it and destroyed
  however the run ends. macOS only, and it refuses rather than continuing
  anywhere else — a build that carries on without the keychain signs with
  whatever the machine happens to hold, and exits zero.

  **The login keychain is never read.** That is the point rather than a side
  effect: a signing identity that comes from installed machine state makes the
  same commit sign differently on two laptops, with nothing saying so.

  It consumes the 1.8.0 schema rather than extending it — `apple.certificates.*`
  and `apple.profiles.*` as `secrets exec` already materializes them. Reads them
  from the environment when they are already there, so `secrets exec -- keychain
  exec -- …` composes, and otherwise decrypts the file itself. Which of the two
  happened is printed, not inferred.

  The wrapped command gets `APPLE_KEYCHAIN`, and is expected to pass
  `OTHER_CODE_SIGN_FLAGS="--keychain $APPLE_KEYCHAIN"` to xcodebuild. Not
  optional: the login keychain cannot be removed from the search list — that
  would drop Apple's intermediates and leave the leaf chaining to nothing — so
  pinning is the only thing that makes *signed with the certificate we imported*
  true rather than likely. A stale identity of the same name in the login
  keychain is not hypothetical; there was one on the author's machine, three
  months old, while this was being written.

  It consolidates two implementations that had each found a different subset of
  this platform's sharp edges, and adds four things neither had:

  - **Garbage collection of keychains left by a killed run.** A trap covers a
    failed build, Ctrl-C and SIGTERM. It covers neither SIGKILL nor the power
    going out, and what survives those is a distribution private key in a
    keychain that stays unlocked for the rest of its timeout. The pid in the
    filename is what makes staleness checkable, and nothing was checking it.
  - **A refusal when a named provisioning profile has expired**, at import
    rather than inside codesign, which reports it without using the word. Only
    when named with `--profile`: the secrets file holds every profile a project
    has, so failing on any expired one would mean an unused Developer ID profile
    lapsing breaks every App Store release, naming a profile that build never
    touches.
  - **Quote-aware parsing of the keychain search list.** Both sources strip
    quotes with `tr` or `sed`, which corrupts the list for anyone whose home
    directory contains a space — the output is quote-delimited precisely to
    permit that.
  - **A diagnosis rather than an assertion** when there is no usable identity.
    `find-identity -v` alone cannot separate "the .p12 had no private key" from
    "the key is here and the certificate does not chain", and those need
    opposite fixes.

- **`loadSecrets` takes `withhold`**, naming credential families the caller
  declares it does not consume. Additive: the default withholds nothing, so
  `secrets exec` is unchanged.

  It exists because a caller that knows its child's platform knows more than
  this file can. `keychain exec` withholds all three it can, each for its own
  reason, and says so rather than going quiet:

  - **`android.keystores`** — an Apple signing command's child cannot sign an
    Android artifact. Refusing to start because the file held two keystores
    locked the first consumer out of the command entirely.
  - **`android.play_service_account`** — **the one credential this tool passes
    by value rather than as a path**, and therefore the one that can escape
    through anything that echoes its environment. An Xcode script build phase
    writes its whole environment into the build log; this variable reached a
    *public* CI log that way, in full, in a project that ships from one.

    Every other credential is a filename in a temp directory that no longer
    exists by the time anyone reads the log. **Withholding it here is a
    mitigation, not the fix** — the fix is to write it to a file and export a
    path like everything else, which changes the contract and so belongs to the
    next major version. A consumer still running an Apple build under plain
    `secrets exec` should unset the variable before invoking xcodebuild.
  - **`apple.api_keys`** — signing needs no App Store key. Nothing is placed
    unless `--api-key` names one: not the singular variables and not
    `API_PRIVATE_KEYS_DIR`, so the `.p8` is never written. A build step can
    deliberately hold no App Store credential — which is what lets CI sign
    without holding anything able to create or revoke signing material — and
    requiring a key to obtain a keychain would give that property away.

    The asymmetry with the keystore above is the argument, and it is worth
    keeping: a keystore that fails to arrive is *silent*, because Gradle falls
    through to the debug config and Play rejects the artifact after a full
    upload. An App Store key that fails to arrive is *loud*, because its
    consumer dies on the first line naming the cause.

  An unrecognized family name is refused rather than ignored, since one
  misspelled withholds nothing while reporting success — and for the Play
  account that means a private key in an environment the caller believes it
  excluded.

- **`ProjectContext.developmentTeam`** reads `DEVELOPMENT_TEAM` from whichever
  Xcode project has one, ignoring the empty assignment Xcode writes for a target
  without a team. It is what lets the identity check ask whether the certificate
  belongs to the account this project builds for — a certificate from another
  account imports perfectly and fails much later as a profile mismatch that
  never mentions certificates.

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

**The tool and the file have to move together, and no order avoids a window
where they disagree.** Both directions fail loudly, and the message says which
way round you are: an older version reading a new file complains that something
*"nests deeper than a credential goes"*, while this version reading an old file
reports unrecognized keys. Neither can mistake the other's file for a valid one,
so the window is an inconvenience rather than a hazard — but do these in one
sitting.

1. **Raise the constraint and upgrade.** A minor bump does not compel this the
   way a major one would: `^1.7.1` already permits 1.8.0, so a resolved
   `pubspec.lock` stays where it is and `dart pub get` alone will not move you
   onto the version that can read the new shape.

   ```sh
   dart pub upgrade cux_ship     # or raise the constraint to ^1.8.0
   ```

2. Add to `.sops.yaml`, under the rule that matches your secrets file:

   ```yaml
   unencrypted_regex: '^(path|env|kind)$'
   ```

   Inert until the file holds a `placed:`, `tokens:`, `ssh_keys:` or
   `apple.api_keys` entry, so a project with only a keystore and a service
   account needs nothing from it yet. Add it anyway: otherwise its absence
   surfaces months later, from a file that had been working, the first time
   somebody adds one of those.

3. Restructure the file. Needs the age identity, because sops binds each value
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

4. Run `cux_ship secrets keys`. It needs no identity, reports every credential
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
