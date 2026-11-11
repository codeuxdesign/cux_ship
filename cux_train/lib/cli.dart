/// The `bin/` entry, as a library, so that a consumer can launch it without
/// first working out where this package resolved to.
///
/// **The same move as `cux_ship`'s and `cux_buildnumber`'s `lib/cli.dart`, for
/// the same consumer and the same reason**, and made here on the first commit
/// rather than retrofitted: a project that pins this package and wants a clean
/// log invokes the entry directly rather than through `dart run`, and then has
/// to name a path. For a hosted pin that path is a version-stamped directory
/// under `~/.pub-cache`, so the launcher ends up reading `rootUri` out of
/// `package_config.json` to find it. The VM resolves a `package:` script URI
/// through `--packages`, so naming the library removes the question:
///
/// ```bash
/// dart --packages=<checkout>/.dart_tool/package_config.json \
///      package:cux_train/cli.dart help
/// ```
///
/// **Separate from `cux_train.dart` rather than a `main` added to it.** That
/// library is the package's API, and a `main` in it would make every importer's
/// library carry an entry point it did not ask for. This file is the
/// executable, and it is the only thing here that knows about process exit.
library;

import 'dart:io';

import 'package:cux_train/cux_train.dart';

/// Runs the command over [args] and sets the process exit code from it.
///
/// `exitCode` rather than `exit()`, as `cux_buildnumber`'s entry does: an
/// immediate `exit()` can truncate a pipe that has not drained, and a release
/// tool's output is read by other programs. `cux_ship`'s own `cli.dart` calls
/// `exit()` and is marked as not for in-process callers; this package has no
/// reason to inherit that.
Future<void> main(List<String> args) async {
  const help = {'help', '--help', '-h'};
  if (args.isEmpty || (args.length == 1 && help.contains(args.single))) {
    stdout.write(usageText());
    return;
  }
  // **To stderr, with the usage text, and a non-zero code.** A command that
  // cannot be understood is not output somebody wants on stdout — a consumer
  // piping this into a release log would otherwise get help text where a step's
  // result belongs, and a zero exit would let a misspelled step pass for a
  // step that ran.
  stderr.writeln('cux_train: unknown command: ${args.join(' ')}');
  stderr.write(usageText());
  exitCode = usageExit;
}
