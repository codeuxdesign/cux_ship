# cux_ship

Release tooling for shipping a Flutter or Dart app to the App Store and Google
Play: upload an artifact, publish the store listing, promote a build that is
already up, and turn a `CHANGELOG.md` into the notes each store shows.

Extracted from [Hold the Wheel](https://holdthewheel.app/) with its
history intact — `git log --follow` on any file here reaches back past the
extraction. Most comments in this code record a specific incident, and that is
the point of keeping the history: `git blame` is usually the only way to recover
why a line exists.

Inside: a hand-written App Store Connect REST client (ES256 JWT auth, the
three-step asset upload, screenshot and listing metadata, TestFlight notes,
promotion), and a Google Play client on `googleapis` that uploads a bundle to a
track, publishes the listing and promotes between tracks.

**There is a second package, and which one you want depends on what you are
doing.**

| Package | Depend on it when |
|---|---|
| **`cux_ship`** | You are *shipping*. The command, and everything behind it. Pulls googleapis, an image codec, an HTTP client and a JWT signer, because publishing needs all of them. |
| [`cux_ship_verify`](https://pub.dev/packages/cux_ship_verify) | You are *checking*. The offline half — the changelog parser, the App Store metadata model, and the checks over both. **No dependencies at all**, which is what makes it right for a `dev_dependency` that runs in your test suite on every push. |

`cux_ship` depends on `cux_ship_verify`, never the reverse. That direction is
the whole design: reaching the checks through the CLI is what would put
googleapis in the lockfile of somebody who only wanted to know whether a release
note is too long.

## The command

```
cux_ship appstore upload            play upload            release finish
         appstore promote           play promote           release refspecs
         appstore beta-release      play tracks            screenshots flatten
         appstore beta-groups       play listing           verify
         appstore builds            play version-code      secrets add
         appstore versions                                 secrets check
         appstore screenshot-types                         secrets list
         appstore build-number                             secrets remove
         appstore wait                                     secrets exec
         appstore signing                                  secrets place
                                                           secrets clean
                                                           secrets pack
                                                           keychain exec
                                                           deps install
                                                           deps check
                                                           manifest write
```

**Run it from a project root and it works out the rest.** The `applicationId`
comes from Gradle, the bundle identifier from the Xcode project, the version
from `pubspec.yaml`, and `CHANGELOG.md` / `store/appstore` / `store/play` from
where they conventionally sit. Flags override; they are not requirements. So the
normal case is a bare subcommand:

```bash
cux_ship play promote        # internal → production, newest build, notes from CHANGELOG.md
cux_ship appstore promote    # newest processed build → App Store review
```

An App Store promotion submits for review; what happens once Apple approves is
the version's release type. New versions are created `MANUAL` — somebody
presses release — and existing ones are left as App Store Connect has them.
`--release-type AFTER_APPROVAL` says go out on approval instead, and the run
prints the effective value read back from Apple either way. It is a different
axis from `--phased`, which is how fast a release rolls out once it starts.

**Anything that becomes public asks first**, printing everything it inferred, so
a wrong guess is visible before it is acted on rather than after:

```
About to release to production on Google Play. This is public immediately.
  app           design.codeux.holdthewheel
  to track      production
  from track    internal
  versionCode   newest on the "internal" track
  notes from    /path/to/CHANGELOG.md

Proceed? [y/N]
```

`--yes` skips the question. With no terminal and no `--yes` the command
**refuses** rather than assuming yes, so a CI job that gained an interactive
step fails loudly instead of releasing on a default. `--dry-run` never asks —
it writes nothing, and a prompt there would only teach the habit of answering
yes.

### When the app is not the repository root

In a monorepo the Flutter app is a subdirectory and the release is still a
property of the repository. Both halves of that matter:

> The **repository** owns `CHANGELOG.md` and `store/`.
> The **app directory** owns `pubspec.yaml`, `android/`, `ios/` and `macos/`.

That is not a compromise between two conventions. A version lives in
`pubspec.yaml` because Flutter puts it there, and platform identifiers live
under `android/` and `ios/` for the same reason. The changelog and the store
listing describe what *shipped* — and in a monorepo most of what a user notices
usually changed in some package other than the app.

Say it once, in `.cux-ship.yaml` at the repository root:

```yaml
app-dir: app
```

This is a property of the repository rather than of a command, which is why the
file is the normal home for it — a shell script that drives several `cux_ship`
invocations would otherwise repeat one constant at every call site, which is
exactly the "keep three copies in step" that inference exists to remove.
`--app-dir` overrides it and `CUX_SHIP_APP_DIR` sits between the two, in that
order.

**An unknown key in that file is an error**, not something skipped. It is read
silently before every command, so a misspelt key that is quietly ignored is a
setting that appears to be applied and is not. For the same reason an `app-dir`
that does not exist, or is outside the repository, stops the command instead of
being inferred past — the alternative is every inferred value turning back into
a required flag, and the first symptom being a command asking for a `--package`
it has always worked out for itself.

Without any of this, nothing changes: a project whose app *is* its repository
needs no file and reads exactly as it always did.

### beta-release is promote's TestFlight sibling

```bash
cux_ship appstore beta-release --build-number 52 --beta-group "External Testers"
```

It gives a build TestFlight already holds to a beta group, and builds and
uploads nothing — the case where CI uploaded the build and `upload` has
nothing left to carry. An internal group receives the build by assignment
alone. An external one receives nothing that way, so the release carries on:
the Beta App Description is reasserted from
`store/appstore/listings/<locale>/beta_description.txt` when that file exists
(and left to the console when it does not), the build is submitted for beta
review, and the closing line reads back the state Apple now reports.
`--build-number` is required rather than defaulted to the newest, for the
same reason `appstore wait` requires it: "newest" would release somebody
else's upload.

### promote is per-store; `release finish` is per-release

`appstore promote` and `play promote` change no version and touch no git. A
build number belongs to a commit; both stores promote that *same* build; so the
version they publish is the same one — which only holds if promotion cannot
move it.

The repository-side half is its own command, run after every store has been
promoted:

```bash
cux_ship release finish --build-number 41
```

It tags the released commit and moves the branch to the next patch version,
with an empty changelog section for it. That second part is not a convenience:
a released version is public, so every later build would otherwise claim a name
that is already in front of users, and a release build should refuse in that
state — meaning a release would quietly break the next push. Doing it here
means that state never exists.

Always a patch bump, because it is the only choice that cannot be wrong before
the work exists. Calling it a 1.1.0 instead is an ordinary commit afterwards.

Repeating it is safe, because a release is exactly the situation where something
fails half way and gets run again: a tag that already names **this** commit is
fine, and a branch already past the released version is not bumped.

**A tag that names a different commit is an error**, and so is the bump with it,
`--dry-run` included. That is one version recorded against two commits, so one
of them is wrong and this refuses rather than choosing; retag deliberately.

**A repeat also pushes a tag an earlier run created but failed to push.** That
used to be permanent: the push ran only on the run that created the tag, so
every later run found it locally, said it was leaving it alone, and finished
green while the remote never received it — leaving the release untagged
anywhere a later reader looks.

```
--commit       what to tag; defaults to HEAD. Any commit-ish; resolved before
               it is compared, so a short sha or HEAD names what you meant
--version      what was released; defaults to that commit's pubspec.yaml
--branch       where the bump belongs; defaults to main
--no-tag / --no-bump / --no-push / --dry-run
```

### `--manifest` — name the build once

If your build script writes a manifest beside its artifact, hand that over
instead of retyping what is in it:

```bash
cux_ship appstore upload --platform ios --manifest dist/ios/manifest.json
==> how-it-went-1.1.0-51.ipa — build 51 of 1.1.0 from fef65ce, digest verified
```

It supplies `--artifact` (or `--aab`), `--build-number`, `--version-name` and
`--commit`. **Explicit flags still win** — a manifest is inference, and
inference loses to what was typed.

It also **verifies the artifact against the digest the manifest records**, which
catches a `dist/` that was edited, half-written, or left over from an earlier
build whose manifest was replaced without its artifact being rewritten. Every
flag correct and the bytes belonging to a different build is not a failure that
announces itself.

**Hash the artifact you are going to upload, after signing.** If a producer
records the digest before the signature is applied, this check fails on every
real release rather than never — the sort of thing found at the worst possible
moment, on a path nobody exercises until it matters. The reference producer
copies the signed artifact into `dist/` and hashes that copy.

A build the manifest marks as coming from a dirty tree is refused unless you
pass `--allow-dirty`, because the commit it names does not then describe what is
inside the artifact. **If your own script already refuses dirty builds, the two
have to agree**: a build yours deliberately allows will otherwise pass your
check and fail this one.

Schema 1, and an unknown schema is refused rather than read optimistically —
every value the upload is named by comes from this file:

```json
{ "schema": 2, "platform": "ios", "versionName": "1.1.0", "buildNumber": 51,
  "gitSha": "fef65ce…", "dirty": false, "format": "ipa",
  "artifact": "how-it-went-1.1.0-51.ipa", "sha256": "…" }
```

`artifact` is relative to the manifest, so a `dist/` tree stays movable.

### `manifest write` — the other half, so the schema exists once

```bash
cux_ship manifest write --artifact dist/android/app-1.1.0-53.aab \
  --platform android --format aab \
  --version-name 1.1.0 --build-number 53 \
  --git-sha "$SHA" --no-dirty
```

Before this, every consuming repository wrote the file with a shell heredoc — so
the schema existed in prose in each of them and in code in none, and a field one
producer omitted was invisible until an upload weeks later published an artifact
described by the wrong numbers. The writer sits beside the reader, which makes
the round trip a test rather than a convention.

Three things it refuses, each of which fails silently otherwise:

- **The digest is computed here and cannot be passed in.** A digest recorded
  before signing fails verification on *every* real release rather than never,
  so it must not be expressible. Run this after signing.
- **`--dirty` has no default.** Give it as `--dirty` or `--no-dirty`; a script
  that forgot the flag would certify every dirty build as clean.
- **An abbreviated `--git-sha` is refused.** 40 hex characters for a sha1
  repository, 64 for sha256. A reader normalizes whatever it is given, which is
  exactly what lets a seven-character sha survive here and break a tool that
  does not.

`--git-sha` and the dirty flag are inputs and never derived: this runs *after*
the build, where a tree that moved in between is invisible.

`--out` writes the manifest under a different name **in the artifact's own
directory** — for a build that keeps one artifact per platform directory and
wants a fixed `manifest.json` its uploader can name without globbing. Anywhere
else is refused, because the artifact is recorded as a basename resolved against
the manifest's directory.

### `--derived-from` — a repackaged artifact inherits its provenance

```bash
cux_ship manifest write --artifact app_1.9.15_amd64.deb \
  --platform linux --format deb \
  --derived-from app-1.9.15.tar.gz.manifest.json \
  --packaging gitSha=… --packaging repo=…
```

No build facts are retyped: the `.deb`'s manifest carries the *tarball's*
`gitSha`, `dirty`, `versionName` and `buildNumber` as its own, because a reader
that knows nothing about derivation must still get true answers from the fields
it already reads.

**It takes the parent's manifest, not a hand-assembled entry**, so the chain
assembles itself and stays flat and nearest-first through any number of steps —
a `.snap` from a `.deb` from a tarball records both ancestors and still reports
the tarball's commit. The parent is digest-checked when its artifact sits beside
its manifest, which turns a fetch that straddled a non-atomic upload into a
refusal rather than a derivation recorded from bytes nobody has.

### The cross-check — the manifest is compared against the artifact

Every `--manifest` upload reads the build's own values back out of the artifact:

```
==> app-1.1.0-66.aab — build 66 of 1.1.0 from bd8d32f…, digest verified
    cross-check: build number and version name agree with base/manifest/AndroidManifest.xml
```

The digest proves the bytes are the ones the manifest was written for. It cannot
notice that the *build* disagreed with the values the script passed — an export
step rewriting `CFBundleVersion`, a Gradle override, a variable that evaluated
empty. In each of those the manifest honestly describes the wrong artifact and
every flag is correct.

`aab` is read from `base/manifest/AndroidManifest.xml` (aapt2 protobuf), `apk`
from `AndroidManifest.xml` (binary XML — a different encoding, so a separate
reader), and `ipa` from `Payload/*.app/Info.plist`. **A format with no reader is trusted out loud** —
`cross-check: no reader for pkg — build number and version name taken on
trust` — because "not checked" must not render the same as "checked and fine".

### Recording which commit an upload came from

Off unless a repository asks for it:

```yaml
# .cux-ship.yaml
tag:
  upload:
    enabled: true
```

`tag:` is the namespace for every kind of tag this tool writes, and both kinds
are implemented. `upload` records one upload of one build and is **off** unless
asked for; `release` names the tag `release finish` writes and is **on**,
defaulting to the `v{version}` this tool has always written.

```yaml
tag:
  release:
    format: rel/{version}    # default: v{version}
```

A release format must contain `{version}`, or every release would collide under
one name. `{build}` is allowed but not required — and if a format asks for one
when the command has none, the tag is **refused** rather than written with the
gap left empty, because `v1.2.3+` is wrong by a single trailing character in a
name nobody reads twice.

With it on, `play upload` and `appstore upload` write an annotated tag naming
the commit the artifact was **built from**, before contacting the store:

```bash
cux_ship play upload --manifest dist/android/manifest.json
```

`--manifest` supplies the commit, so nothing has to read it out by hand:

```bash
cux_ship play upload --commit "$(jq -r .gitSha dist/android/manifest.json)"
```

**`--commit` is not inferred.** An upload job routinely runs
on a different checkout from the build — a `workflow_run` trigger, a repackaging
step, a retry hours later — so `HEAD` is not the answer, and a record naming the
wrong commit is worse than no record at all. It is your build manifest's
`gitSha`.

**Before the store rather than after**, because a record written afterwards
makes the failure mode *shipped but unprovable* — an artifact in front of users
whose commit nobody can name. Written first, a failure fails an upload that had
not happened yet. It follows that the tag records an upload **attempted**, not
accepted: a signature refusal leaves it standing over an artifact nobody
received. Read them as attempts.

The same name at a different commit is a hard error — one build number reaching
two commits — and it raises `UploadCollisionException`, distinct from an
ordinary failure so a wrapper that tolerates "this build is already uploaded"
does not tolerate this too.

The default name is `uploaded/v{version}+{build}`, and the namespace is a
correctness property rather than a preference: a release guard that asks "has
this version shipped" by taking the highest `v*` tag reads a bare `v1.0.4+56` as
a released 1.0.4 — `sort -V` ranks build metadata *above* the version it
annotates — and then refuses to build 1.0.4, naming a release that never
happened. Override with `tag.upload.format`, which must contain `{build}`.

**The namespace protects that guard and not every reader — check yours.** A
consuming repository found the second one the hard way: its build script derives
the version name with `git describe --exact-match`, which returns *whatever* tag
`HEAD` carries. After an upload tagged the commit, the next platform built in the
same release read `uploaded/v1.1.0+67` as its release tag, stripped a leading
`v` that was not there and everything after the `+`, and refused with
`uploaded/v1.1.0` against a pubspec saying `1.1.0`.

`git describe --exact-match --match 'v*'` is the fix there. The general point is
that these tags are now on your release commits, so anything that reads tags
sees them — and only a multi-platform release that *interleaves* build and
upload produces it, which is why no test had the shape.

### `release refspecs` — so a clone can see the build numbers

`refs/buildnumbers/*` and `refs/notes/buildnumbers` are outside `refs/heads` and
`refs/tags`, so a clone's default refspec ignores them: a fresh clone has no
allocation history until something fetches it explicitly.

```bash
cux_ship release refspecs        # once per clone
```

It appends to `remote.origin.fetch` and never replaces it — the branch refspec
already there is what every other git operation depends on. `--remote` names a
different remote, `--dry-run` says what it would do.

### `appstore signing` reads the account, not the app

Automatic signing — `xcodebuild -allowProvisioningUpdates`, and Xcode whenever
it signs a device build — registers App IDs, capabilities, app groups and
profiles without mentioning it. That is mostly what you want, and it is the
reason a project can drop match and its encrypted certificate repository
entirely. The cost is that the account accumulates, silently, and the first
sign of it is usually a registration refused with *"An App ID with Identifier …
is not available"* — which means Xcode created that id months ago, often for a
target since renamed.

```bash
cux_ship appstore signing
```

Certificates first, because they are the only capped category and the only one
shared by every app in the team: exhaust the cap and nothing signs, for any
app. Then App IDs, marking the ones Xcode registered (it names them
`XC <dotted id>`) and separating this project's from the rest. Then profiles,
with their state and expiry.

It writes nothing, ever — no flag makes it destructive. Prune from the portal;
anything automatic signing still needs, it recreates on the next build.

## Consuming it

Install it once and use it from anywhere:

```bash
dart pub global activate cux_ship
cux_ship --help
```

Or pin it, which is what a project that releases from CI should do — a runner
should not resolve "whatever is newest today" in the middle of a release:

```yaml
# tool/cux_ship/pubspec.yaml — a tiny package whose only job is to pin this
name: my_app_ship
publish_to: 'none'
environment:
  sdk: ^3.12.2

dependencies:
  cux_ship: ^1.6.0
```

```bash
cd tool/cux_ship && dart run cux_ship --help
```

A separate package rather than a dependency of your app, because none of this
belongs in what you ship — and because `dart run` resolves against the package
it is invoked from. Everything the command needs is inferred from the repository
around it, so the directory it lives in does not matter.

**Most projects end up with both, and the two drift apart silently.** Scripts
run the pinned one through `dart run`; anything typed at a prompt runs the
global one, because that is what is on `PATH`. Bumping the lockfile does nothing
for `cux_ship …` typed by hand, and neither install mentions the other — so a
fix can be installed, resolved, and still absent from the command you are
actually running. That has already cost someone twenty minutes concluding a
released fix had not landed when it had.

```bash
dart pub global list | grep cux_ship                 # the global one
grep -A5 'name: cux_ship$' tool/cux_ship/pubspec.lock | grep version  # the pinned one
```

Neither is `--version`, because there is no such flag — the command reports
nothing about itself, which is part of why the two can disagree unnoticed. The
`$` in that grep is load-bearing: without it the pattern also matches
`cux_ship_verify`, which is the next entry in the lockfile, so it prints two
versions with the wrong one first. Two people wrote that grep unanchored before
it was noticed.

Worth checking first whenever a version's behaviour is not what its changelog
says.

**The pinning problem is in your documentation, not your scripts.** Scripts are
already safe: anything that `cd`s into the pinned package before `dart run`
cannot reach the global install, and that is nearly every script that exists.
What resolves `PATH` is the bare `cux_ship …` in a README, a runbook, or a
usage header — every command a person types by hand. Two projects measured
themselves after hitting this: one had 4 pinned invocations against 63
documented bare ones, and the other, whose documented commands all name a
wrapper script, had one. Same package, same lockfile, an order of magnitude
apart in exposure.

So a repository that documents a bare command name has not pinned it, however
carefully it pinned the package. The wrapper script is not protecting the
scripts — they were never at risk. It is protecting the reader.

**If your test suite uses the checks, depend on
[`cux_ship_verify`](https://pub.dev/packages/cux_ship_verify) directly** rather
than reaching them through `package:cux_ship/verify.dart`. That re-export still
works and is kept for compatibility, but it brings the whole CLI — googleapis
included — into the lockfile of every contributor.

### Credentials

**No uploader reads a secrets file or knows what a keychain is.** Every
credential arrives as an environment variable — `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH`
for Play, and `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID` and
`APPLE_API_PRIVATE_KEY_PATH` for the App Store — so they work unchanged if those
ever come from Vault, another CI's secret store, or a shell you exported by
hand.

Every one of those is a *path*, and that is deliberate: a variable holding a
filename is safe to print, and things print environments. See 2.0.0 in the
changelog for the incident that settled it.

`secrets exec` is how they get there when you have nothing better, and it is
deliberately a *separate command* rather than something the uploaders do: there
is exactly one place that creates plaintext and one that destroys it, and the
encryption choice stays swappable because of that split.

```bash
cux_ship secrets exec -- tool/build.sh --release android
cux_ship secrets exec -- cux_ship play upload
```

It decrypts `secrets/release.yaml` with [sops](https://getsops.io), puts the
credentials in the child's environment, and materializes the three that a tool
can only open as a file — the Android keystore, the App Store Connect `.p8` and
the distribution certificate — into a private temp directory it removes however
the run ends, including on Ctrl-C. The child runs with the repository root as
its working directory.

**`--only` narrows that to what the child actually consumes:**

```bash
cux_ship secrets exec --only apple.api_keys.upload -- tool/upload.sh
```

The selector is `family` or `family.instance`, comma-separated or repeated. On
this command it is optional — omitted, everything is placed, because a
general-purpose wrapper that hands over nothing is inert. On `keychain exec` it
is the only way anything arrives at all; see below.

Naming a subset *removes* what is not named, rather than merely declining to
place it. That matters under nesting, where an outer wrapper has already put
everything in the environment before an inner one runs.

```yaml
# secrets/release.yaml, before sops encrypts the values
keystore_base64:              # the Android upload key, and its
keystore_password:                # password and alias. All three or none
key_alias:
key_password:                     # only for a keystore whose key password differs

play_service_account_json_base64:

api_key_id:                       # App Store Connect. Both, or neither
api_private_key_base64:
api_issuer_id:                    # team keys only — see below

distribution_p12_base64:          # only a machine with an empty keychain
distribution_p12_password:        # needs these. Both, or neither
```

**Headings are allowed and mean nothing.** Group them however the file reads
best — one level deep, and the heading is discarded:

```yaml
android:
  keystore_base64:
  keystore_password:
  key_alias:
apple:
  api_key_id:
  api_private_key_base64:
```

A credential does not become a different credential because of the heading it
was filed under, so the names that matter are the leaves. The same leaf under
two headings is refused rather than resolved — which one wins is not something
to guess at with a credential.

### `keychain exec` — signing, and a child that holds nothing

```bash
cux_ship keychain exec --profile ios_appstore -- tool/build.sh --release ios
```

It imports the signing certificate into a keychain that exists for the length of
one command and is destroyed however that command exits, installs the profiles
you name, and sets `APPLE_KEYCHAIN`. The login keychain is never read — a build
whose identity comes from whatever a developer happens to have installed is a
build nobody can reproduce.

The wrapped command is expected to pass
`OTHER_CODE_SIGN_FLAGS="--keychain $APPLE_KEYCHAIN"` to xcodebuild. That is not
a nicety: this command cannot *remove* the login keychain from the search list
without taking Apple's intermediate certificates with it, so pinning codesign to
ours is the only thing that makes "signed with the certificate we imported" true
rather than likely.

**Its child gets `APPLE_KEYCHAIN` and nothing else.** No tokens, no keys, and
not the sops identity. Whatever else the child needs is named:

```bash
cux_ship keychain exec --only ssh_keys.github_deploy -- tool/release.sh
```

That is knowledge only the call site has. This command wraps a *build script*,
so what the script consumes happens below this command's arguments — in one real
project four layers down inside a function, with the variable's name inside a
`printf` format string. Nothing here can read that, and a rule that tried
withheld the one token that must never be withheld.

`SOPS_AGE_KEY` is stripped unconditionally and cannot be readmitted. It is the
master key to the whole file, and a child that can decrypt makes the useful
guarantee here — that an archive cannot hold a key able to create or revoke
signing material — hollow. If a child of yours needs to decrypt, run the two
commands as siblings rather than nesting them.

**`--only` governs the environment. It does not govern the keychain.** The
keychain this command builds holds every certificate the file has, and the child
is given its path — so a child named only `tokens.marks` can still sign with any
of them. That is deliberate rather than an oversight: a release run legitimately
signs with the App Store certificate, notarizes with Developer ID and signs a
`.pkg` with the installer certificate, and `xcodebuild` takes one `--keychain`.
Splitting them would replace one keychain with a set the child has to choose
between.

Assume it, rather than assuming otherwise. Which certificates the keychain holds
is a different axis from what the child's environment holds, in the same way
`--profile` is — and if it ever needs controlling it wants its own selector
beside `--profile`, not an overload of this one.

### Reading a secrets file without decrypting it

```bash
cux_ship secrets list
```

sops keeps key names in cleartext and encrypts only the values, so the shape of
a file can be read with **no identity and no decryption** — nothing secret can
reach a terminal or a transcript. It lists every credential, names the heading
each sits under, marks any name `secrets exec` would refuse, and ignores the
`sops:` metadata block.

Worth running **before adopting a new version**, since an unrecognized key stops
`secrets exec` outright. It shares its notion of "a credential name" with the
parser that enforces that, which is the only reason it can be trusted: a
pre-flight check that approximates the real rules is one that eventually
disagrees with them.

Three things stop the command rather than being worked around, and each is a
failure that is otherwise **silent**:

- **An unrecognized key.** A misspelt `keystore_pasword` means the credential
  never arrives, Gradle falls through to the debug key, and Play rejects the
  artifact after a full upload.
- **A half-configured group.** Same outcome, from the other direction — which is
  why the groups above are marked "all or none".
- **A missing identity.** Locally that is `~/.config/sops/age/keys.txt`; in CI
  it is the single `SOPS_AGE_KEY` secret, so changing CI provider means moving
  one value.

It reports what it *loaded* rather than what it was asked for, so a credential
that quietly is not in the file is visible before the command runs instead of
three minutes into one.

### Putting a credential in

```bash
cux_ship secrets add certificate distribution dist.p12 --password-file pw
cux_ship secrets add profile ios_appstore app.mobileprovision
cux_ship secrets add api-key upload ~/Downloads/AuthKey_ZHGL57YJVC.p8
cux_ship secrets add token artifact --env ARTIFACT_TOKEN --value-file tok
cux_ship secrets remove token fosshub
```

A name and an artifact, positionally, in that order. **There are no `--p12` /
`--p8` / `--file` flags: the artifact is identified by its contents.** That is
not only shorter to remember — it names the actual mistake when there is one
("this is a PEM private key, not a PKCS#12 bundle; did you mean `add
api-key`?") and it catches what an extension cannot, a correctly named file with
the wrong thing inside, which happens because people rename downloads.

The shape is not perfectly uniform, and the exceptions are stated rather than
discovered: `token` takes no file — its value comes from `--value-file` or
stdin — and `play-account` takes no name.

What it works out so nobody has to type it: the schema path, the base64, the
JSON quoting, and an api key's `id` and `kind`, read back out of Apple's own
`AuthKey_` / `ApiKey_` naming. Those last two are the fields most often got
wrong, and the filename is the only signal `altool` ever gets about which kind
of key it holds. It prints a certificate's subject and expiry and a profile's
uuid, name and platform, so what was added is visible rather than assumed.

Two properties this exists for:

- **Every field lands in one write.** Field-at-a-time writing is what makes
  half-credentials possible, and a half-credential is the dangerous state — a
  keystore with no password does not fail as "you forgot the password", Gradle
  falls through to the debug key. The partial state `secrets exec` refuses is
  now unrepresentable rather than merely reported.
- **It refuses to overwrite.** `--replace` is the rotation verb. Silently
  replacing a signing key is worse than any partial write.

Replacing a *certificate* also names the profiles that were issued against the
one going away, established before the write while the outgoing certificate is
still there to fingerprint:

```
replaced apple.certificates.distribution

** 3 profiles were issued against the certificate you just replaced:
     apple.profiles.ios_appstore
     apple.profiles.ios_appstore_autofill
     apple.profiles.macos_appstore
```

Nothing else reports that coupling, and no artifact carries it — see
`secrets check` below.

#### Building the `.p12` from a keychain

```bash
cux_ship secrets add certificate distribution --from-keychain --team 64ZPC769JY
```

The onboarding path, for when there is an identity in the keychain but no file.
It exports the certificate **and its private key**, builds a `.p12` with a
generated password, stores both, and removes the plaintext. macOS only, and
macOS will ask permission — that prompt has to be granted.

The password is generated rather than accepted here, unlike every other path:
we are building the bundle, nothing ever has to type its password, and one a
human picks is one they reuse.

Three traps it encodes, all of which produce a file that looks fine:

- **It pairs on `localKeyID`, never on `friendlyName`.** macOS labels the
  certificate bag with the certificate's name and the key bag with whatever the
  key was imported as — usually the account holder — so the two share no
  friendlyName. Filtering on it matches the certificate, misses the key, and
  builds a `.p12` that imports without complaint and cannot sign.
- **It matches the certificate kind as well as the team**, because an Apple
  *Development* certificate carries the same `OU=` and would otherwise be
  exported silently, producing builds the App Store refuses.
- **It checks expiry on every candidate.** A keychain accumulates every
  distribution certificate a team has ever held and never sheds the expired
  ones, so "the certificate for this team" is usually several.

Passwords and token values are never command-line arguments — an argument is
visible to every `ps` on the machine — so they arrive by `--password-file`,
`--value-file`, or a prompt. A certificate's password is checked against the
`.p12` **before** anything is written: a bundle stored with the wrong password
is accepted everywhere until something tries to sign with it, which is a full CI
cycle away and does not look like a password problem when it arrives.

### Checking that the credentials work, and agree

```bash
cux_ship secrets check
```

Three levels, each needing strictly more than the last and answering something
the last cannot:

| | needs | answers |
|---|---|---|
| `cux_ship verify` | nothing | are the release inputs sound |
| `cux_ship secrets list` | no identity | what is in the file |
| `cux_ship secrets check` | an identity | do the credentials work, and agree |

Every credential is reported **verified**, **failed**, or **opaque**, and the
exit code is non-zero only for `failed`. Opaque is not a to-do: it is a
credential this tool cannot ever authenticate — a token, whose validity is the
service's to judge — and it must not colour the exit code or the check becomes
something people learn to skip past. There is deliberately **no way for the
secrets file to describe how to verify a token**: a command or URL per token
would make a credential file into something that executes, and the property
worth keeping is that cux_ship cannot be tricked into spending a token it holds.

Run it after adding a credential, after a rotation, and when onboarding a
machine — the moments an upload-time warning is structurally too late for. "Is
anything about to expire" is a different question, continuous, and well served
by a warning during upload.

**The cross-checks are the part nothing else can do.** A single-artifact command
sees one credential; only something holding the whole decrypted file can ask
whether a stored profile still embeds a certificate the file actually holds:

```
apple.profiles.macos_developerid                 verified  expires in 6563d
apple.profiles.macos_developerid ↔ certificates  verified  embeds apple.certificates.developer_id
```

That pairing is not derivable from either artifact alone. The profile above
outlives the certificate inside it by more than a decade, so its own expiry date
says nothing about whether it still holds a usable certificate — and replacing a
certificate silently invalidates every profile issued against it, with nothing
to notice until codesign fails partway through an archive.

The pairing needs `security cms`, so it is macOS-only. On anything else it is
reported as opaque rather than skipped, because a cross-check that quietly does
not run reads exactly like one that ran and found nothing wrong.

### `deps` — sops and age, pinned by hash

`secrets exec` needs a `sops` binary. `deps install` fetches it, and `age`
alongside it, into `.bin/` at the repository root:

```bash
cux_ship deps install     # whatever is pinned and .bin/ lacks
cux_ship deps check       # report only; non-zero if anything is missing
```

Project-local rather than system-wide, so a laptop and a CI runner run the same
bytes and neither needs a package manager. Both are single static Go binaries
with no runtime of their own, which is most of why they were chosen.

**The checksums are not ceremony**: these files are downloaded and then
executed, and a version pin alone only means "some build of 3.13.3". A download
lands in `<name>.part` and is moved into place only once its hash matches, so an
interrupted or tampered fetch is never picked up as installed.

The pins live in this repository, not in yours — bumping them is a `cux_ship`
release rather than an edit in every project. `deps update` re-pins to the
latest upstream releases and rewrites `deps_pins.dart`, so it only works inside
a cux_ship checkout; a consumer gets new pins by moving the ref it depends on.
It is hidden from `--help` for that reason — to every consuming project it is a
documented way to get an error — but it still runs when typed.

**`APPLE_API_ISSUER_ID` is optional, and leaving it out means something.** A
**team** key — Users and Access > Integrations > Team Keys — has an issuer id
and a role that applies to every app in the team; team keys cannot be scoped to
particular apps. An **individual** key is generated by one App Store Connect
user, inherits that user's role *and* their app restrictions, and has no issuer
id at all. Set the variable for the first kind and omit it for the second;
everything downstream follows, including the `sub: user` claim Apple wants and
altool's `--api-key-subject`.

An individual key is how a CI credential is kept from reaching every app you
own. It cannot read the developer portal, though — certificates, identifiers
and profiles are team resources and are refused whatever role the user has — so
`appstore signing` says so and stops rather than reporting an empty account.

**One command needs a stronger key than the rest.** Uploading a build and
editing a listing are App Store Connect operations, and an **App Manager** key
does them. `appstore signing` reads certificates, identifiers and profiles,
which are the developer *portal* — Apple gates that separately and only an
**Admin** key reaches it. A key's role cannot be changed after it is created,
so a team that wants both from one key has to create it as Admin.

An App Manager key is not refused with anything that says so; it gets a 403
naming nothing. `appstore signing` therefore fetches its three collections
independently, reports whichever it could read, names the rest as refused, and
only exits non-zero when all three were, which is a fact about the key rather
than a finding about the account.

### Keeping the guards

`cux_ship_verify` exists because two things worth checking live in the consumer,
not here: the real `CHANGELOG.md`, and the real App Store metadata tree.

As a command:

```bash
cux_ship verify --appstore store/appstore \
  --require-screenshot-type APP_IPHONE_67 \
  --require-screenshot-type APP_IPAD_PRO_3GEN_129
```

Or from your own tests, which is where it earns its keep — it then runs on every
push rather than only at release time. Take
[`cux_ship_verify`](https://pub.dev/packages/cux_ship_verify) as a
`dev_dependency` for this; it has no dependencies of its own:

```dart
import 'package:cux_ship_verify/cux_ship_verify.dart';
import 'package:test/test.dart';

void main() {
  test('every changelog section fits both stores', () {
    expect(checkChangelogFile('CHANGELOG.md'), isEmpty);
  });

  test('the committed store tree would be accepted', () {
    expect(
      checkAppStoreTree(
        'store/appstore',
        requireScreenshotTypes: {'APP_IPHONE_67', 'APP_IPAD_PRO_3GEN_129'},
      ),
      isEmpty,
    );
  });
}
```

Both stores enforce their limits *after* the artifact has been uploaded, which
is far too late. These run offline, need no credentials, and fail on the push
that introduces the problem.

## Flattening screenshots

`cux_ship screenshots flatten` removes the alpha channel from PNG screenshots,
which every simulator and emulator capture carries even when every pixel is
opaque; where the alpha is genuinely opaque the channel is dropped exactly, and
where it is not the image is composited onto a background rather than having the
channel discarded, because discarding it turns a blank capture into a solid
black rectangle.

It also reduces 16 bits per channel to 8 — a 48-bit PNG, which is what a macOS
`--no-chrome` capture writes, and which Play's *"24-bit PNG"* rules out and
Apple has been observed to refuse at ingestion. That rescales rather
than truncating, so the picture survives; below 8 bits is left alone, because no
store has been seen to refuse a palettised screenshot.

It sits at the top level rather than under `appstore` because stripping an alpha
channel is an operation on an image, and because both stores refuse one — Apple
says *"Images can't include alpha channels or transparencies"* and Play asks for
*"JPEG or 24-bit PNG (no alpha)"* in every slot this tool uploads but the app
icon, which is the one image either store wants an alpha channel in. `--check`
reports what would change and exits 2 without rewriting, for CI.

It is deliberately a separate step from publishing: both upload paths *refuse*
an alpha channel rather than silently fixing one, so the corrected file is the
one committed and reviewed.

## Not implemented

- **App preview videos** — `appPreviewSets` and `appPreviews` in the App Store
  Connect API. Screenshots are handled; videos are not. They use the same
  three-step reservation/upload/commit flow as a screenshot asset, so the shape
  is already here, but nothing has been written or tested.
- **Resolving a build number to a commit.** `release finish` takes `--commit`
  (defaulting to HEAD) rather than working out which commit carries a given
  store build number, because how a project allocates build numbers is its own
  business — Hold the Wheel uses `git-buildnumber` and a notes ref. A project
  that wants `--build-number 41` to find its own commit has to resolve it and
  pass `--commit`.

## Development

The repository is a **pub workspace**: `dart pub get` once at the root resolves
both packages against one lockfile, while each still declares ordinary hosted
constraints — which is what lets them be published without any `path:` rewriting
at release time. `dart format`, `dart analyze --fatal-infos` and `dart test` run
per package; CI runs both as a matrix and adds `dart pub publish --dry-run`, so
the metadata that gates a release is checked on every push rather than
discovered at release time.

Lint rules live in the root `analysis_options.yaml`, which both packages
include: `package:lints` rather than `package:flutter_lints`, because none of
this depends on Flutter.

`lib/src/appstore/` and `lib/src/play/` are libraries, not executables. Each
exposes a command enum, a parser builder and a run function, and
`lib/runner.dart` wires them into the tree — so `--bundle-id` is described once,
in the file that reads it, rather than restated by whatever presents it.

## Licence

Apache-2.0. See [LICENSE](LICENSE) and the
[NOTICE](NOTICE).
