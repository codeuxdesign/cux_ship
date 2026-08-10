# cux_ship

Release tooling for shipping a Flutter or Dart app to the App Store and Google
Play: upload an artifact, publish the store listing, promote a build that is
already up, and turn a `CHANGELOG.md` into the notes each store shows.

Extracted from [Hold the Wheel](https://holdthewheel.codeux.design) with its
history intact — `git log --follow` on any file here reaches back past the
extraction. Most comments in this code record a specific incident, and that is
the point of keeping the history: `git blame` is usually the only way to recover
why a line exists.

| Package | What it is |
|---|---|
| **`cux_ship`** | **The command.** The only package a consumer depends on. |
| `cux_ship_appstore` | App Store Connect. A hand-written REST client — ES256 JWT auth, the three-step asset upload, screenshot and listing metadata, TestFlight notes, promotion. |
| `cux_ship_play` | Google Play, on `googleapis`. Uploads a bundle to a track, publishes the listing, promotes between tracks. |
| `cux_ship_notes` | The `CHANGELOG.md` parser both uploaders share. No dependencies at all. |
| `cux_ship_verify` | Offline checks a consuming repository runs against **its own** changelog and store tree, from its own test suite. |

## The command

```
cux_ship appstore upload            play upload            release finish
         appstore promote           play promote           screenshots flatten
         appstore builds            play tracks            verify
         appstore versions          play listing
         appstore screenshot-types  play version-code
         appstore build-number
         appstore signing
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

One dependency:

```yaml
# tool/cux_ship/pubspec.yaml
name: my_app_ship
publish_to: 'none'
environment:
  sdk: ^3.12.2

dependencies:
  cux_ship:
    git:
      url: https://github.com/codeuxdesign/cux_ship.git
      path: cux_ship
      ref: v1.2.2
```

Everything else arrives transitively. That is not only tidiness: pub treats a
git dependency's ref as part of its identity and does not resolve a tag to a
commit before comparing, so a package named both directly (at a tag) and
transitively (at the commit a relative `path:` resolved to) is an unsolvable
conflict. One direct dependency has no second identity to collide with, which is
what lets you pin a readable tag instead of a SHA.

Use the **HTTPS** URL rather than the SSH form. This repository is public, so
HTTPS needs no credentials anywhere, including in CI; an SSH URL would put an
authentication step back into a pipeline that does not otherwise need one.

Then, from `tool/cux_ship`:

```bash
dart run cux_ship --help
```

Or install it once and drop the ceremony entirely:

```bash
dart pub global activate --source git https://github.com/codeuxdesign/cux_ship.git --git-path cux_ship
```

### Credentials

Nothing here reads a secrets file or knows what a keychain is. Every credential
arrives as an environment variable —
`GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` for Play, and `APPLE_API_KEY_ID`,
`APPLE_API_ISSUER_ID` and `APPLE_API_PRIVATE_KEY_PATH` for the App Store — and
how they get there is the consuming project's business.

Some error messages name the script that sets them in the project this came
from (`tool/with-secrets.sh`). Read those as an example of the arrangement
rather than a requirement.

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
push rather than only at release time:

```dart
import 'package:cux_ship/verify.dart';
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

Each package is independent: `dart pub get`, `dart format`, `dart analyze
--fatal-infos`, `dart test`. CI runs all five as a matrix. Lint rules live in
the root `analysis_options.yaml`, which every package includes;
`package:lints` rather than `package:flutter_lints`, because none of this
depends on Flutter.

`cux_ship_play` has no tests — its logic moved into `cux_ship_notes`, and what
is left is API calls.

The store packages are libraries, not executables. Each exposes a command enum,
a parser builder and a run function; `cux_ship/lib/runner.dart` wires them into
the tree. So `--bundle-id` is described once, in the package that reads it,
rather than restated by whatever presents it.

## Licence

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
