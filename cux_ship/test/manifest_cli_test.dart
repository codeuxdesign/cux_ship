// SPDX-License-Identifier: Apache-2.0
//
// `manifest write` end to end, through the binary a build script actually
// invokes.
//
// The unit tests beside this one cover what gets written. What they cannot
// cover is the thing that has broken this package before: a command that dies
// in argument handling and never reaches its body. That failure is invisible to
// a test that calls the run function directly, and it shipped once — see
// subcommand_smoke_test.dart. A build script is the least forgiving caller
// there is, because nobody reads its output until the upload weeks later.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The entrypoint, resolved against both layouts — CI runs `dart test` from the
/// package directory, a developer runs it from the workspace root, and a path
/// that does not resolve would make every case here pass while running nothing.
final String _cli = () {
  for (final candidate in ['bin/cux_ship.dart', 'cux_ship/bin/cux_ship.dart']) {
    final file = File(candidate);
    if (file.existsSync()) {
      return file.absolute.path;
    }
  }
  throw StateError(
    'cannot find bin/cux_ship.dart from ${Directory.current.path}',
  );
}();

late Directory _dist;

const _sha = 'd9c394bd9c394bd9c394bd9c394bd9c394bd9c39';

String _artifact() {
  final path = '${_dist.path}/how-it-went-1.1.0-53.aab';
  File(path).writeAsStringSync('a signed bundle, pretend');
  return path;
}

ProcessResult _run(List<String> args) => Process.runSync(
  Platform.resolvedExecutable,
  ['--enable-asserts', _cli, 'manifest', 'write', ...args],
  workingDirectory: _dist.path,
);

/// The arguments a well-formed invocation carries, so a case can drop one.
List<String> _args(String artifact) => [
  '--artifact',
  artifact,
  '--platform',
  'android',
  '--format',
  'aab',
  '--version-name',
  '1.1.0',
  '--build-number',
  '53',
  '--git-sha',
  _sha,
  '--no-dirty',
];

