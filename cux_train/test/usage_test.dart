// What the command does with an invocation it cannot run.
//
// **The exit code is the contract, not the text.** Every consumer of this
// package drives it from a shell script or a CI step, where a misspelled
// command that exits 0 is a step that silently did not run — the failure
// `docs/design/release-train.md` §5.1 is arranged against, where the train
// orders a destination it never actually reached. So the cases below assert the
// code and the stream, and only enough of the text to show it is this program's
// usage rather than someone else's.
import 'dart:io';

import 'package:cux_train/cux_train.dart';
import 'package:test/test.dart';

final String _packageConfig = () {
  for (final candidate in [
    '../.dart_tool/package_config.json',
    '.dart_tool/package_config.json',
  ]) {
    final file = File(candidate);
    if (file.existsSync()) {
      return file.absolute.path;
    }
  }
  throw StateError(
    'cannot find the workspace package_config.json from '
    '${Directory.current.path} — run dart pub get at the workspace root',
  );
}();

ProcessResult _run(List<String> args) => Process.runSync(
  Platform.resolvedExecutable,
  ['--packages=$_packageConfig', 'package:cux_train/cli.dart', ...args],
);

void main() {
  group('an invocation the command cannot run', () {
    test('exits 64 and says so on stderr', () {
      final result = _run(['promote']);

      // 64, from `sysexits.h`, the same code `cux_ship` gives a
      // `UsageException`. A consumer distinguishing "you asked for something
      // that does not exist" from "the step failed" reads this number.
      expect(result.exitCode, usageExit);
      expect(
        result.exitCode,
        64,
        reason: 'usageExit must stay sysexits EX_USAGE',
      );
      expect(result.stderr, contains('unknown command: promote'));
      // The usage text goes with it, so the operator does not have to run a
      // second command to find out what was available.
      expect(result.stderr, contains('usage: cux_train'));
    });

    test('keeps stdout clean, because a release log reads it', () {
      final result = _run(['promote']);

      // **The refusal is asserted before the emptiness, because an empty
      // stdout passes for the wrong reason.** Deleting `lib/cli.dart` was the
      // first mutation run against this suite, and this case stayed green
      // while the other seven went red: with no entry to launch, the VM
      // writes its error to stderr and stdout is empty, which satisfied
      // "stdout is clean" with the program gone. The same vacuous shape as the
      // one `cux_ship`'s `cli_library_entry_test.dart` records, found the same
      // way. Re-run after this line was added: red, as it should be.
      expect(result.exitCode, usageExit, reason: result.stderr.toString());
      expect(result.stderr, contains('unknown command'));

      // **The stream matters as much as the code.** A consumer that captures
      // stdout for a step's result and lets stderr through to the log would
      // otherwise record help text as the step's output.
      expect(result.stdout, isEmpty);
    });
  });

  group('help', () {
    test('exits 0 and prints the usage on stdout', () {
      final result = _run(['help']);

      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(result.stdout, contains('usage: cux_train'));
      expect(result.stderr, isEmpty);
    });

    test('is what a bare invocation does too', () {
      // Bare and `help` agree, so an operator who types the command to see
      // what it offers is not treated as having made a mistake.
      final bare = _run([]);
      final asked = _run(['help']);

      expect(bare.exitCode, 0, reason: bare.stderr.toString());
      expect(asked.exitCode, 0);
      expect(bare.stdout, asked.stdout);
      expect(bare.stdout, isNotEmpty);
    });

    test('says plainly that no release commands exist yet', () {
      // The one claim in the text worth a test: this package is a member with
      // no train in it, and the usage must not read as though it can ship
      // something. The move deletes this case along with the sentence.
      final result = _run(['help']);

      expect(result.stdout, contains('No release commands yet'));
    });
  });
}
