// TestFlight refuses emoji in "What to Test" and CHANGELOG.md is full of them
// by design, so this runs on every iOS build. It has to remove exactly the
// characters Apple objects to and nothing else — over-stripping would quietly
// mangle the prose, and under-stripping fails the upload after the .ipa has
// already been transferred and processed.
import 'package:cux_ship_appstore/testflight_notes.dart';
import 'package:test/test.dart';

void main() {
  group('stripForTestFlight', () {
    test('leaves plain text completely alone', () {
      const plain = '- Tap the elevation profile to jump straight there';
      expect(needsStrippingForTestFlight(plain), isFalse);
      expect(stripForTestFlight(plain), plain);
    });

    test('removes every character Apple named', () {
      // Exactly the set from the 409: '[♀, ⚡, 🏔, 👋, 🚴, 🔒, ️]'.
      for (final rejected in ['♀', '⚡', '🏔', '👋', '🚴', '🔒', '️']) {
        expect(
          needsStrippingForTestFlight('hello $rejected there'),
          isTrue,
          reason: 'did not detect $rejected',
        );
        expect(
          stripForTestFlight('hello $rejected there'),
          'hello there',
          reason: 'did not strip $rejected',
        );
      }
    });

    test('handles a ZWJ sequence without leaving fragments', () {
      // 🚴‍♀️ is cyclist + ZWJ + female sign + variation selector: four runes
      // that have to go together or the leftovers are themselves rejected.
      final stripped = stripForTestFlight('watch each of you 🚴‍♀️🚴 climb');
      expect(stripped, 'watch each of you climb');
      expect(needsStrippingForTestFlight(stripped), isFalse);
    });

    test('keeps punctuation that is not an emoji', () {
      // The changelog uses em dashes and curly quotes, and an over-broad
      // filter would take them as well.
      const punctuation = 'never anything to wait for — and it’s “fine”';
      expect(needsStrippingForTestFlight(punctuation), isFalse);
      expect(stripForTestFlight(punctuation), punctuation);
    });

    test('keeps accented characters', () {
      const accented = '- Écoute, the café ride is 8 km';
      expect(stripForTestFlight(accented), accented);
    });

    test('does not leave double spaces or trailing whitespace', () {
      expect(
        stripForTestFlight('- Hello! 👋 First release.'),
        '- Hello! First release.',
      );
      expect(stripForTestFlight('- Climbing hurts 🏔️'), '- Climbing hurts');
    });

    test('preserves line structure, including continuations', () {
      // Entries wrap onto indented continuation lines, and collapsing those
      // would run two bullets together.
      const notes =
          '- One 🚴\n'
          '  wrapped onto a second line\n'
          '- Two 🔒';
      expect(
        stripForTestFlight(notes),
        '- One\n  wrapped onto a second line\n- Two',
      );
    });

    test('the result is always acceptable', () {
      const worst =
          '🎉🚀😍 - Clone yourself 🏔️😅 and hold the wheel 🚴‍♀️🚴 ⚡️';
      final stripped = stripForTestFlight(worst);
      expect(needsStrippingForTestFlight(stripped), isFalse);
      expect(stripped, contains('Clone yourself'));
      expect(stripped, contains('hold the wheel'));
    });

    test('is idempotent', () {
      final once = stripForTestFlight('- Hello! 👋 First release.');
      expect(stripForTestFlight(once), once);
    });
  });
}
