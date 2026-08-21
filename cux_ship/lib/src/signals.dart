// SPDX-License-Identifier: Apache-2.0
//
// Watching for a terminating signal, on platforms that have the one you asked
// for.
//
// **This exists because the watch failed silently.** Both `secrets exec` and
// `keychain exec` install a signal watch so that a Ctrl-C cleans up rather than
// leaving a decrypted private key in a temp directory — the whole reason
// neither uses `exec()` to replace the process. On Windows,
// `ProcessSignal.sigterm.watch()` raises `SignalException: Failed to listen for
// SIGTERM ... The request is not supported`, asynchronously, and the command
// carried on running.
//
// So the guard that protects the key was not armed, the run did not stop, and
// nothing said so. That is the shape this repository keeps finding, arriving
// this time in the cleanup path rather than in a check.
//
// **What is actually lost on Windows is close to nothing, and saying that
// matters more than it sounds.** Windows has no POSIX `SIGTERM` delivery;
// `SIGINT` is what Ctrl-C sends and Dart does support watching it there. So the
// protection the watch exists for is intact, and the exception was the platform
// objecting to a signal it never had rather than to the discipline. Guarding it
// keeps the discipline and drops a request that could not be served.
import 'dart:async';
import 'dart:io';

/// The interrupt signals worth watching on this platform.
///
/// `SIGINT` everywhere — it is what Ctrl-C sends and Dart supports it on
/// Windows as well as on POSIX. `SIGTERM` only where the platform can deliver
/// it, which is everywhere except Windows.
List<ProcessSignal> terminatingSignals() => [
  ProcessSignal.sigint,
  if (!Platform.isWindows) ProcessSignal.sigterm,
];

/// Watches every signal in [terminatingSignals], calling [onSignal] for each.
///
/// Returns the subscriptions so the caller can cancel them — a watch that
/// outlives the thing it was protecting keeps the VM alive.
///
/// A `SignalException` from a platform that rejects a signal this list thought
/// it had is rethrown rather than swallowed. The point of the list is that the
/// question is answered *before* the watch, so an exception here means the list
/// is wrong and that is worth knowing loudly — quietly continuing is how the
/// unarmed watch got shipped in the first place.
List<StreamSubscription<ProcessSignal>> watchTerminating(
  void Function(ProcessSignal) onSignal,
) => [
  for (final signal in terminatingSignals()) signal.watch().listen(onSignal),
];
