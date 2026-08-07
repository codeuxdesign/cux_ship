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
| `cux_ship_appstore` | App Store Connect. A hand-written REST client — ES256 JWT auth, the three-step asset upload, screenshot and listing metadata, TestFlight notes, promotion. Executables: `asc_upload`, `flatten_screenshots`. |
| `cux_ship_play` | Google Play, on `googleapis`. Uploads a bundle to a track, publishes the listing, promotes between tracks. Executable: `play_upload`. |
| `cux_ship_notes` | The `CHANGELOG.md` parser both uploaders share. No dependencies at all. |
| `cux_ship_verify` | Offline checks a consuming repository runs against **its own** changelog and store tree, from its own test suite. |

## Consuming it

Add one package to your project that depends on the uploaders, so there is a
single place to bump the ref:

```yaml
# tool/cux_ship/pubspec.yaml
name: my_app_ship
publish_to: 'none'
environment:
  sdk: ^3.12.2

dependencies:
  cux_ship_appstore:
    git:
      url: https://github.com/codeuxdesign/cux_ship.git
      path: cux_ship_appstore
      ref: v1.0.0
  cux_ship_play:
    git:
      url: https://github.com/codeuxdesign/cux_ship.git
      path: cux_ship_play
      ref: v1.0.0
```

`cux_ship_notes` arrives transitively — the uploaders depend on it by relative
`path:` *within* this repository, and pub resolves that correctly through a git
dependency. Do not depend on it directly.

Use the **HTTPS** URL rather than the SSH form. This repository is public, so
HTTPS needs no credentials anywhere, including in CI; an SSH URL would put an
authentication step back into a pipeline that does not otherwise need one.

Then, from `tool/cux_ship`:

```bash
dart run cux_ship_appstore:asc_upload --help
dart run cux_ship_play:play_upload --help
dart run cux_ship_appstore:flatten_screenshots --help
```

The package names carry the namespace, so the executables keep short names.

### Credentials

Nothing here reads a secrets file or knows what a keychain is. Every credential
arrives as an environment variable —
`GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` for Play, and `APPLE_API_KEY_ID`,
`APPLE_API_ISSUER_ID` and `APPLE_API_PRIVATE_KEY_PATH` for the App Store — and
how they get there is the consuming project's business.

Some error messages name the script that sets them in the project this came
from (`tool/with-secrets.sh`). Read those as an example of the arrangement
rather than a requirement.

### Keeping the guards

`cux_ship_verify` exists because two things worth checking live in the consumer,
not here: the real `CHANGELOG.md`, and the real App Store metadata tree. Call it
from your own tests.

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

`flatten_screenshots` removes the alpha channel from PNG screenshots, which
Apple rejects outright and which every simulator and emulator capture carries
even when every pixel is opaque; where the alpha is genuinely opaque the channel
is dropped exactly, and where it is not the image is composited onto a
background rather than having the channel discarded, because discarding it turns
a blank capture into a solid black rectangle.

It is deliberately a separate step from publishing: `cux_ship_appstore` *refuses*
an alpha channel rather than silently fixing one, so the corrected file is the
one committed and reviewed.

## Not implemented

- **App preview videos** — `appPreviewSets` and `appPreviews` in the App Store
  Connect API. Screenshots are handled; videos are not. They use the same
  three-step reservation/upload/commit flow as a screenshot asset, so the shape
  is already here, but nothing has been written or tested.

## Development

Each package is independent: `dart pub get`, `dart format`, `dart analyze
--fatal-infos`, `dart test`. CI runs all four as a matrix. Lint rules live in
the root `analysis_options.yaml`, which every package includes;
`package:lints` rather than `package:flutter_lints`, because none of this
depends on Flutter.

`cux_ship_play` has no tests — its logic moved into `cux_ship_notes`, and what
is left is API calls.

## Licence

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
