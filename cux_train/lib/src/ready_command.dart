/// `ready`: could `production` run for this candidate, and what is in its way.
///
/// **The second verb, and the first with an answer rather than a picture.**
/// `status` renders every cell and leaves the reading to a person; this one
/// answers a single question, and its exit code is that answer, so a launcher
/// can put it in front of `production` and a release script can branch on it.
///
/// **It still writes nothing anywhere**, which is what lets it land before the
/// verbs that spend. It reads the table and the same promotion refs `status`
/// reads, and the half of §3's `ready` that needs a store read or a hook is
/// named in the output as missing rather than quietly skipped — see
/// [Readiness] for what that covers and why the version tag is not part of it.
library;

import 'candidate_command.dart';
import 'readiness.dart';

/// Answers whether `production` could run, and exits [notReadyExit] if not.
class ReadyCommand extends CandidateCommand {
  ReadyCommand({super.output, super.root, super.openGit});

  @override
  String get name => 'ready';

  @override
  String get description =>
      'Say whether production could run for one candidate, and what is in '
      'its way. Reads only.';

  @override
  void run() {
    refuseStrayArguments();

    final table = readTable();
    final build = candidateBuild();
    final release = candidateRelease();

    final readiness = Readiness.of(
      table: table,
      ledger: ledgerFor(build: build, version: release),
      version: release,
      candidate: build,
    );

    // **The report is written either way, before the verdict is raised.** A
    // blocked run is the one an operator most needs the detail of, and a verb
    // that threw first would print the sentence and withhold the reason.
    output.write(readiness.render());

    if (!readiness.couldRun) {
      final count = readiness.blockers.length;
      throw ProductionNotReady(
        'production is not ready for $release build $build: $count '
        '${count == 1 ? 'blocker' : 'blockers'} '
        '(${readiness.blockers.map((it) => it.destination).join(', ')}).',
      );
    }
  }
}
