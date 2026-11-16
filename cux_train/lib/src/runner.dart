/// The command tree, built as a value so that a caller can run it in process.
///
/// **The same shape as `cux_ship`'s `lib/runner.dart`, for the same reason**:
/// the entry point in `cli.dart` is a thin mapping from exceptions onto exit
/// codes, and everything above it is a `CommandRunner` a test can drive
/// directly. A test that has to spawn a process to find out what a verb does
/// pays a VM start for every case and can assert only on text.
///
/// **No global options.** §3 of `docs/design/authpass-on-the-train.md` lists
/// `--build`, `--dry-run`, `--yes` and `--verbose` as the flags that carry
/// over from the donor, and it would be easy to read that as "declare the four
/// on the runner". Two of them write — `--dry-run` and `--yes` are about
/// spending something — and `status` spends nothing, so on this verb they
/// would be flags that do nothing. The donor's rule, which §3 and §4 both
/// apply, is that a flag which would do nothing is refused rather than
/// dropped, and the cheapest way to keep it is not to offer one: an option
/// nobody declared is one the parser refuses with a 64. They arrive with the
/// verbs that act.
///
/// **That is the whole reason, and position is not one.** `package:args`
/// accepts a global option on either side of the command — a command's parser
/// hands an option it does not know to its parent — so `cux_train status
/// --build N` would work with `--build` declared here. What a global
/// declaration costs is the other thing: every verb then accepts the flag
/// whether or not it reads it, which is the dropped flag again.
library;

import 'package:args/command_runner.dart';

import 'beta_command.dart';
import 'ready_command.dart';
import 'status_command.dart';

/// Builds the command tree.
///
/// [output] is where a verb's result goes, and defaults to `stdout` — a test
/// passes a buffer. Errors never come through here: they are exceptions, and
/// `cli.dart` is the only thing that decides what a process does with one.
CommandRunner<void> buildRunner({StringSink? output}) =>
    CommandRunner<void>(
        'cux_train',
        // **This line is asserted by `cli_library_entry_test.dart`**, which is
        // how a consumer's launcher proves it reached this program rather than
        // some other library that happened to have a `main`.
        'cux_train — order the steps of a release.',
      )
      ..addCommand(StatusCommand(output: output))
      ..addCommand(ReadyCommand(output: output))
      ..addCommand(BetaCommand(output: output));
