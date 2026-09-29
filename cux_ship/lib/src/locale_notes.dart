// SPDX-License-Identifier: Apache-2.0
//
// Release notes for every locale a store listing has.
//
// **The defect.** Both uploaders wrote notes for one locale — the App Store's
// `--locale`, defaulting to en-US; Play's listing default language — while a
// listing could carry several. Apple requires "What's New" on every
// localization of an update, so on 29 September 2026 a listing that had gained
// a German localization answered the review submission with `409 …
// appStoreVersions … is not in valid state`, and the release went out after a
// second run by hand wrote the English notes to de-DE. `verify` was green
// throughout: nothing asked whether every declared locale would get notes.
//
// **The rule** is a filename convention and no configuration:
// `CHANGELOG.md` is the notes for every locale without a file of its own, and
// `CHANGELOG.<locale>.md` beside it is that locale's. Which locales exist is
// what `.cux-ship.yaml` already declares. See `release_notes.dart` in
// cux_ship_verify for the grammar and docs/design/locale-release-notes.md for
// the alternatives that were turned down.
//
// **One resolver for both stores**, because the two `notesFor` closures were
// already two copies of the same branching — present or absent, empty or
// not, fallen back or not — and a per-locale loop added to each would have
// made it four.
import 'package:cux_ship_verify/release_notes.dart';
import 'package:path/path.dart' as p;

import 'notes_source.dart';
import 'release.dart' show ReleaseException;

/// The release notes for one version on one platform, per locale.
class LocaleNotes {
  const LocaleNotes({
    required this.byLocale,
    required this.defaultText,
    required this.sources,
    required this.fromDefault,
  });

  /// Literal text, the same in every locale — `--release-notes <file>`.
  ///
  /// **To every locale, deliberately.** The flag exists for a repository
  /// that keeps its notes in one file rather than a changelog, and such a
  /// repository has made no per-locale decision for this to honour.
  /// Refusing it whenever more than one locale is in play would shut that
  /// caller out the day its listing gains a language.
  factory LocaleNotes.literal(String text, Iterable<String> locales) =>
      LocaleNotes(
        byLocale: {for (final locale in locales) locale: text},
        defaultText: text,
        sources: const [],
        fromDefault: const {},
      );

  /// Locale to the text to publish there, already filtered to the platform.
  final Map<String, String> byLocale;

  /// The default changelog's text, for a locale the caller meets only once
  /// the store has answered — a localization Apple holds that nothing
  /// declares. See [textFor].
  final String defaultText;

  /// Every file that was read, which is what [requireCommittedNotes] was
  /// handed.
  final List<String> sources;

  /// The locales that took the default changelog because they have no file
  /// of their own.
  final Set<String> fromDefault;

  /// What [locale] publishes: its own resolution, or the default text for a
  /// locale that was not asked about.
  String textFor(String locale) => byLocale[locale] ?? defaultText;
}

