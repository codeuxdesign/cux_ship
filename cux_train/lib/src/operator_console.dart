/// The operator's half of §6.1: the keys, and whether anybody is there to
/// press one.
///
/// **This is an interface before it is an implementation, because the thing
/// worth testing is what the run does with each answer** — and a test that had
/// to drive a real terminal could assert none of it. The real one reads
/// `stdin`; a test hands the run a list of answers.
///
/// **`attached` is asked separately from `ask`, and that is §6.1's rule rather
/// than a convenience.** "Off a terminal, a manual destination is reported as
/// pending and the run exits non-zero having done everything else" — so the
/// run has to know *before* printing an instruction that nobody will answer
/// it. Finding out by reading EOF would mean the instruction was already
/// printed, and a CI log full of console instructions nobody can act on is the
/// report that reads as work having been done.
library;

import 'dart:io';

/// What the operator pressed at a manual step.
enum ManualAnswer {
  /// `d` — the step was performed; record it and move on.
  done,

  /// `s` — leave it unrecorded, so the next run stops here again.
  skip,

  /// `f` — it was attempted and the destination refused it.
  ///
  /// **Not the same as [skip], and §6.1 says why it has to exist**: `s` alone
  /// makes "the console rejected the binary" look exactly like "nobody has
  /// looked yet".
  failed,

  /// `q` — end the run, keeping everything recorded so far.
  quit,
}

/// Where a manual step asks its question.
abstract class OperatorConsole {
  /// Whether there is somebody to answer.
  bool get attached;

  /// The key the operator pressed, or null at end of input.
  ManualAnswer? ask();

  /// The line of why that a refusal is not written without.
  ///
  /// Returns null if the operator gave none, which the caller treats as
  /// withdrawing the refusal rather than as an empty reason — see
  /// `writePromotion`, which refuses an unexplained one outright.
  String? askNote();

  /// Asks [question], answering null at end of input.
  ///
  /// **Silence is not yes.** Only a typed `y` or `yes` agrees; anything else,
  /// a bare return included, declines. This is the question in front of every
  /// store upload in the run, so the default has to be the one that costs
  /// nothing.
  bool? confirm(String question);
}

/// The real console, reading `stdin`.
class StdioConsole implements OperatorConsole {
  StdioConsole({StringSink? output}) : _output = output ?? stdout;

  final StringSink _output;

  @override
  bool get attached => stdin.hasTerminal;

  @override
  ManualAnswer? ask() {
    while (true) {
      _output.write('  [d]one   [s]kip for now   [f]ailed   [q]uit — ');
      _output.write('nothing after this is lost\n  > ');
      final line = stdin.readLineSync();
      if (line == null) {
        // **The newline the operator did not type.** Input ended at the `> `
        // prompt, so the cursor is still on it, and without this the run's
        // closing report starts halfway along the prompt line.
        _output.write('\n');
        return null;
      }
      final answer = answerFor(line);
      if (answer != null) {
        return answer;
      }
      // **An unrecognised key asks again rather than guessing.** Every one of
      // the four does something different and two of them write a permanent
      // tag, so the cost of reading `D` as `d` is nothing and the cost of
      // reading anything else as the nearest key is a record that is wrong.
      _output.write('  `${line.trim()}` is not one of d, s, f or q.\n');
    }
  }

  @override
  String? askNote() {
    _output.write('  why — one line, which is what makes the record usable:\n');
    _output.write('  > ');
    final line = stdin.readLineSync();
    if (line == null || line.trim().isEmpty) {
      return null;
    }
    return line.trim();
  }

  @override
  bool? confirm(String question) {
    _output.write('$question [y/N] ');
    final line = stdin.readLineSync();
    if (line == null) {
      return null;
    }
    final said = line.trim().toLowerCase();
    return said == 'y' || said == 'yes';
  }
}

/// The key [line] names, or null.
///
/// Case and surrounding space are forgiven; nothing else is. The whole word is
/// accepted too, because `done` is what somebody who has not read the prompt
/// closely will type.
ManualAnswer? answerFor(String line) => switch (line.trim().toLowerCase()) {
  'd' || 'done' => ManualAnswer.done,
  's' || 'skip' => ManualAnswer.skip,
  'f' || 'failed' => ManualAnswer.failed,
  'q' || 'quit' => ManualAnswer.quit,
  _ => null,
};
