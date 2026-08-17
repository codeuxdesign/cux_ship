// SPDX-License-Identifier: Apache-2.0
//
// `upload` takes one artifact and two platforms, so the option is named for
// what it is rather than for one platform's file extension.

import 'package:cux_ship/src/appstore/cli.dart';
import 'package:test/test.dart';

void main() {
  group('the artifact option', () {
    final parser = buildAscParser(AscCommand.upload);

    // Reported from a real macOS release: `--platform macos` is first-class,
    // but the only way to pass the .pkg was a flag called `--ipa`, and `--pkg`
    // — which is what anyone would reach for — failed with "no such option".
    // It refused rather than uploading nothing, which is the good version of
    // that failure, but it should not have refused at all.
    test('accepts --pkg, --ipa and --artifact alike', () {
      for (final spelling in ['--artifact', '--ipa', '--pkg']) {
        expect(
          parser.parse([spelling, 'dist/app.pkg']).option('artifact'),
          'dist/app.pkg',
          reason: '$spelling should reach the same option',
        );
      }
    });

    // `promote` points an App Store version at a build TestFlight already has,
    // so it builds and uploads nothing. Taking no artifact is the whole point,
    // and it is enforced by the parser rather than by a validation error.
    test('promote takes no artifact at all', () {
      expect(
        () => buildAscParser(AscCommand.promote).parse(['--artifact', 'x.ipa']),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
