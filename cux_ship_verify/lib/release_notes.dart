// SPDX-License-Identifier: Apache-2.0

// Turns CHANGELOG.md into the release notes a store shows.
//
// Its own package rather than a file inside one of the uploaders, because both
// of them need it and neither should depend on the other. That was anticipated
// where this code used to live, in cux_ship_play/lib/changelog.dart: "an iOS
// uploader will want the same parser with a different platform, which is why
// the platform is an argument here and a constant at the call site."
//
// It is the only part of publishing with real branching — present or absent,
// empty or not, this platform or another — and every branch decides what a
// stranger reads on a store page, so it wants tests rather than a careful
// reading.
//
// **The grammar, in one place.** A `## <version>` heading opens a section,
// newest first. Each `-` or `*` bullet is an entry; indented lines continue it.
// An entry that begins `[android]`, `[ios]`, `[macos]`, or a comma list of
// those — `- [ios, macos] Drag files in` — reaches only those platforms and
// has the prefix stripped; an entry with no prefix reaches every store. That
// last rule is the one that bites: App Review Guideline 2.3.10 rejects
// metadata naming another mobile platform, so an unscoped entry about Android
// is App Store copy too.
//
// **And one file per locale, by name.** `CHANGELOG.md` is the notes for every
// locale that has no file of its own; `CHANGELOG.de-DE.md` beside it is
// de-DE's, with the same grammar, the same prefixes and the same walk to an
// older section — which never crosses into another file. No configuration
// says which locales exist; the stores' own `locales:` declaration does, and
// the file's presence is the whole of the override. fastlane's `deliver` has
// the same shape (`metadata/default/` filling every language without its
// own), and Xcode Cloud puts the locale in the filename, which is where it is
// here. See docs/design/locale-release-notes.md.
//
// No dependencies at all, which is what makes it cheap to share.
import 'dart:convert';
import 'dart:io';

import 'release_problem.dart';

/// What ships when neither the version being released nor anything before it
/// has a word to say about this platform.
///
/// Not a placeholder to be filled in later — it is the correct note for a
/// release that changed nothing a user can see, and saying so plainly beats
/// inventing a feature to announce.
const noUserVisibleChanges = 'Performance improvements and bug fixes 🚀';

/// Play's cap on release notes.
///
/// Both store caps live here, beside the parser that produces the text they
/// constrain, because both stores enforce them at exactly the wrong moment —
/// *after* the artifact has been uploaded. Checking locally first is the whole
/// reason either number is written down, and keeping them together means the
/// two are reviewed in one place rather than drifting apart in two uploaders.
const playReleaseNotesLimit = 500;

/// The App Store's cap on an `appStoreVersionLocalizations` `whatsNew`, and on
/// a `betaBuildLocalizations` `whatsNew` ("What to Test").
///
/// Eight times Play's, so a section that fits Play always fits here — but the
/// check still runs, because the reverse is not true and the failure mode is
/// identical.
const appStoreReleaseNotesLimit = 4000;

/// What looking a version up in the changelog produced.
sealed class Notes {
  const Notes();
}

/// The changelog has no section for that version at all, which means somebody
/// forgot rather than decided. The only outcome worth failing on: every other
/// case is a deliberate answer, including an empty section.
class NoSection extends Notes {
  const NoSection();
}

/// Notes to publish.
class NotesText extends Notes {
  const NotesText(this.text, {required this.fromVersion});

  final String text;

  /// The version the text was taken from, which is not the version being
  /// released when an older section had to be fallen back to. Callers say so
  /// out loud rather than quietly publishing another version's notes.
  final String fromVersion;

  @override
  bool operator ==(Object other) =>
      other is NotesText &&
      other.text == text &&
      other.fromVersion == fromVersion;

  @override
  int get hashCode => Object.hash(text, fromVersion);

  @override
  String toString() => 'NotesText($fromVersion: $text)';
}

/// A version heading: `## 1.2.0`, `## [1.2.0]`, `## 1.2.0 - 2026-08-05`.
///
/// Required to start with a digit, which is what keeps the prose headings the
/// file opens with ("## Tone", "## How to keep it") from being read as
/// versions with very strange numbers.
final _versionHeading = RegExp(
  r'^##\s+\[?(\d[^\]\s]*)\]?\s*(?:[-–—]\s*\S.*)?$',
);

final _anyHeading = RegExp(r'^##\s');
final _bullet = RegExp(r'^\s*[-*]\s');

/// `- [android, ios] text` — the prefix has to sit at the very start of the
/// entry, so a bracket appearing mid-sentence is text like any other.
final _scope = RegExp(r'^(\s*[-*]\s*)\[([a-z, ]+)\]\s*');

typedef _Section = ({String version, List<String> entries});

