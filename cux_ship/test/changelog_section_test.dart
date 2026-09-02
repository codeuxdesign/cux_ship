// SPDX-License-Identifier: Apache-2.0
//
// The one case that must fail is the absent section, and the one that must
// not is the empty one — the difference between forgetting and deciding.
import 'dart:io';

import 'package:cux_ship/src/changelog_section.dart';
import 'package:test/test.dart';

late Directory _root;

String _changelog(String contents) {
  final path = '${_root.path}/CHANGELOG.md';
  File(path).writeAsStringSync(contents);
  return path;
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cux_ship_changelog_section');
  });

  tearDown(() => _root.deleteSync(recursive: true));

  test('a version with no section is a problem that names it', () {
    final path = _changelog('# Changelog\n\n## 1.0.0\n\n- Something\n');

    final problem = changelogSectionProblem(changelog: path, version: '1.0.1');

    expect(problem, isNotNull);
    expect(problem!.where, '$path § 1.0.1');
    expect(problem.message, contains('no section'));
    expect(problem.message, contains('"## 1.0.1"'));
  });

  test('a version with a section is fine', () {
    final path = _changelog(
      '# Changelog\n\n## 1.0.1\n\n- New\n\n## 1.0.0\n\n- Something\n',
    );

    expect(changelogSectionProblem(changelog: path, version: '1.0.1'), isNull);
  });

  test('an empty section is a decision, not a problem', () {
    // What `release finish` inserts, and what "nothing user-visible changed"
    // looks like. The uploaders fall back through it; so does this.
    final path = _changelog(
      '# Changelog\n\n## 1.0.1\n\n## 1.0.0\n\n- Something\n',
    );

    expect(changelogSectionProblem(changelog: path, version: '1.0.1'), isNull);
  });

  test('a bracketed, dated heading still counts', () {
    final path = _changelog(
      '# Changelog\n\n## [1.0.1] - 2026-09-02\n\n- New\n',
    );

    expect(changelogSectionProblem(changelog: path, version: '1.0.1'), isNull);
  });

  test('a missing file is reported elsewhere, not twice', () {
    expect(
      changelogSectionProblem(
        changelog: '${_root.path}/absent.md',
        version: '1.0.1',
      ),
      isNull,
    );
  });
}
