// SPDX-License-Identifier: Apache-2.0
import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:cux_ship/src/asc_platforms.dart';
import 'package:test/test.dart';

void main() {
  group('ascPlatforms and AscPlatform', () {
    // There are three spellings of this set: the const, which `--platform`'s
    // `allowed:` and the config reader validate against, and `AscPlatform`,
    // which *resolves* a name once it has been admitted. The const governs what
    // is admitted; the enum governs what is understood; nothing else holds them
    // together.
    //
    // Get them out of step and the failure is not a validation error. Adding a
    // platform to the const alone makes the parser accept `--platform tvos` and
    // the config accept `screenshots: tvos:`, and then `byName` throws an
    // ArgumentError — an uncaught crash with a stack trace, in a consumer's
    // release rather than here.
    //
    // A test rather than deriving one from the other, deliberately:
    // `AscPlatform` lives in `app_store.dart`, which imports the API client, so
    // making the const derive from the enum would pull googleapis into the
    // config reader — the coupling `asc_platforms.dart` exists to avoid.
    test('admit exactly what the enum understands', () {
      expect(
        ascPlatforms.toSet(),
        AscPlatform.values.map((p) => p.name).toSet(),
      );
    });

    test('every admitted name resolves', () {
      for (final name in ascPlatforms) {
        expect(() => AscPlatform.byName(name), returnsNormally, reason: name);
      }
    });

    test('a name the const does not admit does not resolve either', () {
      expect(() => AscPlatform.byName('tvos'), throwsArgumentError);
    });
  });
}
