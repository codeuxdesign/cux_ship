// Turns CHANGELOG.md into the release notes a store shows.
//
// Its own package rather than a file inside one of the uploaders, because both
// of them need it and neither should depend on the other. That was anticipated
// where this code used to live, in tool/play_upload/lib/changelog.dart: "an iOS
// uploader will want the same parser with a different platform, which is why
// the platform is an argument here and a constant at the call site."
//
// It is the only part of publishing with real branching — present or absent,
// empty or not, this platform or another — and every branch decides what a
// stranger reads on a store page, so it wants tests rather than a careful
// reading.
//
// No dependencies at all, which is what makes it cheap to share.
import 'dart:convert';
import 'dart:io';

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

/// [changelogNotes] against a file on disk.
Notes changelogNotesOf(
  String path,
  String version, {
  required String platform,
}) =>
    changelogNotes(File(path).readAsStringSync(), version, platform: platform);

/// The version name out of a release name this tool wrote, which is
/// `<versionName> (<versionCode>)`.
///
/// Used to look a promoted release up in the changelog. Falls back to the whole
/// name for anything shaped differently — a release created by hand in the
/// console — which then simply fails to match a section, and says so, rather
/// than guessing.
String versionFromReleaseName(String name) =>
    RegExp(r'^(.*?)\s*\(\d+\)$').firstMatch(name)?.group(1) ?? name;