void main() {
  setUp(() => _dist = Directory.systemTemp.createTempSync('cux_ship_mcli'));
  tearDown(() => _dist.deleteSync(recursive: true));

  test('writes a manifest and reports what it wrote', () {
    final artifact = _artifact();
    final result = _run(_args(artifact));

    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(
      File('$artifact.manifest.json').existsSync(),
      isTrue,
      reason: 'the sidecar goes beside the artifact',
    );

    // Effective configuration, not intended: the line has to carry enough to
    // answer "which commit, which bytes" from a build log alone.
    final output = '${result.stdout}';
    expect(output, contains('1.1.0 (53)'));
    expect(output, contains('android/aab'));
    expect(output, contains(_sha.substring(0, 7)));
    expect(output, contains('sha256:'));
  });

  test('what it writes is what this package reads back', () {
    final artifact = _artifact();
    _run(_args(artifact));

    final read =
        jsonDecode(File('$artifact.manifest.json').readAsStringSync()) as Map;
    expect(read['schema'], 2);
    expect(read['gitSha'], _sha);
    expect(read['producer'], {'name': 'cux_ship', 'version': isNotEmpty});
    expect(
      read['builtAt'],
      isNotNull,
      reason: 'omitted means now, not means absent',
    );
  });

  test('a missing --dirty is refused rather than assumed clean', () {
    // The one default that must not exist. A build script that forgot the flag
    // would certify every dirty build as clean, and nothing downstream could
    // tell the difference — which is the exact shape of defect the manifest is
    // supposed to remove, reintroduced by the tool that writes it.
    final args = _args(_artifact())..remove('--no-dirty');
    final result = _run(args);

    expect(result.exitCode, isNot(0));
    expect('${result.stderr}', contains('--dirty or --no-dirty'));
  });

  test('a missing required argument names itself', () {
    final args = _args(_artifact());
    args.removeRange(
      args.indexOf('--build-number'),
      args.indexOf('--build-number') + 2,
    );
    final result = _run(args);

    expect(result.exitCode, isNot(0));
    expect('${result.stderr}', contains('--build-number'));
  });

  test('key=value options land in their own blocks', () {
    final artifact = _artifact();
    final result = _run([
      ..._args(artifact),
      '--toolchain',
      'flutter=3.47.0',
      '--toolchain',
      'dart=3.13.0',
      '--x',
      'gradleTask=bundlePlaystoreRelease',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');

    final read =
        jsonDecode(File('$artifact.manifest.json').readAsStringSync()) as Map;
    expect(read['toolchain'], {'flutter': '3.47.0', 'dart': '3.13.0'});
    expect(read['x'], {'gradleTask': 'bundlePlaystoreRelease'});
  });

  test('a malformed key=value is refused, not silently dropped', () {
    final result = _run([..._args(_artifact()), '--toolchain', 'flutter']);

    expect(result.exitCode, isNot(0));
    expect('${result.stderr}', contains('key=value'));
  });

  test('an unassigned build number is recorded as such', () {
    final artifact = _artifact();
    _run([..._args(artifact), '--no-build-number-assigned']);

    final read =
        jsonDecode(File('$artifact.manifest.json').readAsStringSync()) as Map;
    expect(read['buildNumberAssigned'], isFalse);
  });

  group('--derived-from', () {
    /// A parent manifest and its artifact, as a repackager finds them after
    /// downloading both.
    String parent({String bytes = 'the linux tarball'}) {
      final artifact = '${_dist.path}/authpass-1.9.15.tar.gz';
      File(artifact).writeAsStringSync(bytes);
      _run([
        '--artifact',
        artifact,
        '--platform',
        'linux',
        '--format',
        'tar.gz',
        '--version-name',
        '1.9.15',
        '--build-number',
        '2155',
        '--git-sha',
        _sha,
        '--no-dirty',
        '--built-at',
        '2026-08-21T09:00:00Z',
      ]);
      return '$artifact.manifest.json';
    }

    String child(String parentManifest, {String name = 'app_1.9.15.deb'}) {
      final artifact = '${_dist.path}/$name';
      File(artifact).writeAsStringSync('repackaged $name');
      final result = _run([
        '--artifact',
        artifact,
        '--platform',
        'linux',
        '--format',
        'deb',
        '--derived-from',
        parentManifest,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      return '$artifact.manifest.json';
    }

    test('build facts are hoisted, so none are retyped', () {
      // build-manifest.md: inherited facts go to top level *always*, because a
      // reader that knows nothing about derivation must still get true answers
      // from the fields it already reads.
      final read = jsonDecode(File(child(parent())).readAsStringSync()) as Map;

      expect(read['gitSha'], _sha);
      expect(read['versionName'], '1.9.15');
      expect(read['buildNumber'], 2155);
      expect(read['dirty'], isFalse);
    });

    test("the chain is [parent] + the parent's own, nearest first", () {
      final deb = child(parent());
      final snap = child(deb, name: 'app_1.9.15.snap');
      final read = jsonDecode(File(snap).readAsStringSync()) as Map;

      expect(
        (read['derivedFrom'] as List).cast<Map<String, dynamic>>().map(
          (e) => e['artifact'],
        ),
        ['app_1.9.15.deb', 'authpass-1.9.15.tar.gz'],
        reason: 'a flat ordered list is what survives multi-step repackaging',
      );
      expect(
        read['gitSha'],
        _sha,
        reason: 'two hops on, the built commit is still the tarball\'s',
      );
    });

    test('the entry records the digest of the bytes consumed', () {
      final parentManifest = parent();
      final parentRead =
          jsonDecode(File(parentManifest).readAsStringSync()) as Map;
      final read =
          jsonDecode(File(child(parentManifest)).readAsStringSync()) as Map;

      expect(
        (read['derivedFrom'] as List)
            .cast<Map<String, dynamic>>()
            .first['sha256'],
        parentRead['sha256'],
      );
    });

    test('a parent whose bytes have changed is refused', () {
      // The whole value of a derivation record is the digest of what was
      // actually consumed. A tarball and its sidecar upload non-atomically, so
      // a fetch can straddle the two — this turns that into a loud failure
      // rather than a chain that records a lie.
      final parentManifest = parent();
      File(
        '${_dist.path}/authpass-1.9.15.tar.gz',
      ).writeAsStringSync('truncated in transit');

      final artifact = '${_dist.path}/app.deb';
      File(artifact).writeAsStringSync('x');
      final result = _run([
        '--artifact',
        artifact,
        '--platform',
        'linux',
        '--format',
        'deb',
        '--derived-from',
        parentManifest,
      ]);

      expect(result.exitCode, isNot(0));
      expect('${result.stderr}', contains('does not match the manifest'));
    });

    test('an explicit flag still beats what the parent says', () {
      final artifact = '${_dist.path}/app.deb';
      File(artifact).writeAsStringSync('x');
      _run([
        '--artifact',
        artifact,
        '--platform',
        'linux',
        '--format',
        'deb',
        '--derived-from',
        parent(),
        '--version-name',
        '2.0.0',
      ]);
      final read =
          jsonDecode(File('$artifact.manifest.json').readAsStringSync()) as Map;

      expect(read['versionName'], '2.0.0');
      expect(read['gitSha'], _sha, reason: 'the rest is still inherited');
    });

    test('without a parent, the required flags are still required', () {
      final artifact = _artifact();
      final result = _run([
        '--artifact',
        artifact,
        '--platform',
        'linux',
        '--format',
        'deb',
        '--no-dirty',
      ]);

      expect(result.exitCode, isNot(0));
      expect(
        '${result.stderr}',
        contains('--version-name'),
        reason:
            'inheritance is what --derived-from buys; without one the flags '
            'are as required as they ever were',
      );
    });
  });

  test('--help reaches the parser rather than crashing', () {
    // What subcommand_smoke_test.dart guards for every other command: a
    // subcommand that dies in argument handling is broken for everyone,
    // whatever it would have gone on to do.
    final result = _run(['--help']);
    final output = '${result.stdout}${result.stderr}';

    for (final phrase in [
      'Could not find an option named',
      'Invalid argument(s)',
      'Unhandled exception',
    ]) {
      expect(output, isNot(contains(phrase)), reason: output);
    }
    expect(output, contains('--git-sha'));
  });
}
