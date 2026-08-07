// SPDX-License-Identifier: Apache-2.0
//
// The one executable. Named after its package so that `dart run cux_ship` and
// `dart pub global activate cux_ship` both work without naming it twice.
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cux_ship/runner.dart';

Future<void> main(List<String> argv) async {
  try {
    await buildRunner().run(argv);
  } on UsageException catch (e) {
    // Not a crash: a mistyped command or a missing required option. The usage
    // goes to stderr so that piping a `--print-*` subcommand's output somewhere
    // does not silently swallow the reason it produced nothing.
    stderr.writeln(e);
    exit(64); // EX_USAGE
  }
}
