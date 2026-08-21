// SPDX-License-Identifier: Apache-2.0
//
// The one executable. Named after its package so that `dart run cux_ship` and
// `dart pub global activate cux_ship` both work without naming it twice.
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cux_ship/runner.dart';
import 'package:cux_ship/src/provenance.dart'
    show UploadCollisionException, uploadCollisionExit;
import 'package:cux_ship/src/release.dart' show ReleaseException;

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
