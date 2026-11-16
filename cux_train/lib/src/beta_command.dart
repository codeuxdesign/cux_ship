/// `cux_train beta` — the same build, to public testers.
///
/// **The first verb that spends something, and the smallest one that does.**
/// §3 gives `beta` no wait and no ordering: it is the stage walked once, each
/// destination performed and recorded. `internal` adds a dispatch and an
/// evidence wait with a timeout, and `production` adds an ordered group, the
/// finish rule and the version tag — both of which are about *this* loop
/// rather than instead of it, which is why the loop lives in
/// `promotion_run.dart` and this file is sixty lines of flags.
///
/// **It is not a base class yet, deliberately.** `candidate_command.dart` was
/// extracted on the second verb that read, and the same rule applies here: the
/// shape `internal` and `production` share is a guess until there are two of
/// them, and a base class written for one subclass is a base class whose
/// members are whatever that subclass happened to need.
library;

import 'package:cux_ship/provenance.dart' show Git;

import 'candidate_command.dart';
import 'destinations.dart';
import 'operator_console.dart';
import 'promotion_run.dart';
import 'step_command.dart';
import 'store_selection.dart';

/// The default `uploaded/` tag pattern, matching `cux_ship`'s own default.
const String defaultUploadedTag = 'uploaded/v{version}+{build}';

class BetaCommand extends CandidateCommand {
  BetaCommand({
    super.output,
    super.root,
    super.openGit,
    this.console,
    this.spawn,
    this.push = true,
  }) {
    argParser
      ..addMultiOption(
        'store',
        valueHelp: 'NAME',
        help:
            'Act on these destinations only. A family name covers its '
            'members. Repeatable; the default is every destination.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help:
            'Print every instruction and command and record nothing. This is '
            'the checklist for this build.',
      )
      ..addFlag(
        'yes',
        negatable: false,
        help:
            'Do not ask before acting. It does not answer a manual step, '
            'which is not something this command does.',
      )
      ..addOption(
        'uploaded-tag',
        valueHelp: 'PATTERN',
        defaultsTo: defaultUploadedTag,
        help:
            'The tag naming the commit a record is written at. The consumer '
            'owns this convention; {version} and {build} are substituted.',
      );
  }

  /// Where a manual step asks its question. A test passes a scripted one;
  /// null means the real `stdin`.
  final OperatorConsole? console;

  /// How a `ship` or `run` step is spawned. A test passes a recorder; null
  /// means a real child process.
  final StepSpawn? spawn;

  /// Whether records are pushed. For tests, as on `writePromotion`.
  final bool push;

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

    final selection = resolveStores(
      table: table,
      names: argResults!['store'] as List<String>,
      stage: Stage.beta,
    );
    final ledger = ledgerFor(build: build, version: version);

    final uploadedTag = interpolate(argResults!['uploaded-tag'] as String, {
      'version': version,
      'build': '$build',
    }, '--uploaded-tag');

    final run = PromotionRun(
      selection: selection,
      ledger: ledger,
      stage: Stage.beta,
      build: build,
      version: version,
      root: root,
      uploadedTag: uploadedTag,
      git: Git(root),
      output: output,
      console: console ?? StdioConsole(output: output),
      dryRun: argResults!['dry-run'] as bool,
      yes: argResults!['yes'] as bool,
      spawn: spawn,
      push: push,
    );

    final report = await run.perform();
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

/// Thrown when a run leaves something outstanding, so `cli.dart` can map it.
///
/// It carries the report rather than a sentence because the report has already
/// been printed: this exists to pick an exit code, and inventing a second
/// description of the same run is how the two drift apart.
class PromotionIncomplete implements Exception {
  PromotionIncomplete(this.report);

  final RunReport report;

  @override
  String toString() =>
      '${report.outstanding.length} destination(s) outstanding at '
      '${report.stage.name}';
}
