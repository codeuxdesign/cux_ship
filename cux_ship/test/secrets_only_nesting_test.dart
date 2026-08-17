// SPDX-License-Identifier: Apache-2.0
//
// The one property `--only` exists for that a unit test cannot reach: what a
// *child process* actually receives.
//
// This is a regression test with a specific history. `--only` shipped into the
// working tree filtering *placement* — it declined to place what was not named,
// and never removed what a parent had already put in the environment. Then,
// once removal was added, `Process.start` merged the filtered map back over the
// parent's environment and restored everything, because this command did not
// pass `includeParentEnvironment: false`.
//
// Both bugs were live while 258 unit tests were green, including sixteen on the
// selector itself. Those tests establish that resolution is correct; nothing
// short of spawning a process establishes that a filtered environment survives
// into one. That is the gap this file exists to close.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

late Directory _root;

/// The real CLI, so the test exercises the path a caller does.
///
/// Found by walking up rather than resolved against the working directory: this
/// suite is run both from the package and from the workspace root, and a
/// relative path is correct in exactly one of those.
final _binary = _findBinary();

String _findBinary() {
  for (
    var dir = Directory.current;
    dir.parent.path != dir.path;
    dir = dir.parent
  ) {
    final candidate = File('${dir.path}/bin/cux_ship.dart');
    if (candidate.existsSync()) {
      return candidate.path;
    }
    final nested = File('${dir.path}/cux_ship/bin/cux_ship.dart');
    if (nested.existsSync()) {
      return nested.path;
    }
  }
  throw StateError('cannot find bin/cux_ship.dart from ${Directory.current}');
}

void _write(String path, String contents) {
  final file = File('${_root.path}/$path')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(contents);
  if (path.startsWith('.bin/')) {
    Process.runSync('chmod', ['+x', file.path]);
  }
}

String _b64(String value) => base64.encode(utf8.encode(value));

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cux_ship_nesting_test');
    // `cat "$2"` — the file is its own plaintext, which is all this needs.
    _write('.bin/sops', '#!/bin/sh\ncat "\$2"\n');
    _write('pubspec.yaml', 'name: fixture\nenvironment:\n  sdk: ^3.0.0\n');
    _write(
      'secrets/release.yaml',
      'tokens:\n'
          '  wanted:\n'
          '    env: WANTED_TOKEN\n'
          '    value: yes-please\n'
          '  unwanted:\n'
          '    env: UNWANTED_TOKEN\n'
          '    value: should-not-arrive\n'
          'ssh_keys:\n'
          '  deploy:\n'
          '    env: DEPLOY_KEY_PATH\n'
          '    base64: ${_b64('a key')}\n',
    );
  });

  tearDown(() => _root.deleteSync(recursive: true));

  /// Runs `secrets exec` with [only], under a parent that already exports
  /// [inherited] — which is what an outer wrapper looks like from in here.
  ///
  /// The child writes its own environment to a file rather than stdout, because
  /// the command inherits stdio and there is nothing to capture.
  Map<String, String> childEnvironment({
    required List<String> only,
    Map<String, String> inherited = const {},
  }) {
    final flags = only.map((o) => '--only $o').join(' ');
    final result = Process.runSync(
      'sh',
      [
        '-c',
        'exec dart run $_binary secrets exec $flags -- '
            'sh -c "env > seen.txt"',
      ],
      workingDirectory: _root.path,
      environment: inherited,
    );
    expect(result.exitCode, 0, reason: 'the run failed: ${result.stderr}');
    final seen = <String, String>{};
    for (final line in File('${_root.path}/seen.txt').readAsLinesSync()) {
      final cut = line.indexOf('=');
      if (cut > 0) {
        seen[line.substring(0, cut)] = line.substring(cut + 1);
      }
    }
    return seen;
  }

  test('a named credential reaches the child', () {
    final seen = childEnvironment(only: ['tokens.wanted']);
    expect(seen['WANTED_TOKEN'], 'yes-please');
  });

  test('an unnamed credential does not', () {
    final seen = childEnvironment(only: ['tokens.wanted']);
    expect(seen, isNot(contains('UNWANTED_TOKEN')));
    expect(seen, isNot(contains('DEPLOY_KEY_PATH')));
  });

  // **The regression.** A variable the parent already exported, belonging to a
  // credential this run did not name, must not reach the child. Filtering only
  // what this process places leaves it; so does removing it from the map while
  // letting `Process.start` merge the parent's environment back over the top.
  // Both of those shipped, and both look correct at every line.
  test('a credential an outer wrapper already placed is removed', () {
    final seen = childEnvironment(
      only: ['tokens.wanted'],
      inherited: {
        ...Platform.environment,
        'UNWANTED_TOKEN': 'placed-by-an-outer-wrapper',
        'DEPLOY_KEY_PATH': '/tmp/placed-by-an-outer-wrapper',
      },
    );
    expect(
      seen,
      isNot(contains('UNWANTED_TOKEN')),
      reason: 'the outer wrapper\'s value survived the inner --only',
    );
    expect(seen, isNot(contains('DEPLOY_KEY_PATH')));
    expect(seen['WANTED_TOKEN'], 'yes-please');
  });

  // The filter removes what cux_ship placed, not the ambient environment. One
  // project's build authenticates to git through an agent socket cux_ship never
  // placed, and an empty selection must not break it.
  test('the ambient environment is left alone', () {
    final seen = childEnvironment(
      only: ['tokens.wanted'],
      inherited: {...Platform.environment, 'SSH_AUTH_SOCK': '/tmp/agent.sock'},
    );
    expect(seen['SSH_AUTH_SOCK'], '/tmp/agent.sock');
    expect(seen, contains('PATH'));
  });
}
