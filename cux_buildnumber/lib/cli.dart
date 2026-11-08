/// The `bin/` entry, as a library, so that a consumer can launch it without
/// first working out where this package resolved to.
///
/// **The same move as `cux_ship`'s `lib/cli.dart`, for the same consumer and
/// the same reason.** A project that pins this package and wants a clean log
/// invokes the entry directly rather than through `dart run` — see
/// `docs/design/publishing-from-a-workspace.md` for why — and then has to name
/// a path. For a hosted pin that path is a version-stamped directory under
/// `~/.pub-cache`, so the launcher ends up reading `rootUri` out of
/// `package_config.json` to find it. The VM resolves a `package:` script URI
/// through `--packages`, so naming the library removes the question:
///
/// ```bash
/// dart --packages=<checkout>/.dart_tool/package_config.json \
///      package:cux_buildnumber/cli.dart generate
/// ```
///
/// **Separate from `cux_buildnumber.dart` rather than a `main` added to it.**
/// That library is the package's API — three `export`s and nothing else — and a
/// `main` in it would make every importer's library carry an entry point it did
/// not ask for. This file is the executable, and it is the only thing here that
/// knows about process exit.
library;

import 'dart:io';

import 'package:cux_buildnumber/cux_buildnumber.dart';

/// Runs the tool over [args] and sets the process exit code from it.
///
/// `exitCode` rather than `exit()`, as `bin/git_buildnumber.dart` has always
/// done: the tool writes the allocated number to stdout and an immediate
/// `exit()` can truncate a pipe that has not drained.
Future<void> main(List<String> args) async {
  exitCode = await runGitBuildNumber(args);
}
