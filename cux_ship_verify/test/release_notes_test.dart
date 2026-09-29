// SPDX-License-Identifier: Apache-2.0

// The rules in lib/release_notes.dart decide what a stranger reads on a store
// page, and several of them are invisible when they misfire: a swallowed
// continuation line, a prefix that was not stripped, a fallback that reached
// too far back. Each one is pinned here.
import 'dart:io';

import 'package:cux_ship_verify/release_notes.dart';
import 'package:test/test.dart';

/// Shaped like the real CHANGELOG.md: prose headings first, then versions
/// newest-first. The prose is what stops a naive parser from reading "## Tone"
/// as a version.
const _changelog = '''
# Changelog

Blah blah.

## Tone

Playful. This paragraph is not a release note.

## 1.3.0

- [ios] Fixed the notch overlapping the transport bar

## 1.2.0

## 1.1.0

- Tap the elevation profile to jump there, with a sentence that
  wraps onto a second line
- [android] Back gesture no longer eats the segment editor
- [ios, web] Something for two other platforms

## 1.0.0

- Hello! First release.
''';

void main() {
  group('changelogNotes', () {
    test('takes the entries for the requested version', () {
      final notes = changelogNotes(_changelog, '1.0.0', platform: 'android');
      expect(
        notes,
        const NotesText('- Hello! First release.', fromVersion: '1.0.0'),
      );
    });

    test('keeps unprefixed entries and strips a matching prefix', () {
      final notes = changelogNotes(_changelog, '1.1.0', platform: 'android');
      expect(
        notes,
        isA<NotesText>().having(
          (n) => n.text,
          'text',
          '- Tap the elevation profile to jump there, with a sentence that\n'
              '  wraps onto a second line\n'
              '- Back gesture no longer eats the segment editor',
        ),
      );
    });

    test(
      'a continuation line stays with its entry rather than becoming one',
      () {
        // A continuation treated as its own entry would be filtered on its own
        // and could be published as a detached half-sentence, so it has to stay
        // glued to the line above through the filter.
        final notes =
            changelogNotes(_changelog, '1.1.0', platform: 'ios') as NotesText;
        expect(
          notes.text,
          contains(
            'jump there, with a sentence that\n  wraps onto a second line',
          ),
        );
        // The unprefixed entry and the [ios, web] one, and nothing else.
        expect(
          notes.text.split('\n').where((l) => l.startsWith('- ')),
          hasLength(2),
        );
      },
    );

    test('a multi-platform prefix matches any of its platforms', () {
      final notes =
          changelogNotes(_changelog, '1.1.0', platform: 'web') as NotesText;
      expect(notes.text, contains('Something for two other platforms'));
      expect(notes.text, isNot(contains('[ios, web]')));
    });

    test(
      'a version with nothing for this platform falls back to an older one',
      () {
        // 1.3.0 is iOS-only and 1.2.0 is empty, so Android reaches 1.1.0.
        final notes =
            changelogNotes(_changelog, '1.3.0', platform: 'android')
                as NotesText;
        expect(notes.fromVersion, '1.1.0');
        expect(notes.text, contains('Back gesture'));
      },
    );

    test('an empty section falls back the same way', () {
      final notes =
          changelogNotes(_changelog, '1.2.0', platform: 'android') as NotesText;
      expect(notes.fromVersion, '1.1.0');
    });

    test('the fallback never reaches forward to a newer version', () {
      // Android has nothing at or below 1.0.0's neighbours here, so a parser
      // that scanned the whole file rather than downwards would wrongly find
      // 1.1.0 for a version below it.
      const onlyOther = '''
## 2.0.0

- [android] Something Android got

## 1.0.0

- [ios] Only ever an iOS thing
''';
      final notes =
          changelogNotes(onlyOther, '1.0.0', platform: 'android') as NotesText;
      expect(notes.text, noUserVisibleChanges);
      expect(notes.fromVersion, isEmpty);
    });

    test('falls back to the boilerplate when nothing anywhere qualifies', () {
      // Every entry is scoped to somewhere else. An unprefixed entry would
      // count for macos too, which is the whole point of leaving one off.
      const elsewhere = '''
## 2.0.0

- [ios] Something

## 1.0.0

- [android, web] Something else
''';
      final notes =
          changelogNotes(elsewhere, '2.0.0', platform: 'macos') as NotesText;
      expect(notes.text, noUserVisibleChanges);
      expect(notes.fromVersion, isEmpty);
    });

    test('a missing version is an error rather than a fallback', () {
      expect(
        changelogNotes(_changelog, '9.9.9', platform: 'android'),
        isA<NoSection>(),
      );
    });

    test('prose headings are not versions', () {
      expect(
        changelogNotes(_changelog, 'Tone', platform: 'android'),
        isA<NoSection>(),
      );
    });

    test('a bracketed heading with a date is still that version', () {
      const dated = '## [1.4.0] - 2026-08-05\n\n- Something\n';
      expect(
        changelogNotes(dated, '1.4.0', platform: 'android'),
        isA<NotesText>(),
      );
    });

    test('a bracket mid-sentence is text, not a platform prefix', () {
      const midSentence = '## 1.0.0\n\n- Fixed [android] in the docs\n';
      final notes =
          changelogNotes(midSentence, '1.0.0', platform: 'ios') as NotesText;
      expect(notes.text, '- Fixed [android] in the docs');
    });
  });

  group('localeChangelogPath', () {
    test('puts the locale before the extension, beside the changelog', () {
      expect(
        localeChangelogPath('CHANGELOG.md', 'de-DE'),
        'CHANGELOG.de-DE.md',
      );
      expect(
        localeChangelogPath('docs/CHANGELOG.md', 'zh-Hans'),
        'docs/CHANGELOG.zh-Hans.md',
      );
    });

    test('appends to a name with no .md', () {
      expect(localeChangelogPath('NOTES', 'pt-BR'), 'NOTES.pt-BR');
    });

    test('a dot in a directory is not the extension', () {
      // A worktree lives under `.claude/`, and a release branch directory is
      // `v1.2/` — cutting at the first `.` would put the locale mid-path.
      expect(
        localeChangelogPath('/w/.claude/v1.2/CHANGELOG.md', 'de-DE'),
        '/w/.claude/v1.2/CHANGELOG.de-DE.md',
      );
      expect(localeChangelogPath('v1.2/NOTES', 'de-DE'), 'v1.2/NOTES.de-DE');
    });
  });

  group('localeNotesSource', () {
    late Directory root;
    late String changelog;

    setUp(() {
      root = Directory.systemTemp.createTempSync('locale_notes_source');
      changelog = '${root.path}/CHANGELOG.md';
      File(changelog).writeAsStringSync('## 1.0.0\n\n- Hello\n');
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('a locale with its own file reads it', () {
      File('${root.path}/CHANGELOG.de-DE.md').writeAsStringSync('## 1.0.0\n');

      expect(
        localeNotesSource(changelog, 'de-DE'),
        isA<OwnFile>().having(
          (s) => s.path,
          'path',
          '${root.path}/CHANGELOG.de-DE.md',
        ),
      );
    });

    test('a locale without one takes the changelog', () {
      expect(
        localeNotesSource(changelog, 'de-DE'),
        isA<DefaultFile>().having((s) => s.path, 'path', changelog),
      );
    });

    test('a link to nothing is its own case, not "no file"', () {
      // `File.existsSync` follows the link and says false, so without the
      // `typeSync` probe this is a DefaultFile — and the German translation
      // somebody linked in is replaced by the English notes in silence.
      Link(
        '${root.path}/CHANGELOG.de-DE.md',
      ).createSync('${root.path}/translations/de.md');

      expect(localeNotesSource(changelog, 'de-DE'), isA<DanglingLink>());
    });

    test('a link that resolves is simply the locale\'s file', () {
      Link('${root.path}/CHANGELOG.de-DE.md').createSync(changelog);

      expect(localeNotesSource(changelog, 'de-DE'), isA<OwnFile>());
    });
  });

  group('localeChangelogsBeside', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('locale_changelogs_beside');
      File('${root.path}/CHANGELOG.md').writeAsStringSync('## 1.0.0\n');
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('finds each locale file by the locale its name carries', () {
      File('${root.path}/CHANGELOG.de-DE.md').writeAsStringSync('');
      File('${root.path}/CHANGELOG.de.md').writeAsStringSync('');
      Link('${root.path}/CHANGELOG.fr-FR.md').createSync('${root.path}/gone');
      // Not locale files: another stem, and a nested extension.
      File('${root.path}/CHANGES.de-DE.md').writeAsStringSync('');
      File('${root.path}/CHANGELOG.de-DE.md.bak').writeAsStringSync('');

      expect(localeChangelogsBeside('${root.path}/CHANGELOG.md').keys.toSet(), {
        'de-DE',
        'de',
        'fr-FR',
      });
    });
  });

  group('versionFromReleaseName', () {
    test('drops the version code this tool appends', () {
      expect(versionFromReleaseName('1.2.0 (37)'), '1.2.0');
    });

    test('leaves a name it did not write alone', () {
      expect(versionFromReleaseName('Hand-made release'), 'Hand-made release');
    });
  });

  // Both stores enforce their cap *after* the artifact has been uploaded, which
  // is far too late and is why the limits exist here at all. Every section of a
  // real changelog is still checked against both — but not from here.
  //
  // That check read '../../CHANGELOG.md', which resolved only while this
  // package sat inside the app whose changelog it was. It now lives in
  // cux_ship_verify as checkChangelog(), and each consuming repository calls it
  // against its own CHANGELOG.md from its own suite, so an over-long entry is
  // still caught by CI when it is written rather than by a store when it is
  // published.
}
