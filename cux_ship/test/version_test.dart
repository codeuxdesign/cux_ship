// SPDX-License-Identifier: Apache-2.0
//
// `cuxShipVersion` is hand-maintained, so this is what keeps it honest.
//
// Without it the constant drifts the first time someone bumps `pubspec.yaml`
// and does not think to look in `lib/src/`, and then every manifest written
// afterwards attributes itself to a version that never existed. Nothing would
// fail — a wrong producer version reads exactly like a right one, which is why
// it needs a test rather than care.
import 'dart:io';

import 'package:cux_ship/src/version.dart';
import 'package:test/test.dart';

void main() {
  test('cuxShipVersion is what pubspec.yaml declares', () {
    final pubspec = ['pubspec.yaml', 'cux_ship/pubspec.yaml']
        .map(File.new)
        .firstWhere(
          (f) => f.existsSync(),
          orElse: () => throw StateError(
            'cannot find pubspec.yaml from ${Directory.current.path} — and a '
            'version test that cannot find the version would pass by default',
          ),
        );

    final declared = RegExp(
      r'^version:\s*(\S+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec.readAsStringSync())?.group(1);

    expect(declared, isNotNull, reason: '${pubspec.path} has no version: line');
    expect(
      cuxShipVersion,
      declared,
      reason:
          'lib/src/version.dart says $cuxShipVersion and ${pubspec.path} says '
          '$declared. Every manifest written between the bump and this test '
          'running names the wrong producer.',
    );
  });
}