/// Every version section in document order, which the file keeps newest first.
///
/// An entry begins with `-` or `*`; indented lines under it are continuations
/// of that entry rather than entries of their own, so a wrapped sentence is not
/// torn in half by the platform filter later.
List<_Section> _sections(String markdown) {
  final sections = <_Section>[];
  List<String>? entries;

  for (final line in const LineSplitter().convert(markdown)) {
    final heading = _versionHeading.firstMatch(line);
    if (heading != null) {
      entries = <String>[];
      sections.add((version: heading.group(1)!, entries: entries));
      continue;
    }
    if (_anyHeading.hasMatch(line)) {
      // A prose heading ends whatever section was being collected, rather than
      // silently absorbing the rest of the document into it.
      entries = null;
      continue;
    }
    if (entries == null || line.trim().isEmpty) {
      continue;
    }
    if (_bullet.hasMatch(line) || entries.isEmpty) {
      entries.add(line.trimRight());
    } else {
      entries[entries.length - 1] += '\n${line.trimRight()}';
    }
  }
  return sections;
}

/// The entries of [section] that a [platform] user could notice, with the
/// scope prefix stripped — it is repository bookkeeping, not something to
/// publish. An unprefixed entry belongs to every platform.
List<String> _forPlatform(List<String> section, String platform) {
  final kept = <String>[];
  for (final entry in section) {
    final match = _scope.firstMatch(entry);
    if (match == null) {
      kept.add(entry);
      continue;
    }
    final platforms = match
        .group(2)!
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty);
    if (platforms.contains(platform)) {
      kept.add(entry.replaceRange(0, match.end, match.group(1)!));
    }
  }
  return kept;
}

/// The release notes to publish for [version] on [platform].
///
/// A version whose own section says nothing about this platform — empty, or
/// entirely `[ios]` — falls back to the newest earlier version that does. That
/// is not a workaround for a missing entry: a release still has to tell users
/// something, and the most recent thing this platform actually gained is a
/// truer answer than boilerplate. Only when nothing anywhere below qualifies
/// does [noUserVisibleChanges] go out.
///
/// The walk relies on the file being newest-first, which is the convention
/// CHANGELOG.md states and `tool/build.sh --release` half-enforces by requiring
/// a section for the version being built.
Notes changelogNotes(
  String markdown,
  String version, {
  required String platform,
}) {
  final sections = _sections(markdown);
  final start = sections.indexWhere((s) => s.version == version);
  if (start < 0) {
    return const NoSection();
  }
  for (var i = start; i < sections.length; i++) {
    final kept = _forPlatform(sections[i].entries, platform);
    if (kept.isNotEmpty) {
      return NotesText(kept.join('\n'), fromVersion: sections[i].version);
    }
  }
  return const NotesText(noUserVisibleChanges, fromVersion: '');
}

/// Another store's name, as App Review would read it.
///
/// Android's names only, because Apple's is the rule that rejects: App Review
/// Guideline 2.3.10 refuses metadata naming another mobile platform. Play has
/// no such rule, so an entry reaching Android that names iPhone is allowed,
/// and a check for it would be a style warning this package has no channel
/// for. Word-bounded, so `androids` and a bare `Play` are not hits.
final _otherStoreNames = RegExp(
  r'\b(android|google play|play store)\b',
  caseSensitive: false,
);

/// Entries that would reach an Apple store naming Android.
///
/// An entry with no scope prefix reaches every store, so *"Drag files in on
/// Android"* written without `[android]` is App Store copy — which is how it
/// reached two uploaded builds of one consumer on 29 September 2026 before a
/// reader caught it. Checked on the text each Apple platform would actually
/// get, after filtering: an `[android]` entry is fine, and a `[macos]` one
/// is reported against macOS alone.
///
/// Every section, not only the newest, because the fallback walk can publish
/// an older one. One problem per entry, naming each Apple platform it reaches.
/// [name] is what the problems call the file.
List<ReleaseProblem> checkPlatformNames(
  String markdown, {
  String name = 'CHANGELOG.md',
}) {
  final problems = <ReleaseProblem>[];
  for (final section in _sections(markdown)) {
    for (final entry in section.entries) {
      final reaches = <String>[];
      String? named;
      for (final platform in const ['ios', 'macos']) {
        final kept = _forPlatform([entry], platform);
        final match = kept.isEmpty
            ? null
            : _otherStoreNames.firstMatch(kept.single);
        if (match != null) {
          reaches.add(platform);
          named = match.group(0);
        }
      }
      if (reaches.isEmpty) {
        continue;
      }
      final text = entry.split('\n').first.trim();
      problems.add(
        ReleaseProblem(
          '$name § ${section.version} → ${reaches.join(', ')}',
          '"$text" names $named and reaches the App Store — App Review '
              'Guideline 2.3.10 rejects metadata naming other mobile platforms. '
              'Prefix it [android], or reword it',
        ),
      );
    }
  }
  return problems;
}

/// [changelogNotes] against a file on disk.
Notes changelogNotesOf(
  String path,
  String version, {
  required String platform,
}) =>
    changelogNotes(File(path).readAsStringSync(), version, platform: platform);

