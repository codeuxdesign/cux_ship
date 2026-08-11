# cux_ship_verify

Catches what the App Store and Google Play would otherwise reject **after** you
have uploaded — a release note over the cap, a screenshot carrying an alpha
channel, a missing iPad set, a listing field a few characters too long.

Runs offline, needs no credentials, and has **no dependencies at all**. That
last part is the point: this belongs in your `dev_dependencies` so the checks
run in your own test suite on every push, and what it drags into a
contributor's lockfile matters.

```yaml
dev_dependencies:
  cux_ship_verify: ^1.6.0
```

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

**Why a test rather than a release-time check.** Both stores enforce these
limits after the artifact has been transferred and processed, which is far too
late and often days later. A test fails on the push that introduces the problem,
which is when the person who caused it is still looking at it.

`requireScreenshotTypes` is worth setting deliberately: a universal app needs an
iPad set as well as an iPhone one, and Apple refuses the *submission* rather
than the upload — so an absent set is invisible until review.

## What else is in here

Two libraries that are the model these checks are built on, public because the
uploading half of [`cux_ship`](https://pub.dev/packages/cux_ship) reads them too:

| Library | What it is |
|---|---|
| `package:cux_ship_verify/release_notes.dart` | The `CHANGELOG.md` parser. Finds a version's section and renders it as each store wants it — which is not the same text, because the filtering differs and the caps differ (Play 500, App Store 4000). |
| `package:cux_ship_verify/metadata.dart` | Loads and fully validates a `store/appstore/` tree. The standing rule is **present means owned**: a file that exists replaces what App Store Connect holds, one that does not is left alone. That is what makes a partial tree safe to keep in a repository. |

## Also

`cux_ship verify` in the [`cux_ship`](https://pub.dev/packages/cux_ship) CLI runs
the same checks from the command line, for the moment before there is a test
suite to put them in.

## Licence

Apache-2.0. See [LICENSE](LICENSE) and the
[repository](https://github.com/codeuxdesign/cux_ship).
