/// `cux_train beta` — the same build, to public testers.
///
/// **The first verb that spends something, and the smallest one that does.**
/// §3 gives `beta` no wait and no ordering: it is the stage walked once, each
/// destination performed and recorded. `internal` adds a dispatch and an
/// evidence wait with a timeout, and `production` adds the finish rule and the
/// version tag — both of which are about *this* loop rather than instead of
/// it, which is why the loop lives in `promotion_run.dart`, the flags in
/// `promoting_command.dart`, and this file is a `run` of ten lines.
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

    final report = await runFor(
      selection: selectionFor(table, Stage.beta),
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
