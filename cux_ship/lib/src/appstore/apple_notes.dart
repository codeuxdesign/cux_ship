// SPDX-License-Identifier: Apache-2.0

// Makes CHANGELOG.md's release notes acceptable to Apple — on both surfaces.
//
// CHANGELOG.md is deliberately emoji-heavy — "Emoji are welcome and
// encouraged" is one of its stated rules, and it is the one place in the
// repository that talks to riders rather than developers. Play publishes that
// verbatim. **Apple does not, and it took two errors to learn that it means
// both fields.**
//
// TestFlight, on `betaBuildLocalizations`:
//
//   Text for whatsNew contains invalid characters:'[♀, ⚡, 🏔, 👋, 🚴, 🔒, ️]'
//
// The App Store, on `appStoreVersionLocalizations`:
//
//   An attribute value has invalid characters. — What's New in This Version
//   can't contain the following character(s): 🧭, 🗺, 🌍, ️
//
// **This file used to say the second field accepted emoji, and that claim was
// wrong.** It reasoned from published App Store listings that carry emoji —
// which is evidence about the *description*, a different field with a
// different rule. Nothing had exercised it: the only prior submission for the
// app in question was a first release, and a first release has no "What's New"
// at all, so the sentence sat there being believed until a second release met
// it and 409'd after the version had been created and the build attached.
//
// Both rejections fall inside the same ranges, so this is one rule with one
// implementation rather than two lists that would drift. If Apple ever proves
// the two fields differ, split it then — on evidence, not in anticipation.
//
// Stripping rather than failing is the right trade here, unlike the alpha
// channel on a screenshot. A screenshot with the wrong bytes is wrong; a note
// without its emoji still says the true thing, and the alternative would be
// either a second changelog or a rule that the changelog cannot use emoji at
// all. The substitution is announced by the caller rather than done silently —
// and on the App Store path that announcement matters more, because the text
// being altered is copy a shopper reads.
library;

/// Unicode ranges Apple rejects in a release note.
///
/// Derived from what Apple actually complained about plus the blocks those
/// characters live in, rather than from a published list — Apple documents the
/// field as accepting 4000 characters and says nothing about which ones.
///
/// Deliberately narrow. Everything outside these ranges is left alone, so an
/// em dash, a curly quote and an accented character all survive; only symbols
/// and pictographs go.
///
/// Note the variation-selector range is load-bearing rather than tidy: Apple
/// listed a bare U+FE0F as an invalid "character" in its own right, so this is
/// not only about pictographs.
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

/// Whether [text] carries anything Apple would refuse in a release note.
bool needsStrippingForApple(String text) => text.runes.any(_isRejected);

/// [text] with the characters Apple refuses removed.
///
/// Whitespace is tidied afterwards, because an emoji at the end of a line
/// leaves a trailing space and one mid-sentence leaves a double space — both
/// of which a reader notices even though the emoji's absence is the point.
///
/// **Leading whitespace is preserved.** An entry that wrapped onto a second
/// line is indented, and that indent is what keeps it reading as a
/// continuation rather than as a new bullet — collapsing it along with the
/// internal double spaces was the first version of this and was wrong.
String stripForApple(String text) {
  if (!needsStrippingForApple(text)) {
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
