/// `ready`: what `production` would meet for this candidate.
///
/// **The second verb, and the first that reads the record for a purpose.**
/// `status` renders every cell and leaves the sense of it to a person; this
/// one says what `production` would do next, what the version tag waits for,
/// and what to take to the consoles.
///
/// **It exits 0 on every answer it can give, which is not what the first
/// draft did.** That draft treated a refused destination as a veto and exited
/// 2. §6.1 records a refusal so that the next `production` run goes back to
/// that destination, so the veto was backwards — and because nothing clears a
/// refusal, it was permanent. [ReadinessWarning] carries what that cost. What
/// is left here cannot say no, and the exit code that could say it was removed
/// rather than kept for a case nothing reaches: a code nobody can produce is
/// the donor's dropped flag in another spelling.
///
/// **It writes nothing anywhere**, which is what lets it land before the verbs
/// that spend. It reads the table and the same promotion refs `status` reads,
/// and the half of §3's `ready` that needs a store read or a hook is named in
/// the output as missing rather than quietly skipped — see [Readiness] for
/// what that covers and why the version tag is not part of it.
library;

import 'candidate_command.dart';
import 'readiness.dart';

/// Says what `production` would meet for one release candidate.
class ReadyCommand extends CandidateCommand {
  ReadyCommand({super.output, super.root, super.openGit});

  @override
  String get name => 'ready';

  @override
  String get description =>
      'Say what production has left to do for one candidate, and what to '
      'take with you. Reads only.';

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

    output.write(readiness.render());
  }
}
