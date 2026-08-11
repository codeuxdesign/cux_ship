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
         appstore promote           play promote           screenshots flatten
         appstore builds            play tracks            verify
         appstore versions          play listing           secrets exec
         appstore screenshot-types  play version-code      secrets keys
         appstore build-number                             deps install
         appstore signing                                  deps check
                                                           deps update
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

Everything about it is idempotent — an existing tag is left alone, and a branch
already past the released version is not bumped — because a release is exactly
the situation where something fails half way and gets run again.

```
--commit       what to tag; defaults to HEAD
--version      what was released; defaults to that commit's pubspec.yaml
--branch       where the bump belongs; defaults to main
--no-tag / --no-bump / --no-push / --dry-run
```

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

**If your test suite uses the checks, depend on
[`cux_ship_verify`](https://pub.dev/packages/cux_ship_verify) directly** rather
than reaching them through `package:cux_ship/verify.dart`. That re-export still
works and is kept for compatibility, but it brings the whole CLI — googleapis
included — into the lockfile of every contributor.

### Credentials

**No uploader reads a secrets file or knows what a keychain is.** Every
credential arrives as an environment variable — `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`
for Play, and `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID` and
`APPLE_API_PRIVATE_KEY_PATH` for the App Store — so they work unchanged if those
ever come from Vault, another CI's secret store, or a shell you exported by
hand.

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

### Reading a secrets file without decrypting it

```bash
cux_ship secrets keys
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
which Apple rejects outright and which every simulator and emulator capture
carries even when every pixel is opaque; where the alpha is genuinely opaque the
channel is dropped exactly, and where it is not the image is composited onto a
background rather than having the channel discarded, because discarding it turns
a blank capture into a solid black rectangle.

It sits at the top level rather than under `appstore` because stripping an alpha
channel is an operation on an image. Apple is merely the store that refuses one.
`--check` reports what would change and exits 2 without rewriting, for CI.

It is deliberately a separate step from publishing: `cux_ship_appstore` *refuses*
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
