// SPDX-License-Identifier: Apache-2.0

// TestFlight refuses emoji in "What to Test" and CHANGELOG.md is full of them
// by design, so this runs on every iOS build. It has to remove exactly the
// characters Apple objects to and nothing else — over-stripping would quietly
// mangle the prose, and under-stripping fails the upload after the .ipa has
// already been transferred and processed.
import 'package:cux_ship/src/appstore/apple_notes.dart';
import 'package:test/test.dart';

void main() {
  group('stripForApple', () {
    test('leaves plain text completely alone', () {
      const plain = '- Tap the elevation profile to jump straight there';
      expect(needsStrippingForApple(plain), isFalse);
      expect(stripForApple(plain), plain);
    });

    test('removes every character Apple named', () {
      // Exactly the set from the 409: '[♀, ⚡, 🏔, 👋, 🚴, 🔒, ️]'.
      for (final rejected in ['♀', '⚡', '🏔', '👋', '🚴', '🔒', '️']) {
        expect(
          needsStrippingForApple('hello $rejected there'),
          isTrue,
          reason: 'did not detect $rejected',
        );
        expect(
          stripForApple('hello $rejected there'),
          'hello there',
          reason: 'did not strip $rejected',
        );
      }
    });

    test('handles a ZWJ sequence without leaving fragments', () {
      // 🚴‍♀️ is cyclist + ZWJ + female sign + variation selector: four runes
      // that have to go together or the leftovers are themselves rejected.
      final stripped = stripForApple('watch each of you 🚴‍♀️🚴 climb');
      expect(stripped, 'watch each of you climb');
      expect(needsStrippingForApple(stripped), isFalse);
    });

    test('keeps punctuation that is not an emoji', () {
      // The changelog uses em dashes and curly quotes, and an over-broad
      // filter would take them as well.
      const punctuation = 'never anything to wait for — and it’s “fine”';
      expect(needsStrippingForApple(punctuation), isFalse);
      expect(stripForApple(punctuation), punctuation);
    });

    test('keeps accented characters', () {
      const accented = '- Écoute, the café ride is 8 km';
      expect(stripForApple(accented), accented);
    });

    test('does not leave double spaces or trailing whitespace', () {
      expect(
        stripForApple('- Hello! 👋 First release.'),
        '- Hello! First release.',
      );
      expect(stripForApple('- Climbing hurts 🏔️'), '- Climbing hurts');
    });

    test('preserves line structure, including continuations', () {
      // Entries wrap onto indented continuation lines, and collapsing those
      // would run two bullets together.
      const notes =
          '- One 🚴\n'
          '  wrapped onto a second line\n'
          '- Two 🔒';
      expect(
        stripForApple(notes),
        '- One\n  wrapped onto a second line\n- Two',
      );
    });

    test('the result is always acceptable', () {
      const worst =
          '🎉🚀😍 - Clone yourself 🏔️😅 and hold the wheel 🚴‍♀️🚴 ⚡️';
      final stripped = stripForApple(worst);
      expect(needsStrippingForApple(stripped), isFalse);
      expect(stripped, contains('Clone yourself'));
      expect(stripped, contains('hold the wheel'));
    });

    test('is idempotent', () {
      final once = stripForApple('- Hello! 👋 First release.');
      expect(stripForApple(once), once);
    });
  });

  group('the App Store rejects these too, which this file used to deny', () {
    // The claim was that `appStoreVersionLocalizations.whatsNew` accepts
    // emoji, reasoning from published listings that carry them — evidence
    // about the *description*, a different field. It went unexercised because
    // the only prior submission was a first release, and a first release has
    // no "What's New" at all. A second release met it and 409'd after the
    // version had been created and the build attached.

    test('every character Apple named in the App Store rejection', () {
      // Verbatim from the error: 🧭, 🗺, 🌍, ️ — the last being a bare
      // variation selector, so this is not only about pictographs.
      for (final rejected in const ['🧭', '🗺', '🌍', '️']) {
        expect(
          needsStrippingForApple(rejected),
          isTrue,
          reason: 'U+${rejected.runes.first.toRadixString(16).toUpperCase()}',
        );
        expect(stripForApple('Explore $rejected the map'), 'Explore the map');
      }
    });

    test('the whole rejected set leaves readable copy behind', () {
      // What a shopper would have read, had the write succeeded.
      expect(
        stripForApple('🧭 Find your way 🗺 anywhere 🌍️ you ride'),
        'Find your way anywhere you ride',
      );
    });

    test('one rule, not two lists that drift', () {
      // TestFlight's rejection set and the App Store's both fall inside the
      // same ranges. If Apple ever proves the two fields differ, split it
      // then — on evidence, not in anticipation.
      const testFlightNamed = ['♀', '⚡', '🏔', '👋', '🚴', '🔒', '️'];
      const appStoreNamed = ['🧭', '🗺', '🌍', '️'];
      for (final character in [...testFlightNamed, ...appStoreNamed]) {
        expect(needsStrippingForApple(character), isTrue, reason: character);
      }
    });
  });
}