/// Where [locale]'s own notes live, beside [changelog].
///
/// `CHANGELOG.md` and `de-DE` give `CHANGELOG.de-DE.md`, in the same
/// directory; a name with no `.md` gets the locale appended, so
/// `NOTES` gives `NOTES.de-DE`. The locale is spelled exactly as a store
/// block declares it — `de-DE`, `zh-Hans`, `pt-BR` — because that
/// declaration is the only list of locales there is, and a second spelling
/// would be a second list.
///
/// Pure: it says where the file would be, not whether it is there. That is
/// [localeNotesSource]'s question.
String localeChangelogPath(String changelog, String locale) {
  final (:directory, :stem, :extension) = _splitChangelog(changelog);
  return '$directory$stem.$locale$extension';
}

/// [changelog] as the three parts a locale file is named from.
///
/// Split on the last separator of either kind rather than with `dart:io`'s
/// path handling, which this package does not have: a `.` in a directory
/// name — `v1.2/CHANGELOG.md`, a worktree under `.claude/` — must not be
/// taken for the extension.
({String directory, String stem, String extension}) _splitChangelog(
  String changelog,
) {
  final cut = changelog.lastIndexOf(RegExp(r'[/\\]')) + 1;
  final directory = changelog.substring(0, cut);
  final name = changelog.substring(cut);
  if (name.toLowerCase().endsWith('.md') && name.length > 3) {
    return (
      directory: directory,
      stem: name.substring(0, name.length - 3),
      extension: name.substring(name.length - 3),
    );
  }
  return (directory: directory, stem: name, extension: '');
}

/// Which file a locale's notes come from.
///
/// Sealed so a caller switches over all three rather than testing a boolean
/// and forgetting the third — which is the one that matters, because
/// "absent" now means "take the default", and a link to nothing is not a
/// decision anybody made.
sealed class NotesSource {
  const NotesSource(this.path);

  /// The file the notes are read from, or for [DanglingLink] the link.
  final String path;
}

/// The locale has a file of its own, and its notes are that file's.
final class OwnFile extends NotesSource {
  const OwnFile(super.path);
}

/// The locale has no file, so it takes the changelog's — the ordinary case,
/// and the one that makes a listing gaining a language cost nothing.
final class DefaultFile extends NotesSource {
  const DefaultFile(super.path);
}

/// A symlink where the locale's file would be, pointing at nothing.
///
/// `File.existsSync` follows the link and answers false, so without its own
/// case this reads as [DefaultFile] and the locale silently publishes the
/// default text — the translation somebody linked in is dropped with no word
/// said. Refused by every caller, by name.
final class DanglingLink extends NotesSource {
  const DanglingLink(super.path);
}

/// Where [locale]'s notes come from, given [changelog] as the default.
///
/// A symlink that resolves is an ordinary [OwnFile] — the same file read
/// twice, if it points at the default — and needs no case of its own.
NotesSource localeNotesSource(String changelog, String locale) {
  final path = localeChangelogPath(changelog, locale);
  if (File(path).existsSync()) {
    return OwnFile(path);
  }
  if (FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.link) {
    return DanglingLink(path);
  }
  return DefaultFile(changelog);
}

/// Every locale file beside [changelog], by the locale its name carries.
///
/// What `verify` compares against the declared locales: a file for a locale
/// no store declares publishes nowhere, and the likeliest cause is a
/// misspelling — `CHANGELOG.de.md` beside `locales: [de-DE]` — that would
/// otherwise be a translation silently ignored.
///
/// Dangling links are included, since they are exactly what somebody meant
/// to be a locale file.
Map<String, String> localeChangelogsBeside(String changelog) {
  final (:directory, :stem, :extension) = _splitChangelog(changelog);
  final dir = Directory(directory.isEmpty ? '.' : directory);
  if (!dir.existsSync()) {
    return const {};
  }
  final pattern = RegExp(
    '^${RegExp.escape(stem)}\\.([^./\\\\]+)${RegExp.escape(extension)}\$',
  );
  final found = <String, String>{};
  for (final entity in dir.listSync(followLinks: false)) {
    final name = entity.path.substring(
      entity.path.lastIndexOf(RegExp(r'[/\\]')) + 1,
    );
    final match = pattern.firstMatch(name);
    if (match != null) {
      found[match.group(1)!] = '$directory$name';
    }
  }
  return found;
}

/// The version name out of a release name this tool wrote, which is
/// `<versionName> (<versionCode>)`.
///
/// Used to look a promoted release up in the changelog. Falls back to the whole
/// name for anything shaped differently — a release created by hand in the
/// console — which then simply fails to match a section, and says so, rather
/// than guessing.
String versionFromReleaseName(String name) =>
    RegExp(r'^(.*?)\s*\(\d+\)$').firstMatch(name)?.group(1) ?? name;
