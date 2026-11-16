/// `status`: read the records, render the grid, write nothing.
///
/// **The first verb wired to the library, and the only one that spends
/// nothing.** It can still be wrong — a grid can misreport — but it cannot cost
/// anything. §3 of `docs/design/authpass-on-the-train.md` defines it as "reads,
/// writes nothing", which is what makes it the right one to land first: every
/// other verb in the plan spends something — a push, a console submission, the
/// version tag — and none of them can be exercised against a real repository
/// until the thing that *reports* state is trustworthy.
///
/// **What this file decides is now nearly nothing**, and that is the shape the
/// second verb forced. Where the table is, which build, which release and how
/// the ledger is keyed were all settled here while `status` was the only verb.
/// They belong to every verb that is about a candidate rather than to this one,
/// so they are in [CandidateCommand] and what is left here is the grid.
library;

import 'candidate_command.dart';
import 'status_grid.dart';

/// Prints the evidence grid for one release candidate.
class StatusCommand extends CandidateCommand {
  StatusCommand({super.output, super.root, super.openGit});

  @override
  String get name => 'status';

  @override
  String get description =>
      'Print the evidence grid for one release candidate. Reads only.';

  @override
  void run() {
    refuseStrayArguments();

    final table = readTable();
    final build = candidateBuild();
    final release = candidateRelease();

    final grid = StatusGrid.of(
      table: table,
      ledger: ledgerFor(build: build, version: release),
      version: release,
      candidate: build,
    );

    output.write(grid.render());
  }
}
