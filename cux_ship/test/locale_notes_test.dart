// SPDX-License-Identifier: Apache-2.0
//
// `resolveLocaleNotes` decides which text each locale's store page shows, and
// every way it can be wrong is silent at the store: English leaking into a
// German release, a German section falling back to an English one, a
// translation over Play's cap reported as the English file's. Each is pinned.
//
// The temp root is outside any repository, which `requireCommittedNotes`
// skips by design — the dirty-file half is `notes_source_test.dart`'s.
import 'dart:io';

import 'package:cux_ship/src/locale_notes.dart';
import 'package:cux_ship_verify/release_notes.dart';
import 'package:test/test.dart';

late Directory _root;

String _write(String name, String contents) {
  final path = '${_root.path}/$name';
  File(path).writeAsStringSync(contents);
  return path;
}

/// A refusal, caught so a test can read what it said.
class _Refused implements Exception {
  _Refused(this.message);
  final String message;
}

LocaleNotes? _resolve(
  Iterable<String> locales, {
  String platform = 'android',
  int limit = playReleaseNotesLimit,
  bool missingSectionIsError = true,
  List<String>? said,
}) => resolveLocaleNotes(
  changelog: '${_root.path}/CHANGELOG.md',
  version: '1.1.9',
  platform: platform,
  locales: locales,
  limit: limit,
  store: 'Play',
  fail: (message) => throw _Refused(message),
  say: (line) => said?.add(line),
  missingSectionIsError: missingSectionIsError,
);

Matcher _refusal(Object matcher) =>
    throwsA(isA<_Refused>().having((e) => e.message, 'message', matcher));

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('locale_notes');
    _write(
      'CHANGELOG.md',
      '## 1.1.9\n\n- Drag files in\n\n## 1.1.8\n\n- Older\n',
    );
  });

  tearDown(() => _root.deleteSync(recursive: true));

  test('with no locale files, every locale takes the changelog', () {
    // The case that 409'd: a listing gained de-DE and nothing else changed.
    final notes = _resolve({'en-US', 'de-DE'})!;

    expect(notes.byLocale, {
      'en-US': '- Drag files in',
      'de-DE': '- Drag files in',
    });
    expect(notes.fromDefault, {'en-US', 'de-DE'});
    expect(notes.sources, ['${_root.path}/CHANGELOG.md']);
  });

  test("a locale file's section wins, and the default does not leak", () {
    final german = _write(
      'CHANGELOG.de-DE.md',
      '## 1.1.9\n\n- Dateien hineinziehen\n\n## 1.1.8\n\n- Älter\n',
    );

    final notes = _resolve({'en-US', 'de-DE'})!;

    expect(notes.byLocale['de-DE'], '- Dateien hineinziehen');
    expect(notes.byLocale['en-US'], '- Drag files in');
    expect(notes.fromDefault, {'en-US'});
    // Exactly the files read, which is what the dirty-file guard was handed.
    expect(notes.sources, ['${_root.path}/CHANGELOG.md', german]);
  });

  test('an empty German section walks to German 1.1.8, not English 1.1.9', () {
    // The walk never crosses files: empty in German means nothing changed for
    // German readers, exactly as it does in English.
    _write('CHANGELOG.de-DE.md', '## 1.1.9\n\n## 1.1.8\n\n- Älter\n');
    final said = <String>[];

    final notes = _resolve({'en-US', 'de-DE'}, said: said)!;

    expect(notes.byLocale['de-DE'], '- Älter');
    expect(said, contains(contains('de-DE: 1.1.9 changes nothing')));
  });

  test('a German file with no section for the version refuses, naming it', () {
    _write('CHANGELOG.de-DE.md', '## 1.1.8\n\n- Älter\n');

    expect(
      () => _resolve({'en-US', 'de-DE'}),
      _refusal(
        allOf(
          contains('CHANGELOG.de-DE.md has no section for 1.1.9'),
          contains('Or delete'),
        ),
      ),
    );
  });

  test('the limit is per locale, and the refusal names the locale', () {
    // English fits Play; German does not. Measured together, or against the
    // English file, this would either pass or send somebody to the wrong one.
    _write('CHANGELOG.md', '## 1.1.9\n\n- ${'e' * 478}\n');
    _write('CHANGELOG.de-DE.md', '## 1.1.9\n\n- ${'d' * 518}\n');

    expect(
      () => _resolve({'en-US', 'de-DE'}),
      _refusal(
        allOf(
          startsWith('de-DE: '),
          contains('CHANGELOG.de-DE.md'),
          contains('520 characters'),
          contains('Play allows 500'),
        ),
      ),
    );
    expect(_resolve({'en-US'})!.byLocale['en-US'], hasLength(480));
  });

  test('a dangling link where a locale file would be is refused', () {
    Link(
      '${_root.path}/CHANGELOG.de-DE.md',
    ).createSync('${_root.path}/translations/de.md');

    expect(
      () => _resolve({'en-US', 'de-DE'}),
      _refusal(contains('symlink to nothing')),
    );
  });

  group('when a missing section is not an error', () {
    // The App Store's listing-only publish, where the changelog was inferred.

    test('a missing default section means no notes, silently as before', () {
      _write('CHANGELOG.md', '## 1.1.8\n\n- Older\n');
      final said = <String>[];

      expect(
        _resolve({'en-US'}, missingSectionIsError: false, said: said),
        isNull,
      );
      expect(said, isEmpty);
    });

    test('a missing locale section means no notes anywhere, said out loud', () {
      // All or nothing: English in every locale but German would be the
      // silent substitution this refuses elsewhere, and notes on some
      // localizations and not others is the state Apple will not submit.
      _write('CHANGELOG.de-DE.md', '## 1.1.8\n\n- Älter\n');
      final said = <String>[];

      expect(
        _resolve({'en-US', 'de-DE'}, missingSectionIsError: false, said: said),
        isNull,
      );
      expect(said.join('\n'), contains('no locale gets any'));
    });
  });

  test('literal notes go to every locale', () {
    // `--release-notes <file>`: a repository that keeps one file has made no
    // per-locale decision to honour.
    final notes = LocaleNotes.literal('Bug fixes', {'en-US', 'de-DE'});

    expect(notes.byLocale, {'en-US': 'Bug fixes', 'de-DE': 'Bug fixes'});
    expect(notes.sources, isEmpty);
  });

  test('a locale nobody asked about takes the default text', () {
    // An App Store localization that nothing declares.
    _write('CHANGELOG.de-DE.md', '## 1.1.9\n\n- Dateien hineinziehen\n');

    final notes = _resolve({'de-DE'})!;

    expect(notes.textFor('fr-FR'), '- Drag files in');
    expect(notes.textFor('de-DE'), '- Dateien hineinziehen');
  });

  test('every locale and its source is named when there is a choice', () {
    _write('CHANGELOG.de-DE.md', '## 1.1.9\n\n- Dateien hineinziehen\n');
    final said = <String>[];

    _resolve({'en-US', 'de-DE', 'fr-FR'}, said: said);

    expect(said, [
      '==> release notes by locale',
      '    en-US ← CHANGELOG.md (no CHANGELOG.en-US.md)',
      '    de-DE ← CHANGELOG.de-DE.md',
      '    fr-FR ← CHANGELOG.md (no CHANGELOG.fr-FR.md)',
    ]);
  });

  test('a lone locale on the default says nothing new', () {
    // Every release before locales could be declared.
    final said = <String>[];

    _resolve({'en-US'}, said: said);

    expect(said, isEmpty);
  });
}
