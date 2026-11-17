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

import 'package:args/command_runner.dart';
import 'package:cux_ship/provenance.dart' show ReleaseException;
import 'package:cux_train/cux_train.dart';
import 'package:cux_train/runner.dart';

/// Runs the command over [args] and sets the process exit code from it.
///
/// `exitCode` rather than `exit()`, as `cux_buildnumber`'s entry does: an
/// immediate `exit()` can truncate a pipe that has not drained, and a release
/// tool's output is read by other programs. `cux_ship`'s own `cli.dart` calls
/// `exit()` and is marked as not for in-process callers; this package has no
/// reason to inherit that.
///
/// **Every clause below prints a sentence and no stack trace**, and anything
/// no clause names still gets the stack trace — the list is the states
/// somebody is expected to meet, not a catch-all, so that a bug stays loud.
/// These are states a release operator is meant to read and act on — a table
/// that is not there, a candidate that was not named, a ref somebody wrote by
/// hand that this grammar cannot read — and an unhandled Dart exception buries
/// the one line that matters under a frame list nobody needs. `cux_ship`'s
/// entry makes the same trade for the same reason.
Future<void> main(List<String> args) async {
  try {
    await buildRunner().run(args);
  } on UsageException catch (e) {
    // **To stderr, with the usage text, and a non-zero code.** A command that
    // cannot be understood is not output somebody wants on stdout — a consumer
    // piping this into a release log would otherwise get help text where a
    // step's result belongs, and a zero exit would let a misspelled step pass
    // for a step that ran.
    stderr.writeln(e);
    exitCode = usageExit;
  } on DestinationTableException catch (e) {
    stderr.writeln('cux_train: $e');
    exitCode = 1;
  } on PromotionRecordException catch (e) {
    stderr.writeln('cux_train: $e');
    exitCode = 1;
  } on StatusGridException catch (e) {
    stderr.writeln('cux_train: $e');
    exitCode = 1;
  } on StoreSelectionException catch (e) {
    // A table that declares nothing at the stage a verb is about. It reaches
    // here from `ready` without `--store` existing yet: `resolveStores` is
    // what every verb asks, narrowed or not, and it has a sentence of its own
    // for the unnarrowed run.
    stderr.writeln('cux_train: $e');
    exitCode = 1;
  } on ReadinessException catch (e) {
    stderr.writeln('cux_train: $e');
    exitCode = 1;
  } on StepCommandException catch (e) {
    // A `command` in the table this package will not spawn. A table problem
    // rather than a usage one — the operator typed nothing wrong.
    stderr.writeln('cux_train: $e');
    exitCode = 1;
  } on PromotionWriteException catch (e) {
    stderr.writeln('cux_train: $e');
    exitCode = 1;
  } on PromotionRunException catch (e) {
    stderr.writeln('cux_train: $e');
    exitCode = 1;
  } on EvidenceWaitException catch (e) {
    // A `read` command that exited 0 and printed something this package
    // cannot read as a build number. A table problem, like a `command` it
    // will not spawn, and the operator typed nothing wrong.
    stderr.writeln('cux_train: $e');
    exitCode = 1;
  } on EvidenceIncomplete {
    // **Nothing printed, for the reason the next clause gives.** The wait has
    // already rendered its rows and its "still pending after 1h"; this is the
    // number for it. The same number as an unfinished walk, because it is the
    // same state — the build is not at the stage — and whatever branches on
    // it is asking about the build rather than about which lane fell short.
    exitCode = incompleteExit;
  } on PromotionIncomplete {
    // **Nothing is printed here, and that is the point of the clause.** The
    // run already rendered what is outstanding and why; this exists only to
    // turn that into a number a caller can branch on, and a second sentence
    // saying it again would be the one that goes stale. It covers a dry run
    // that found work to do — what it printed it did not perform, so it must
    // not be the cheap way to a zero exit — and not one that found the stage
    // already recorded, which is complete and never throws this.
    exitCode = incompleteExit;
  } on ReleaseException catch (e) {
    // Git ran and said no — not a repository, most often. It arrives from
    // `cux_ship`, because that is whose `Git` reads the refs. A `git` that is
    // not on the path at all is *not* this: `Process.runSync` throws a
    // `ProcessException` before `Git` has an exit code to wrap, and that one
    // still reaches the operator as a stack trace, here as in `cux_ship`.
    stderr.writeln('cux_train: ${e.message}');
    exitCode = 1;
  }
}
