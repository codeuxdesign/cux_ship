// SPDX-License-Identifier: Apache-2.0

/// The command, as a library, so that a consumer can launch it without first
/// working out where this package resolved to.
///
/// **This is `bin/cux_ship.dart`'s body, moved, and the move is for one
/// consumer shape that had no good answer.** `publishing-from-a-workspace.md`
/// establishes that `dart <entry>` — no `run` — is how a pinning project keeps
/// the workspace warning out of its logs, and then has to tell that project to
/// pass `<checkout>/cux_ship/bin/cux_ship.dart`. For a git pin that path is
/// writable by hand. For a **hosted** pin it is a directory in the pub cache
/// named for a version, so the launcher has to read `rootUri` out of
/// `package_config.json` to find it — and the obvious way to do that is a
/// regex, which gets three things wrong: `"name": "cux_ship"` is a prefix of
/// `"name": "cux_ship_verify"`, a `rootUri` may be relative, and a `file:` URI
/// is percent-encoded. A consumer hit all three.
///
/// Declaring the entry here removes the question rather than answering it. The
/// VM resolves a `package:` script URI through `--packages`, so the launcher
/// becomes a path it already knows:
///
/// ```bash
/// dart --packages=<checkout>/.dart_tool/package_config.json \
///      package:cux_ship/cli.dart …
/// ```
///
/// **`main` rather than a named function, deliberately.** The VM looks for
/// `main` in the library it is given as the script, so the name is what makes
/// the line above work at all — a `cuxShipMain` would still need a file
/// somewhere to call it, which is the thing being removed.
///
/// **It does not cover `dart compile kernel`, which refuses a `package:` URI**
/// (`"package:cux_ship/cli.dart" file not found`, where the plain `dart` above
/// resolves it). A consumer caching a snapshot — the one here went from ~4 s a
/// run to ~420 ms — still needs a real file, but it can now be a one-line
/// `export` of this library committed in its own tree, rather than a path
/// recovered from the pub cache.
library;

import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cux_ship/runner.dart';
import 'package:cux_ship/src/provenance.dart'
    show UploadCollisionException, uploadCollisionExit;
import 'package:cux_ship/src/release.dart' show ReleaseException;

/// Runs the command tree over [argv], mapping the exceptions a caller should
/// read onto exit codes.
///
/// **The mapping lives here rather than in each launcher**, which is the other
/// half of why this is a library. A consumer that wrote its own entry would
/// copy these three `catch` clauses, pinned to the exceptions that existed the
/// day it copied them — and the first one is the loudest error this tool has.
Future<void> main(List<String> argv) async {
  try {
    await buildRunner().run(argv);
  } on UploadCollisionException catch (e) {
    // **Caught before ReleaseException, which it extends.** One build number
    // naming two commits is the loudest error this tool has, and it is the one
    // most likely to be swallowed: a release wrapper calls the upload under
    // `|| exitCode=$?` on purpose, so that re-running a release for a build the
    // store already holds is a no-op. Without a code of its own, a collision
    // exits through that same path as the tolerable kind and the release
    // finishes green having published nothing and said so to nobody.
    stderr.writeln('cux_ship: ${e.message}');
    exit(uploadCollisionExit);
  } on ReleaseException catch (e) {
    // Something the caller should read and act on, not a bug. Printed rather
    // than thrown, because an unhandled Dart exception on a release path buries
    // the sentence that matters under a stack trace nobody needs.
    stderr.writeln('cux_ship: ${e.message}');
    exit(1);
  } on UsageException catch (e) {
    // Not a crash: a mistyped command or a missing required option. The usage
    // goes to stderr so that piping a `--print-*` subcommand's output somewhere
    // does not silently swallow the reason it produced nothing.
    stderr.writeln(e);
    exit(64); // EX_USAGE
  }
}
