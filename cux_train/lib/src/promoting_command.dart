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

import 'dart:io';

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

  /// Runs the gates [stage] declares, in order, refusing on the first failure.
  ///
  /// **Hoisted on the second verb to run gates, and the schema moved with
  /// it.** This was `production`'s private method over a flat `gates:` list;
  /// `internal` has gates of its own — §3 gives it the `pre-build` hook — and
  /// one list shared between the two verbs would hand each the other's. The
  /// alternative was to leave this where it was and let a table's
  /// `gates.internal` parse and never run, which is the worst state a gate
  /// has: declared, believed, and not there.
  ///
  /// **A dry run runs them.** They spend nothing by contract, and a dry run
  /// that skipped them could not answer the question §8 step 1 wants a dry run
  /// for — whether this release is ready. `release finish --dry-run`, one of
  /// the two gates §3 names, is itself exactly this shape.
  ///
  /// **`HOOK_STORES` carries the destinations this run will act on**, which §7
  /// records as the donor's existing hook contract and the part that is
  /// already generic. A gate that cares whether the run was narrowed reads it;
  /// one that does not, ignores it. There is no `{destination}`: a gate is
  /// about the release rather than about one row, so that name is refused by
  /// the resolver instead of resolving to something invented.
  Future<void> runGates(
    DestinationTable table,
    StoreSelection selection, {
    required Stage stage,
    required String version,
    required int build,
  }) async {
    final gates = table.gatesAt(stage);
    if (gates.isEmpty) {
      return;
    }
    final stores = selection.acting.map((it) => it.name).join(' ');
    for (var i = 0; i < gates.length; i++) {
      final argv = resolveStepCommand(
        gates[i].command!,
        values: {'version': version, 'build': '$build', 'stage': stage.name},
        where: '`gates.${stage.name}[$i]`.command',
      );
      output.write('\ngate  ${argv.join(' ')}\n');
      final int code;
      try {
        code = await (spawn ?? spawnInheritingStdio)(
          argv,
          workingDirectory: root,
          environment: {'HOOK_STORES': stores},
        );
      } on ProcessException catch (error) {
        throw PromotionRunException(
          'The gate `${argv.first}` could not be started: ${error.message}. '
          'Nothing was spent.',
        );
      }
      if (code != 0) {
        throw PromotionRunException(
          'The gate `${argv.join(' ')}` exited $code, so nothing was spent. '
          'This is the refusal arriving while it is still free — fix what it '
          'reported and run ${stage.name} again.',
        );
      }
    }
  }

  /// A run over [selection] at [stage], wired to this invocation's flags.
  ///
  /// **The ledger is read here, on every call, and that is load-bearing for
  /// `production`.** Its second walk happens after the first has written
  /// records and after the version tag has been spent, so a ledger captured
  /// once at the top would have it deciding what is outstanding from refs
  /// that were already stale when the finish ran.
  ///
  /// **[alreadyConfirmed] is consent this verb has taken for itself, and it is
  /// not `--yes`.** `internal` asks once, before the dispatch, about
  /// everything the invocation will spend — the push, the destinations that
  /// are public the moment it lands, and the local lane this run walks. The
  /// walk asking again afterwards would be a second question about a decision
  /// the operator has already made, and the only way to answer it would be to
  /// say yes a second time.
  PromotionRun runFor({
    required StoreSelection selection,
    required Stage stage,
    required int build,
    required String version,
    required String uploadedTag,
    String? pass,
    bool alreadyConfirmed = false,
  }) => PromotionRun(
    pass: pass,
    selection: selection,
    ledger: ledgerFor(build: build, version: version),
    stage: stage,
    build: build,
    version: version,
    root: root,
    uploadedTag: uploadedTag,
    git: gitAt(root),
    output: output,
    console: console ?? StdioConsole(output: output),
    dryRun: dryRun,
    yes: yes || alreadyConfirmed,
    spawn: spawn,
    push: push,
  );
}
