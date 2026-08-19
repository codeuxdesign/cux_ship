// SPDX-License-Identifier: Apache-2.0
//
// The one case that matters here is that the branch refspec survives. A clone
// that can fetch build numbers and not branches is worse than one that never
// learned about build numbers at all, and `git config <key> <value>` on a
// multi-valued key is exactly how that happens.
import 'dart:io';

import 'package:cux_ship/src/provenance.dart';
import 'package:cux_ship/src/release.dart' show Git;
import 'package:test/test.dart';

late Directory _root;
late Git _git;

List<String> _fetchRefspecs() => _git
    .run(['config', '--get-all', 'remote.origin.fetch'], allowFailure: true)
    .split('\n')
    .where((line) => line.isNotEmpty)
    .toList();

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cux_ship_refspecs');
    _git = Git(_root.path);
    _git.run(['init', '-q', '-b', 'main']);
    _git.run(['remote', 'add', 'origin', 'https://example.invalid/repo.git']);
  });

  tearDown(() => _root.deleteSync(recursive: true));

  test('adds both refspecs and keeps the branch one', () {
    expect(_fetchRefspecs(), ['+refs/heads/*:refs/remotes/origin/*']);

    final log = configureBuildnumberRefspecs(_git);

    expect(log, everyElement(startsWith('added: ')));
    expect(
      _fetchRefspecs(),
      containsAll(<String>[
        '+refs/heads/*:refs/remotes/origin/*',
        ...buildnumberFetchRefspecs,
      ]),
      reason: 'losing the branch refspec would break every ordinary fetch',
    );
  });

  test('running it twice changes nothing', () {
    configureBuildnumberRefspecs(_git);
    final after = _fetchRefspecs();

    final log = configureBuildnumberRefspecs(_git);

    expect(log, everyElement(startsWith('already configured: ')));
    expect(_fetchRefspecs(), after);
  });

  test('a dry run reports and writes nothing', () {
    final before = _fetchRefspecs();

    final log = configureBuildnumberRefspecs(_git, dryRun: true);

    expect(log, everyElement(startsWith('would add: ')));
    expect(_fetchRefspecs(), before);
  });

  test('a named remote is honored', () {
    _git.run(['remote', 'add', 'upstream', 'https://example.invalid/up.git']);

    configureBuildnumberRefspecs(_git, remote: 'upstream');

    expect(
      _git.run(['config', '--get-all', 'remote.upstream.fetch']),
      contains('refs/buildnumbers'),
    );
    expect(_fetchRefspecs(), [
      '+refs/heads/*:refs/remotes/origin/*',
    ], reason: 'origin must be untouched when another remote was named');
  });

  test('the notes ref is not a glob', () {
    // `refs/notes/*` would force every notes ref, including refs/notes/commits,
    // which is somebody else's data. That mistake shipped once upstream and
    // rolled back notes a colleague had pushed, silently and with exit 0.
    expect(
      buildnumberFetchRefspecs,
      isNot(contains(startsWith('+refs/notes/*'))),
    );
    expect(
      buildnumberFetchRefspecs.singleWhere((r) => r.contains('notes')),
      '+refs/notes/buildnumbers:refs/notes/buildnumbers',
    );
  });
}
