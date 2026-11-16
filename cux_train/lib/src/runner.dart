/// The command tree, built as a value so that a caller can run it in process.
///
/// **The same shape as `cux_ship`'s `lib/runner.dart`, for the same reason**:
/// the entry point in `cli.dart` is a thin mapping from exceptions onto exit
/// codes, and everything above it is a `CommandRunner` a test can drive
/// directly. A test that has to spawn a process to find out what a verb does
/// pays a VM start for every case and can assert only on text.
///
/// **No global options.** §3 lists `--build`, `--dry-run`, `--yes` and
/// `--verbose` as the flags that carry over from the donor, and it would be
/// easy to read that as "declare the four on the runner". Two of them write —
/// `--dry-run` and `--yes` are about spending something — and `status` spends
/// nothing, so on this verb they would be flags that do nothing. §4's rule is
/// that a flag which would do nothing is refused rather than dropped, and the
/// cheapest way to keep it is not to offer one. They arrive with the verbs
/// that act. `package:args` also requires a global option *before* the
/// command, so a global `--build` would be typed `cux_train --build N status`,
/// which is not what either repository's operators type.
library;

import 'package:args/command_runner.dart';

import 'status_command.dart';

/// Builds the command tree.
///
/// [output] is where a verb's result goes, and defaults to `stdout` — a test
/// passes a buffer. Errors never come through here: they are exceptions, and
/// `cli.dart` is the only thing that decides what a process does with one.
CommandRunner<void> buildRunner({StringSink? output}) => CommandRunner<void>(
  'cux_train',
  // **This line is asserted by `cli_library_entry_test.dart`**, which is
  // how a consumer's launcher proves it reached this program rather than
  // some other library that happened to have a `main`.
  'cux_train — order the steps of a release.',
)..addCommand(StatusCommand(output: output));
