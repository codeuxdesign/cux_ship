// SPDX-License-Identifier: Apache-2.0
//
// The failure this refuses is one nobody sees happen: text that was never
// reviewed reaching a store because it happened to be on disk when a release
// ran. So the cases are the ones where it must refuse, and the two where it
// must not — a clean file, and no repository at all.
import 'dart:io';

import 'package:cux_ship/src/notes_source.dart';
import 'package:cux_ship/src/release.dart' show Git, ReleaseException;
import 'package:test/test.dart';

late Directory _root;
late Git _git;

String _changelog(String text) {
  final path = '${_root.path}/CHANGELOG.md';
  File(path).writeAsStringSync(text);
  return path;
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cux_ship_notes');
    _git = Git(_root.path);
    _git.run(['init', '-q', '-b', 'main']);
    _git.run(['config', 'user.email', 'test@example.com']);
    _git.run(['config', 'user.name', 'Test']);
  });

  tearDown(() => _root.deleteSync(recursive: true));

  test('committed notes are allowed', () {
    final path = _changelog('# Changelog\n\n## 1.0.0\n\n- Something\n');
    _git.run(['add', '-A']);
    _git.run(['commit', '-q', '-m', 'notes']);

    expect(() => requireCommittedNotes([path]), returnsNormally);
  });

  test('an uncommitted edit is refused, naming the file', () {
    final path = _changelog('# Changelog\n\n## 1.0.0\n\n- Something\n');
    _git.run(['add', '-A']);
    _git.run(['commit', '-q', '-m', 'notes']);
    File(path).writeAsStringSync('# Changelog\n\n## 1.0.0\n\n- Half a sen');

    expect(
      () => requireCommittedNotes([path]),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('CHANGELOG.md'), contains('Commit it first')),
        ),
      ),
    );
  });

  test('a file that was never committed at all is refused', () {
    // The dangerous case is not only an edit to a tracked file: a changelog
    // added and never committed is entirely unreviewed.
    final path = _changelog('# Changelog\n\n## 1.0.0\n\n- New\n');
    expect(
      () => requireCommittedNotes([path]),
      throwsA(isA<ReleaseException>()),
    );
  });

  test('several sources are all checked, not just the first', () {
    // The rule is over *the files the notes were resolved from*, which at 23
    // locales is 23 files. Checking one of them would pass a release whose
    // other twenty-two were mid-edit.
    final clean = _changelog('# Changelog\n\n## 1.0.0\n\n- Something\n');
    _git.run(['add', '-A']);
    _git.run(['commit', '-q', '-m', 'notes']);
    final dirty = '${_root.path}/changelogs-53.txt';
    File(dirty).writeAsStringSync('not committed');

    expect(
      () => requireCommittedNotes([clean, dirty]),
      throwsA(isA<ReleaseException>()),
    );
  });

  test('a path outside any repository is allowed', () {
    // A dist/ published from a tarball on a machine with no checkout has no
    // working tree to be dirty, and refusing there would block a legitimate
    // release for a condition that cannot exist.
    final loose = Directory.systemTemp.createTempSync('cux_ship_norepo');
    addTearDown(() => loose.deleteSync(recursive: true));
    final path = '${loose.path}/CHANGELOG.md';
    File(path).writeAsStringSync('# Changelog\n\n## 1.0.0\n\n- Something\n');

    expect(() => requireCommittedNotes([path]), returnsNormally);
  });

  test('a path that does not exist is not this check\'s business', () {
    // Absent is a different failure with a better message elsewhere; refusing
    // here would report a missing changelog as a dirty one.
    expect(
      () => requireCommittedNotes(['${_root.path}/nope.md']),
      returnsNormally,
    );
  });

  test('an uncommitted edit reached through a symlink is still refused', () {
    // The blind spot this pins: `git status -- <link>` answers for the link
    // object, which stays clean while the file it points at is mid-edit. One
    // consuming repository keeps CHANGELOG.md as a root symlink into its
    // package directory, and an uncommitted section walked straight past the
    // guard through it.
    Directory('${_root.path}/pkg').createSync();
    final target = '${_root.path}/pkg/CHANGELOG.md';
    File(target).writeAsStringSync('# Changelog\n\n## 1.0.0\n\n- Something\n');
    final link = Link('${_root.path}/CHANGELOG.md')
      ..createSync('pkg/CHANGELOG.md');
    _git.run(['add', '-A']);
    _git.run(['commit', '-q', '-m', 'notes and link']);
    File(target).writeAsStringSync('# Changelog\n\n## 1.0.0\n\n- Half a sen');

    expect(
      () => requireCommittedNotes([link.path]),
      throwsA(
        isA<ReleaseException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('pkg/CHANGELOG.md'), contains('Commit it first')),
        ),
      ),
    );
  });

  test('a clean file reached through a symlink is allowed', () {
    // The other half: resolving the link must not turn a committed file into
    // a refusal.
    Directory('${_root.path}/pkg').createSync();
    File(
      '${_root.path}/pkg/CHANGELOG.md',
    ).writeAsStringSync('# Changelog\n\n## 1.0.0\n\n- Something\n');
    final link = Link('${_root.path}/CHANGELOG.md')
      ..createSync('pkg/CHANGELOG.md');
    _git.run(['add', '-A']);
    _git.run(['commit', '-q', '-m', 'notes and link']);

    expect(() => requireCommittedNotes([link.path]), returnsNormally);
  });

  test('a symlink into another repository consults that repository', () {
    // The link's parent decides which repository is asked, and for a symlink
    // those differ: asked about a path outside itself, the link-side
    // repository answers nothing at all, and nothing reads as clean.
    final other = Directory.systemTemp.createTempSync('cux_ship_other');
    addTearDown(() => other.deleteSync(recursive: true));
    final otherGit = Git(other.path);
    otherGit.run(['init', '-q', '-b', 'main']);
    otherGit.run(['config', 'user.email', 'test@example.com']);
    otherGit.run(['config', 'user.name', 'Test']);
    final target = '${other.path}/CHANGELOG.md';
    File(target).writeAsStringSync('never committed over there');
    final link = Link('${_root.path}/CHANGELOG.md')..createSync(target);

    expect(
      () => requireCommittedNotes([link.path]),
      throwsA(isA<ReleaseException>()),
    );
  });
}
