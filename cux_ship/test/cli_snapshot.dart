// SPDX-License-Identifier: Apache-2.0
//
// The CLI, compiled once, for the suites that spawn it.
//
// Four suites here run the real binary in a child process, because what they
// pin cannot be reached any other way: a command that dies in argument handling
// before it reaches its body, an exit code, an environment that survives into a
// grandchild. Those are worth the price of a subprocess.
//
// The price was being paid per *invocation*. `dart bin/cux_ship.dart` compiles
// the entire program from source before it runs a line of it — about 2.7
// seconds, against roughly 0.13 to start the same program from a kernel
// snapshot. Some seventy invocations across those four suites made spawning the
// CLI 140 of the 165 seconds the package took, and none of that time tested
// anything: it was the same compile, seventy times.
//
// So compile it once and spawn that. The snapshot is what `dart` produces from
// the source anyway — the same kernel, kept instead of thrown away — and
// `--enable-asserts` governs it exactly as it governs the source, which is what
// makes this a swap rather than a weakening.
//
// **Rebuilt every run, never cached across runs.** A snapshot keyed on
// timestamps or hashes is a snapshot that can be stale, and a stale one tests
// code nobody has any more while reporting on code they do — the vacuous pass
// this package keeps having to design against. Compiling costs about a second
// and a half and happens once per suite in parallel; that is not worth a
// staleness bug.
import 'dart:io';

/// The entrypoint, resolved against both layouts — CI runs `dart test` from the
/// package directory, a developer runs it from the workspace root, and a path
/// that does not resolve would make every case pass while running nothing.
final String cliSource = () {
  for (final candidate in ['bin/cux_ship.dart', 'cux_ship/bin/cux_ship.dart']) {
    final file = File(candidate);
    if (file.existsSync()) {
      return file.absolute.path;
    }
  }
  throw StateError(
    'cannot find bin/cux_ship.dart from ${Directory.current.path} — these '
    'tests spawn the CLI, and a path that does not resolve makes every one of '
    'them pass without running anything',
  );
}();

/// A kernel snapshot of [cliSource], to spawn in place of it.
///
/// Pass it to `dart` exactly where the source path went:
/// `Process.runSync(Platform.resolvedExecutable, ['--enable-asserts',
/// cliSnapshot, ...args])`.
///
/// **Carry over whatever flags that call site already had, rather than these.**
/// Three of the four suites pass `--enable-asserts` because they always did;
/// secrets_only_nesting_test.dart does not, because it spawned `dart run`,
/// which does not enable them either. Adding the flag there would be a change
/// to what that suite runs, dressed as making it consistent with this comment.
final String cliSnapshot = _compile();

String _compile() {
  // Beside the source, under the package's own build directory, so it lands on
  // the same filesystem as the rename below — and so it is gitignored, and goes
  // when `.dart_tool` does, rather than accumulating in the system temp
  // directory. Nothing prunes it on its own: `dart pub` does not tidy
  // directories it did not create. It is 25MB, one shared copy rather than one
  // per suite, which is what keeps that acceptable.
  final root = File(cliSource).parent.parent.path;
  final dir = Directory('$root/.dart_tool/cux_ship_test')
    ..createSync(recursive: true);
  final snapshot = '${dir.path}/cli.dill';

  // Suites run in parallel and all compile, so each writes somewhere of its own
  // and renames the result into place. Rename is atomic and both writers
  // produce the same bytes from the same source, so whoever lands last is
  // still correct, and a suite already spawning the previous one keeps its
  // inode — whereas compiling straight to the shared path would let two
  // writers interleave into a corrupt snapshot.
  //
  // **The scratch name comes from `createTempSync`, and may not come from
  // `pid`.** It did, and CI failed where this machine had not: `dart test` runs
  // VM suites as *isolates in one process*, so every suite reports the same
  // pid, and two of them chose the same scratch path. The first renamed it
  // away; the second's rename found nothing and threw `PathNotFoundException`.
  // A process-wide identifier cannot separate writers that are not processes,
  // and a race that resolves on timing is exactly the kind that stays green on
  // a laptop.
  final scratch = dir.createTempSync('compile-');
  // In `finally`, because every exit from here leaks 25MB otherwise, and the
  // names are unique by construction — so a directory left behind is one
  // nothing will ever reuse or reclaim. The throw below is the reachable case;
  // a failing rename is the one worth covering without being able to provoke.
  try {
    final compiled = '${scratch.path}/cli.dill';
    final result = Process.runSync(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      cliSource,
      '-o',
      compiled,
    ]);
    // Loudly. Falling back to spawning the source here would be slow but
    // correct, which is the problem: nobody would ever notice it had happened.
    if (result.exitCode != 0) {
      throw StateError(
        'could not compile $cliSource to a kernel snapshot '
        '(exit ${result.exitCode})\n${result.stdout}${result.stderr}',
      );
    }
    File(compiled).renameSync(snapshot);
    return snapshot;
  } finally {
    scratch.deleteSync(recursive: true);
  }
}
