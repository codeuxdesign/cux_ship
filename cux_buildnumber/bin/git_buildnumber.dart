import 'dart:io';

import 'package:cux_buildnumber/cux_buildnumber.dart';

Future<void> main(List<String> args) async {
  exitCode = await runGitBuildNumber(args);
}
