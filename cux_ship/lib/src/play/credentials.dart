// SPDX-License-Identifier: Apache-2.0
//
// Loading the Play service account, in a form a library can call.
//
// Split out of cli.dart because the version there ends in `exit(1)`, which is
// correct for a command and unusable from anything that has a caller: an
// in-process read cannot have "no credentials" take the whole process down.
// The CLI still exits — it catches the [StateError] and prints it — so the two
// disagree about how to report the failure and about nothing else.
import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';

/// The variable holding the *path* to the service account JSON, never the JSON
/// itself.
///
/// The value used to travel in the environment, which is how a Google private
/// key ended up in public CI logs: anything that echoes its environment — an
/// xcode script build phase, for one — prints whatever a variable holds. A
/// filename in a temp directory that has already been removed is not worth
/// printing.
const playServiceAccountVar = 'GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH';

/// The service account [playServiceAccountVar] points at.
///
/// Throws [StateError] with a message meant to be printed as-is when the
/// variable is unset, points nowhere, or names a file that is not JSON.
ServiceAccountCredentials loadPlayServiceAccount() {
  final path = Platform.environment[playServiceAccountVar];
  if (path == null || path.trim().isEmpty) {
    throw StateError(
      '$playServiceAccountVar is not set.\n'
      '  It holds the path to the Google Play service account JSON. Run this\n'
      '  through `cux_ship secrets exec`, which writes the file and sets it.',
    );
  }
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError(
      '$playServiceAccountVar points at $path, which does not exist.',
    );
  }
  try {
    return ServiceAccountCredentials.fromJson(
      jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
    );
  } on FormatException catch (e) {
    throw StateError('the file at $path is not valid JSON: ${e.message}');
  }
}
