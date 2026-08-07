// SPDX-License-Identifier: Apache-2.0
//
// The pause before something becomes public.
//
// Releasing is the one operation here that cannot be undone by running the
// command again: a build submitted for App Store review, or a track pointed at
// production, is visible to strangers before anyone notices the mistake. Since
// almost every argument is now inferred rather than typed, the confirmation is
// also where the inference is shown — it is the moment to notice that the
// bundle identifier came out wrong.
//
// Two rules that matter more than the prompt itself:
//
//   * --dry-run never prompts. It writes nothing, so there is nothing to
//     confirm, and a prompt there would train the habit of answering yes.
//   * Not a terminal and no --yes is a *refusal*, not an assumed yes. A CI job
//     that gained an interactive step should fail loudly rather than release on
//     a default. Passing --yes is how a script says it meant it.
import 'dart:io';

/// Asked before a write, with a summary of everything about to happen.
typedef Confirm = void Function(String summary);

/// Prints [summary] and waits for a yes, unless [assumeYes].
///
/// Exits rather than returning false: every caller would otherwise have to
/// decide what a no means, and it always means the same thing.
void confirmOrExit(String summary, {required bool assumeYes}) {
  stdout.writeln(summary);

  if (assumeYes) {
    stdout.writeln('--yes given, proceeding.');
    return;
  }

  if (!stdin.hasTerminal) {
    stderr.writeln(
      'cux_ship: refusing to release unattended.\n'
      '  Nothing here is reversible by re-running it, and there is no terminal\n'
      '  to ask at. Pass --yes if this is a script that means it.',
    );
    exit(1);
  }

  stdout.write('Proceed? [y/N] ');
  final answer = stdin.readLineSync()?.trim().toLowerCase();
  if (answer != 'y' && answer != 'yes') {
    stdout.writeln('Nothing was done.');
    exit(1);
  }
}
