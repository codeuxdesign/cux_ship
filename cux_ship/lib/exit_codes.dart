// SPDX-License-Identifier: Apache-2.0
//
// What `cux_ship` exits with, as names.
//
//   import 'package:cux_ship/exit_codes.dart';
//
//   final result = await Process.run('cux_ship', [...]);
//   if (result.exitCode == noSuchVersionExit) {
//     // Apple holds no such version yet — an ordinary state, not a failure.
//   }
//
// **Its own library rather than a corner of `documents.dart`.** These belong
// to the contract of *spawning* the binary: a caller reads the status and then
// decodes stdout, and the two halves are the same conversation. But
// `documents.dart` states a precise rule about itself — the field names are the
// JSON keys, and its dartdoc is the published format — which a handful of
// integers does not fit. A caller that only branches on status, and never
// decodes a document, should not have to pull in the document classes to name
// a number.
//
// **Exported because a consumer was writing the digit with a comment where the
// name belongs.** They reported it ranked below everything else and were right
// that it is readability rather than correctness — the forward rule in
// README.md means an existing code never changes meaning, so a hard-coded 5
// stays right. It is the same omission class as the document types that were
// unexported until somebody outside tried to name one, which is why it was
// worth closing rather than noting.
//
// **`exit_codes_test.dart` asserts this list is complete**, by reading the
// source for every `…Exit` constant and failing if one is missing here. The
// point is the class rather than the instance: a sixth code added without
// being exported fails there rather than in a consumer's package a release
// later.
//
// README.md's "Exit codes" section is the prose version, including the two
// things no constant can carry: 64 comes from the argument parser rather than
// from any of these, and `secrets exec` / `keychain exec` return their child's
// status, so under those two commands none of this applies.
library;

export 'src/appstore/app_store.dart'
    show noSuchVersionExit, previewsPendingExit;
export 'src/appstore/flatten_cli.dart' show needsFlatteningExit;
export 'src/provenance.dart' show uploadCollisionExit;
