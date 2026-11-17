/// `cux_train beta` — the same build, to public testers.
///
/// **The first verb that spends something, and the smallest one that does.**
/// §3 gives `beta` no wait and no ordering: it is the stage walked once, each
/// destination performed and recorded. `internal` adds a dispatch and an
/// evidence wait with a timeout, and `production` adds the finish rule and the
/// version tag — both of which are about *this* loop rather than instead of
/// it, which is why the loop lives in `promotion_run.dart`, the flags in
/// `promoting_command.dart`, and this file is one short `run`.
library;

import 'destinations.dart';
import 'promoting_command.dart';
import 'promotion_run.dart';

class BetaCommand extends PromotingCommand {
  BetaCommand({
    super.output,
    super.root,
    super.openGit,
    super.console,
    super.spawn,
    super.push,
  });

  @override
  String get name => 'beta';

  @override
  String get description =>
      'Promote one build to the beta stage at every destination that has '
      'one, and record each.';

  @override
  Future<void> run() async {
    refuseStrayArguments();
    final table = readTable();
    final build = candidateBuild();
    final version = candidateRelease();

    final selection = selectionFor(table, Stage.beta);

    // **`beta` runs the gates its stage declares, though §3 gives it none.**
    // The gate schema's rule is that the key *is* the stage, so `Stage.values`
    // is what `gates:` accepts — and with this call missing, `gates: {beta:
    // […]}` parsed, was believed, and never ran, which is the one state this
    // package will not ship a gate in. A verb that spends something asks its
    // gates first; that `beta`'s list is empty in every table today is a fact
    // about the tables, not a licence for the verb to skip the question.
    await runGates(
      table,
      selection,
      stage: Stage.beta,
      version: version,
      build: build,
    );

    final report = await runFor(
      selection: selection,
      stage: Stage.beta,
      build: build,
      version: version,
      uploadedTag: uploadedTagFor(version: version, build: build),
    ).perform();
    output.write(report.render());

    // **The exit code is about the stage, not about this invocation's luck.**
    // A run that reached every destination and was refused by one has done
    // everything asked of it and still leaves the build not at beta, and the
    // thing calling this — a script, or an operator's `&&` — is asking the
    // second question.
    if (!report.complete) {
      throw PromotionIncomplete(report);
    }
  }
}
