/// Walking the destinations of one stage and recording what happened at each.
///
/// **This is the first thing in the package that spends something**, and the
/// shape it takes is set by three rules the design states and one it does not.
///
/// From §3: *a store refusing does not stop the others*. Every outcome below
/// is per-destination, the loop never breaks on a bad one, and `q` is the only
/// answer that ends a run early — because it is the only one the operator
/// chose for the run rather than for the destination.
///
/// From §6.1: `--yes` does not auto-confirm a manual step, because `--yes`
/// means "do not ask before doing what you were going to do" and a manual step
/// is not something the train does. Off a terminal a manual destination is
/// reported pending and the run exits non-zero *having done everything else*.
///
/// From §4: resumability is the record, not a flag. [PromotionLedger.outstanding]
/// already drops what is handed over, so a re-run picks up at the first
/// destination that is not — and a refusal is outstanding, which is what makes
/// `f` a retry rather than a tombstone.
///
/// **And the one the design does not settle: a step whose command fails is not
/// recorded.** It would be easy to file a `refused/` tag for a `ship` that
/// exited non-zero, since §6.2 renders both as `failed`. That would be wrong,
/// and permanently so. A refusal is a judgement *about the artifact* — a human
/// at a console saying this binary does not pass — and nothing in this package
/// clears one: `recordFor` lets a refusal win over a later hand-over on
/// purpose, so a tag written for a five-second network timeout would mark that
/// destination refused for the life of the build. A failed command is an
/// incident, not a verdict. It is reported, the destination stays outstanding,
/// and the next run tries it again, which is exactly what `s` does and for the
/// same reason.
library;

import 'dart:async';
import 'dart:io';

import 'destinations.dart';
import 'operator_console.dart';
import 'promotion_ledger.dart';
import 'promotion_record.dart';
import 'record_writer.dart';
import 'step_command.dart';
import 'store_selection.dart';

/// Spawns [argv] and answers its exit code.
typedef StepSpawn =
    Future<int> Function(List<String> argv, {required String workingDirectory});

