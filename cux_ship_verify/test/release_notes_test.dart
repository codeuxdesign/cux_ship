// SPDX-License-Identifier: Apache-2.0

// The rules in lib/release_notes.dart decide what a stranger reads on a store
// page, and several of them are invisible when they misfire: a swallowed
// continuation line, a prefix that was not stripped, a fallback that reached
// too far back. Each one is pinned here.
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
