/// What every verb that *acts* on a candidate has to do before it can start.
///
/// **Extracted on the second such verb, which is the rule this package has
/// been following.** `candidate_command.dart` says the same thing about the
/// second verb that *read*, and `beta_command.dart` said in as many words that
/// a base class written for one subclass is a base class whose members are
/// whatever that subclass happened to need. There are now two, and the four
/// flags, the `uploaded/` tag pattern and the construction of a
/// [PromotionRun] are the same in both.
///
/// **What is deliberately not here is the walk.** `beta` walks a stage once;
/// `production` walks it, then checks the finish rule, then spends the version
/// tag, then walks what is ordered after it. Hoisting that into a template
/// method with hooks would make the one interesting difference between the two
/// verbs the hardest thing in the package to read. Each verb writes its own
/// `run`, and this supplies the parts.
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

/// A verb that performs and records steps for one build.
abstract class PromotingCommand extends CandidateCommand {
  PromotingCommand({
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

  /// The destinations named by `--store`, resolved for [stage].
  StoreSelection selectionFor(DestinationTable table, Stage stage) =>
      resolveStores(
        table: table,
        names: argResults!['store'] as List<String>,
        stage: stage,
      );

  bool get dryRun => argResults!['dry-run'] as bool;

  bool get yes => argResults!['yes'] as bool;

  /// The `uploaded/` tag for this candidate, from the declared pattern.
  String uploadedTagFor({required String version, required int build}) =>
      interpolate(argResults!['uploaded-tag'] as String, {
        'version': version,
        'build': '$build',
      }, '--uploaded-tag');

  /// A run over [selection] at [stage], wired to this invocation's flags.
  ///
  /// **The ledger is read here, on every call, and that is load-bearing for
  /// `production`.** Its second walk happens after the first has written
  /// records and after the version tag has been spent, so a ledger captured
  /// once at the top would have it deciding what is outstanding from refs
  /// that were already stale when the finish ran.
  PromotionRun runFor({
    required StoreSelection selection,
    required Stage stage,
    required int build,
    required String version,
    required String uploadedTag,
    String? pass,
  }) => PromotionRun(
    pass: pass,
    selection: selection,
    ledger: ledgerFor(build: build, version: version),
    stage: stage,
    build: build,
    version: version,
    root: root,
    uploadedTag: uploadedTag,
    git: Git(root),
    output: output,
    console: console ?? StdioConsole(output: output),
    dryRun: dryRun,
    yes: yes,
    spawn: spawn,
    push: push,
  );
}
