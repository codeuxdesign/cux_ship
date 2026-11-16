// The four keys of §6.1. Two of them write a tag that nothing in this package
// can clear, so what this file is really about is everything that must *not*
// be read as one of those two.
import 'package:cux_train/cux_train.dart';
import 'package:test/test.dart';

void main() {
  test('reads the four keys', () {
    expect(answerFor('d'), ManualAnswer.done);
    expect(answerFor('s'), ManualAnswer.skip);
    expect(answerFor('f'), ManualAnswer.failed);
    expect(answerFor('q'), ManualAnswer.quit);
  });

  test('reads the whole word, which is what gets typed', () {
    expect(answerFor('done'), ManualAnswer.done);
    expect(answerFor('skip'), ManualAnswer.skip);
    expect(answerFor('failed'), ManualAnswer.failed);
    expect(answerFor('quit'), ManualAnswer.quit);
  });

  test('forgives case and surrounding space', () {
    expect(answerFor('  D  '), ManualAnswer.done);
    expect(answerFor('Quit'), ManualAnswer.quit);
  });

  test('a bare return is not an answer', () {
    // The key under a person's finger when they are reading rather than
    // deciding. Recording it as `done` would assert a console submission that
    // never happened.
    expect(answerFor(''), isNull);
    expect(answerFor('   '), isNull);
  });

  test('nothing else is guessed at', () {
    // `y` is the tempting one: it is the answer to the confirmation a few
    // lines earlier, and it is not one of these four.
    for (final typed in ['y', 'yes', 'n', 'x', 'ds', 'd s', '1']) {
      expect(answerFor(typed), isNull, reason: '`$typed` is not a key');
    }
  });
}
