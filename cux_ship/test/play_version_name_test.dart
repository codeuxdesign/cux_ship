// SPDX-License-Identifier: Apache-2.0
//
// A version name is never a build number.
//
// This existed as `opt('version-name') ?? buildNumber ?? defaults.versionName`,
// which made the build number the version name whenever the flag was omitted —
// Play would have taken a release named "65 (65)", and the changelog lookup
// asked for a section headed 65 and refused the upload saying the CHANGELOG had
// none. Every caller passed the flag, so the branch was unreachable until a
// consumer moved to `--manifest`, and then it failed on a real upload rather
// than in anything here.
//
// The resolution is a function so that this file can exist at all. Its
// signature has nowhere to put a build number, so the defect is not merely
// fixed — it is unspellable.
import 'package:cux_ship/src/play/cli.dart';
import 'package:test/test.dart';

void main() {
  test('an explicit --version-name wins', () {
    expect(
      resolveVersionName(explicit: '1.2.0', fromManifest: '1.1.0'),
      '1.2.0',
      reason: 'a typed flag beats inference, as everywhere else here',
    );
  });

  test('the manifest supplies it when the flag is absent', () {
    // The path that was broken: this is what --manifest exists to do.
    expect(resolveVersionName(fromManifest: '1.1.0'), '1.1.0');
  });

  test('neither source gives the empty string, not a build number', () {
    // Empty is the caller's problem to report; the one thing it must not be is
    // some other field that happened to be in scope.
    expect(resolveVersionName(), '');
  });

  test('the signature cannot be handed a build number', () {
    // Not an assertion about behavior — a statement about the type. If someone
    // reintroduces a build-number fallback they have to add a parameter to do
    // it, which is a visible change to a function whose doc comment says why
    // that is wrong. Kept as a test so the reasoning is read when it matters.
    expect(
      resolveVersionName(explicit: null, fromManifest: '1.1.0'),
      isNot('65'),
      reason: 'a build number is a different kind of fact and never a fallback',
    );
  });
}