/// The real spawn: the child inherits this process's streams.
///
/// **Inherited rather than captured**, because an upload is minutes long and a
/// captured one shows the operator nothing until it is over. The train has
/// nothing to add to a store tool's own output, so it gets out of the way.
Future<int> spawnInheritingStdio(
  List<String> argv, {
  required String workingDirectory,
}) async {
  final process = await Process.start(
    argv.first,
    argv.skip(1).toList(),
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}

/// What one destination's step produced.
enum StepOutcome {
  /// Performed, and recorded under `promoted/`.
  handedOver('handed over'),

  /// Attempted and refused, recorded under `refused/`.
  refused('refused'),

  /// Its command ran and did not succeed. Deliberately unrecorded — see the
  /// library comment.
  failed('failed'),

  /// `s`: the operator left it for next time. Unrecorded by definition.
  leftUnrecorded('left for next time'),

  /// A manual step with nobody to perform it, because this is not a terminal.
  ///
  /// The summary is the bare word because the detail beside it says why; the
  /// two together read as one sentence rather than as the same fact twice.
  pending('pending'),

  /// Reached after `q`, or not reached at all.
  notReached('not reached'),

  /// `--dry-run`: what the step would have done was printed, nothing happened.
  wouldAct('would act');

  const StepOutcome(this.summary);

  /// How this reads in the run's closing report.
  final String summary;

  /// Whether the destination is finished for this build.
  bool get finished => this == handedOver;
}

/// What happened at one destination.
class StepReport {
  const StepReport({
    required this.destination,
    required this.outcome,
    this.detail,
  });

  final String destination;
  final StepOutcome outcome;

  /// A line of why, where there is one — the note on a refusal, the exit code
  /// on a failure.
  final String? detail;
}

/// What a whole run did.
class RunReport {
  RunReport({
    required this.stage,
    required this.build,
    required this.version,
    required List<StepReport> steps,
    required List<String> noStageHere,
    required this.dryRun,
  }) : steps = List.unmodifiable(steps),
       noStageHere = List.unmodifiable(noStageHere);

  final Stage stage;
  final int build;
  final String version;
  final List<StepReport> steps;

  /// Destinations the selection named that have no step at this stage.
  final List<String> noStageHere;

  final bool dryRun;

  /// Whether every destination this run covers is recorded at this stage.
  ///
  /// **The question is about the build, not about this invocation**, because
  /// that is what the exit code is read for: `train beta && …` asks whether
  /// the build is at beta, not whether this process did the work.
  ///
  /// **There was a `!dryRun &&` here, and a mutation that removed it survived,
  /// which is how the guard turned out to be wrong rather than redundant.** A
  /// dry run that has work to do is already incomplete without it — every step
  /// it produces is [StepOutcome.wouldAct], which is not finished — so the
  /// only case the term changed was the one where a dry run found *everything
  /// already recorded*, and there it answered no about a build that is fully
  /// at the stage. That is the false negative that makes an `&&` chain
  /// useless. The property it was guarding is real and lives where it belongs:
  /// in [StepOutcome.finished], which only `handedOver` satisfies.
  bool get complete => steps.every((step) => step.outcome.finished);

  /// The destinations this run leaves outstanding, in order.
  List<StepReport> get outstanding => [
    for (final step in steps)
      if (!step.outcome.finished) step,
  ];

  String render() {
    final lines = <String>[
      '',
      '$version — build $build — ${stage.name}'
          '${dryRun ? ' — dry run, nothing was recorded' : ''}',
      '',
    ];
    final widest = steps.fold<int>(
      0,
      (widest, step) =>
          step.destination.length > widest ? step.destination.length : widest,
    );
    for (final step in steps) {
      final detail = step.detail == null ? '' : '  — ${step.detail}';
      lines.add(
        '  ${step.destination.padRight(widest)}  '
        '${step.outcome.summary}$detail',
      );
    }
    if (noStageHere.isNotEmpty) {
      lines
        ..add('')
        ..add('  no ${stage.name} audience: ${noStageHere.join(', ')}');
    }
    lines
      ..add('')
      ..add(_verdict());
    return '${lines.join('\n')}\n';
  }

  String _verdict() {
    // **Complete is asked first, and a dry run reaches it.** A dry run that
    // found everything already recorded has nothing to tell the operator to
    // run again, and saying "nothing was recorded" there describes the
    // invocation while the question is about the build.
    if (complete) {
      return 'Every destination this run covers is recorded at '
          '${stage.name}.';
    }
    if (dryRun) {
      return 'Nothing was performed and nothing was recorded. Run it again '
          'without --dry-run.';
    }
    final left = outstanding.length;
    return '${left == 1 ? '1 destination is' : '$left destinations are'} '
        'still outstanding. Run ${stage.name} again — what is recorded is '
        'skipped, so it picks up where this stopped.';
  }
}

/// One invocation of a verb that acts.
class PromotionRun {
  PromotionRun({
    required this.selection,
    required this.ledger,
    required this.stage,
    required this.build,
    required this.version,
    required this.root,
    required this.uploadedTag,
    required this.git,
    required this.output,
    required this.console,
    this.dryRun = false,
    this.yes = false,
    StepSpawn? spawn,
    this.push = true,
  }) : spawn = spawn ?? spawnInheritingStdio;

  final StoreSelection selection;
  final PromotionLedger ledger;
  final Stage stage;
  final int build;
  final String version;

  /// The directory a step's command is spawned in.
  final String root;

  /// The `uploaded/` tag naming the commit a record is written at.
  final String uploadedTag;

  final Git git;
  final StringSink output;
  final OperatorConsole console;
  final bool dryRun;
  final bool yes;
  final StepSpawn spawn;

  /// Whether a written record is pushed. For tests, as on [writePromotion].
  final bool push;

  /// Performs the stage, returning what happened.
  Future<RunReport> perform() async {
    final todo = ledger.outstanding(selection.acting, stage);
    final steps = <StepReport>[];

    // **Already recorded is reported, not hidden.** A re-run that silently
    // acted on three of six destinations and said so only in a total would
    // leave the operator to work out which three; §3's resumable production is
    // read across days, by somebody who did not type the previous run.
    final done = [
      for (final destination in selection.acting)
        if (!todo.contains(destination)) destination,
    ];
    if (done.isNotEmpty) {
      output.write(
        'Already recorded at ${stage.name} for build $build: '
        '${done.map((it) => it.name).join(', ')}\n',
      );
    }

    if (todo.isEmpty) {
      return RunReport(
        stage: stage,
        build: build,
        version: version,
        steps: const [],
        noStageHere: [for (final it in selection.skipped) it.name],
        dryRun: dryRun,
      );
    }

    if (!_confirmed(todo)) {
      throw PromotionRunException(
        'Stopped before anything was spent. Re-run with --yes to skip this '
        'question, or from a terminal where it can be answered.',
      );
    }

    var quit = false;
    for (final destination in todo) {
      if (quit) {
        steps.add(
          StepReport(
            destination: destination.name,
            outcome: StepOutcome.notReached,
          ),
        );
        continue;
      }
      steps.add(await _perform(destination));
      // `q` is the one answer about the run rather than about the destination,
      // and it is reported as `leftUnrecorded` for the destination it was
      // pressed at — the operator did not say that one failed.
      quit = _quitPressed;
    }

    return RunReport(
      stage: stage,
      build: build,
      version: version,
      steps: steps,
      noStageHere: [for (final it in selection.skipped) it.name],
      dryRun: dryRun,
    );
  }

  /// Whether the operator agreed to spend what [todo] will spend.
  ///
  /// **A dry run never asks**, because the answer cannot matter. Everything
  /// else does, unless `--yes` — and off a terminal with neither, the run
  /// stops rather than assuming consent.
  bool _confirmed(List<Destination> todo) {
    if (dryRun || yes) {
      return true;
    }
    output.write(
      '\nAbout to act on ${todo.length} destination'
      '${todo.length == 1 ? '' : 's'} at ${stage.name} for build $build of '
      '$version:\n',
    );
    for (final destination in todo) {
      output.write(
        '  ${destination.name}  '
        '(${destination.stepAt(stage).kind.name})\n',
      );
    }
    if (!console.attached) {
      return false;
    }
    return console.confirm('Go ahead?') ?? false;
  }

  /// Whether a manual step answered `q`, which ends the run after it.
  bool _quitPressed = false;

  Future<StepReport> _perform(Destination destination) async {
    final step = destination.stepAt(stage);
    return switch (step.kind) {
      // **Unreachable through `resolveStores`, and it says so rather than
      // reporting something.** A `none` step is what `skipped` is, so a
      // destination arriving here with one means the selection and this loop
      // disagree about what acting means — and the cheap readings, treating it
      // as done or as not reached, both end with a report that is quietly
      // wrong about a destination nobody will act on.
      StepKind.none => throw StateError(
        '${destination.name} has no ${stage.name} step and should have been '
        'skipped by resolveStores',
      ),
      StepKind.manual => _manual(destination, step),
      StepKind.ship || StepKind.run => await _spawn(destination, step),
    };
  }

  /// A `ship` or `run` step: resolve the command, spawn it, record on success.
  Future<StepReport> _spawn(
    Destination destination,
    DestinationStep step,
  ) async {
    final argv = resolveStepCommand(
      step.command!,
      values: {
        'version': version,
        'build': '$build',
        'destination': destination.name,
        'stage': stage.name,
      },
      where: '${destination.name}.${stage.name}.command',
    );

    if (dryRun) {
      output.write('\n${_rule(destination)}\n  would run  ${argv.join(' ')}\n');
      return StepReport(
        destination: destination.name,
        outcome: StepOutcome.wouldAct,
      );
    }

    output.write('\n${_rule(destination)}\n  run  ${argv.join(' ')}\n');
    final code = await spawn(argv, workingDirectory: root);
    if (code != 0) {
      return StepReport(
        destination: destination.name,
        outcome: StepOutcome.failed,
        detail: 'exit $code, nothing recorded — run it again',
      );
    }
    _record(destination, PromotionOutcome.handedOver, null);
    return StepReport(
      destination: destination.name,
      outcome: StepOutcome.handedOver,
    );
  }

  /// A `manual` step: §6.1's instruction, wait and record.
  StepReport _manual(Destination destination, DestinationStep step) {
    output.write('\n${_rule(destination)}\n');
    if (step.console != null) {
      output.write('  where    ${step.console}\n');
    }
    if (step.note != null) {
      output.write('  notes    ${step.note}\n');
    }
    output.write('\n');

    if (dryRun) {
      output.write('  (dry run — nothing recorded)\n');
      return StepReport(
        destination: destination.name,
        outcome: StepOutcome.wouldAct,
      );
    }

    // **`--yes` is not consulted here, and that is §6.1 in one line.** It
    // means "do not ask me before doing what you were going to do"; the train
    // was never going to do this one.
    if (!console.attached) {
      output.write(
        '  Nobody to ask — this is not a terminal, so it stays pending.\n',
      );
      return StepReport(
        destination: destination.name,
        outcome: StepOutcome.pending,
        detail: 'nobody to ask: not a terminal',
      );
    }

    final answer = console.ask();
    switch (answer) {
      case null || ManualAnswer.quit:
        _quitPressed = true;
        return StepReport(
          destination: destination.name,
          outcome: StepOutcome.leftUnrecorded,
          detail: answer == null ? 'input ended' : 'quit here',
        );
      case ManualAnswer.skip:
        return StepReport(
          destination: destination.name,
          outcome: StepOutcome.leftUnrecorded,
          detail: 'skipped, so the next run stops here again',
        );
      case ManualAnswer.done:
        _record(destination, PromotionOutcome.handedOver, null);
        return StepReport(
          destination: destination.name,
          outcome: StepOutcome.handedOver,
        );
      case ManualAnswer.failed:
        final note = console.askNote();
        if (note == null) {
          // **No reason given is not a refusal.** `writePromotion` refuses an
          // unexplained one, and turning that into a crash here would lose the
          // run; leaving it unrecorded is what `s` means, which is the honest
          // reading of an operator who pressed `f` and then said nothing.
          output.write(
            '  No reason given, so nothing is recorded — which is what `s` '
            'does. The next run stops here again.\n',
          );
          return StepReport(
            destination: destination.name,
            outcome: StepOutcome.leftUnrecorded,
            detail: 'refusal withdrawn: no reason given',
          );
        }
        _record(destination, PromotionOutcome.attemptedAndRefused, note);
        return StepReport(
          destination: destination.name,
          outcome: StepOutcome.refused,
          detail: note,
        );
    }
  }

  void _record(
    Destination destination,
    PromotionOutcome outcome,
    String? note,
  ) {
    final record = PromotionRecord(
      destination: destination.name,
      stage: stage,
      version: version,
      build: build,
      outcome: outcome,
    );
    final result = writePromotion(
      git: git,
      record: record,
      uploadedTag: uploadedTag,
      note: note,
      push: push,
    );
    output.write('  recorded ${record.ref}');
    if (result == UploadRecordResult.writtenNotPushed) {
      output.write(' (written here, not pushed — push it when you can)');
    }
    output.write('\n');
  }

  String _rule(Destination destination) {
    final head = '── ${destination.name} · ${stage.name} · build $build ';
    return head.padRight(72, '─');
  }
}

/// A run that stopped before it spent anything.
class PromotionRunException implements Exception {
  PromotionRunException(this.message);

  final String message;

  @override
  String toString() => message;
}
