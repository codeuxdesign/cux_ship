// Makes CHANGELOG.md's release notes acceptable to TestFlight.
//
// CHANGELOG.md is deliberately emoji-heavy — "Emoji are welcome and
// encouraged" is one of its stated rules, and it is the one place in the
// repository that talks to riders rather than developers. Play publishes that
// verbatim. **TestFlight will not:**
//
//   Text for whatsNew contains invalid characters:'[♀, ⚡, 🏔, 👋, 🚴, 🔒, ️]'
//
// So the notes are stripped on the way to `betaBuildLocalizations`, and only
// there. This is not applied to the App Store release notes
// (`appStoreVersionLocalizations.whatsNew`), which accept emoji — plenty of
// App Store listings carry them — and stripping those would quietly flatten
// the voice for the audience it was written for.
//
// Stripping rather than failing is the right trade here, unlike the alpha
// channel on a screenshot. A screenshot with the wrong bytes is wrong; a
// tester note without its emoji still says the true thing, and the
// alternative would be either a second changelog or a rule that the changelog
// cannot use emoji at all. The substitution is announced by the caller rather
// than done silently.
library;

/// Unicode ranges TestFlight rejects.
///
/// Derived from what Apple actually complained about plus the blocks those
/// characters live in, rather than from a published list — Apple documents the
/// field as accepting 4000 characters and says nothing about which ones.
///
/// Deliberately narrow. Everything outside these ranges is left alone, so an
/// em dash, a curly quote and an accented character all survive; only symbols
/// and pictographs go.
const _rejected = <({int from, int to})>[
  (from: 0x200D, to: 0x200D), // zero-width joiner, glues 🚴‍♀️ together
  (from: 0x2190, to: 0x21FF), // arrows
  (from: 0x2300, to: 0x23FF), // miscellaneous technical, incl. ⏱
  (from: 0x2600, to: 0x27BF), // miscellaneous symbols and dingbats, incl. ♀ ⚡
  (from: 0x2B00, to: 0x2BFF), // miscellaneous symbols and arrows
  (from: 0xFE00, to: 0xFE0F), // variation selectors, the invisible ️ above
  (from: 0x1F000, to: 0x1FAFF), // emoji proper
];

bool _isRejected(int rune) =>
    _rejected.any((range) => rune >= range.from && rune <= range.to);

/// Whether [text] carries anything TestFlight would refuse.
bool needsStrippingForTestFlight(String text) => text.runes.any(_isRejected);

/// [text] with the characters TestFlight refuses removed.
///
/// Whitespace is tidied afterwards, because an emoji at the end of a line
/// leaves a trailing space and one mid-sentence leaves a double space — both
/// of which a reader notices even though the emoji's absence is the point.
///
/// **Leading whitespace is preserved.** An entry that wrapped onto a second
/// line is indented, and that indent is what keeps it reading as a
/// continuation rather than as a new bullet — collapsing it along with the
/// internal double spaces was the first version of this and was wrong.
String stripForTestFlight(String text) {
  if (!needsStrippingForTestFlight(text)) {
    return text;
  }
  final kept = String.fromCharCodes(
    text.runes.where((rune) => !_isRejected(rune)),
  );
  return kept
      .split('\n')
      .map((line) {
        final indent = RegExp(r'^[ \t]*').firstMatch(line)!.group(0)!;
        final body = line
            .substring(indent.length)
            .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
            .trimRight();
        return body.isEmpty ? '' : '$indent$body';
      })
      .join('\n')
      .trim();
}