/// Resolves [changelog]'s notes for [version] on [platform], for every one of
/// [locales].
///
/// Each locale reads `CHANGELOG.<locale>.md` when it exists and [changelog]
/// otherwise; each file is walked on its own, so an empty German section
/// falls back to the newest older *German* section and never to the English
/// one. Each text is checked against [limit] on its own too — a translation
/// is routinely longer than its source.
///
/// The default changelog is always resolved, whether or not any locale takes
/// it: it is what an undeclared locale falls back to, and it is the file that
/// has always been required, so a repository that translates every locale is
/// not quietly excused from keeping it.
///
/// [missingSectionIsError] is false only for the App Store's listing-only
/// publish, where the changelog was inferred rather than named and an absent
/// section means "no notes this run" rather than a mistake. **Even then the
/// answer is all or nothing**: when any file lacks the section, no locale
/// gets notes, and the run says which file. Publishing English where a German
/// file was forgotten would be exactly the silent substitution this exists to
/// prevent, and publishing to some localizations and not others is the state
/// Apple refuses to submit.
///
/// Returns null only when [missingSectionIsError] is false and a section was
/// missing. [fail] is each store's own refusal, so a message reads the way
/// the rest of that command's do. [store] names the store in the limit
/// refusal.
///
/// [requireCommittedNotes] runs once, over every file, before any is parsed.
LocaleNotes? resolveLocaleNotes({
  required String changelog,
  required String version,
  required String platform,
  required Iterable<String> locales,
  required int limit,
  required String store,
  required Never Function(String) fail,
  required void Function(String) say,
  bool missingSectionIsError = true,
}) {
  final sources = <String, NotesSource>{
    for (final locale in locales) locale: localeNotesSource(changelog, locale),
  };
  for (final MapEntry(key: locale, value: source) in sources.entries) {
    if (source is DanglingLink) {
      fail(
        '${source.path} is a symlink to nothing, so $locale would silently '
        "publish $changelog's notes.\n"
        '  Point it at the file it was meant to name, or delete it to publish '
        'those notes deliberately.',
      );
    }
  }

  final read = [
    changelog,
    for (final source in sources.values) ...[
      if (source is OwnFile) source.path,
    ],
  ];
  try {
    requireCommittedNotes(read);
  } on ReleaseException catch (e) {
    fail(e.message);
  }

  // Resolves one file; null means the section was absent and that is not an
  // error on this path.
  String? resolve(String path, {String? locale}) {
    final notes = changelogNotesOf(path, version, platform: platform);
    final prefix = locale == null ? '' : '$locale: ';
    switch (notes) {
      case NoSection():
        if (!missingSectionIsError) {
          if (locale != null) {
            say(
              '==> release notes skipped: $path has no section for $version, '
              'and a\n'
              '    locale file is that locale\'s notes — so no locale gets '
              'any, rather than\n'
              '    $locale getting the default\'s in its place.',
            );
          }
          return null;
        }
        fail(
          '$path has no section for $version.\n'
          '  Add one. Empty is a fine answer — it publishes the newest older\n'
          '  version that did change something here, or\n'
          '  "$noUserVisibleChanges" if there is none. Absent is not the same\n'
          '  answer as empty.'
          '${locale == null ? '' : '\n  Or delete $path to publish '
                    "$changelog's notes to $locale."}',
        );
      case NotesText(:final text, :final fromVersion):
        if (text.length > limit) {
          fail(
            "$prefix$path's $fromVersion section is ${text.length} "
            'characters once filtered to $platform; $store allows $limit',
          );
        }
        // Said out loud: publishing one version's notes under another
        // version's name should never happen quietly.
        if (fromVersion.isEmpty) {
          say(
            '==> ${prefix}nothing at or below $version is user-visible on '
            '$platform — publishing "$text"',
          );
        } else if (fromVersion != version) {
          say(
            '==> $prefix$version changes nothing on $platform — publishing '
            "$fromVersion's notes instead",
          );
        }
        return text;
    }
  }

  final defaultText = resolve(changelog);
  if (defaultText == null) {
    return null;
  }
  final byLocale = <String, String>{};
  final fromDefault = <String>{};
  for (final MapEntry(key: locale, value: source) in sources.entries) {
    switch (source) {
      case OwnFile(:final path):
        final text = resolve(path, locale: locale);
        if (text == null) {
          return null;
        }
        byLocale[locale] = text;
      case DefaultFile():
        byLocale[locale] = defaultText;
        fromDefault.add(locale);
      case DanglingLink():
        // Refused above, before anything was read.
        throw StateError('unreachable: $locale is a dangling link');
    }
  }

  // Named whenever there is more than one answer to "where did this come
  // from" — several locales, or one with a file of its own. A lone locale on
  // the default is every release before this existed, and says nothing new.
  if (sources.length > 1 || fromDefault.length < sources.length) {
    say('==> release notes by locale');
    for (final line in localeNotesSourceLines(changelog, sources.keys)) {
      say('    $line');
    }
  }

  return LocaleNotes(
    byLocale: byLocale,
    defaultText: defaultText,
    sources: read,
    fromDefault: fromDefault,
  );
}

/// One line per locale saying which file its notes come from, by name.
///
/// Printed by every run that publishes to more than one locale, and by
/// `verify`, in the same words — so a locale on the default is a choice read
/// on every release rather than one made once and forgotten. The `(no …)`
/// names the file that would change the answer, which is the thing a reader
/// wanting a translation needs to know.
List<String> localeNotesSourceLines(
  String changelog,
  Iterable<String> locales,
) => [
  for (final locale in locales) ...[
    switch (localeNotesSource(changelog, locale)) {
      OwnFile(:final path) => '$locale ← ${p.basename(path)}',
      DefaultFile() =>
        '$locale ← ${p.basename(changelog)} (no '
            '${p.basename(localeChangelogPath(changelog, locale))})',
      DanglingLink(:final path) =>
        '$locale ← nothing: ${p.basename(path)} is a dangling link',
    },
  ],
];
