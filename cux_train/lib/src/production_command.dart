/// `cux_train production` — the same build, to users; then finish.
///
/// **The three things that make this more than `beta` at another stage** are
/// all about the version tag, and §3 step 5 states each.
///
/// *The finish rule.* `vX.Y.Z` is spent once every declared destination with a
/// production step is **recorded** at production. That question is asked of
/// the record, never of how this invocation was narrowed — §4 is explicit,
/// and the reason is that a `production` spanning days ends with somebody
/// typing `--store ppa production`, which under the donor's `isEveryStore`
/// could never be allowed to finish.
///
/// *The order.* `fdroid` pushes `fdroid-vX.Y.Z`, a tag that annotates the
/// version tag and therefore cannot precede it. Such destinations are
/// declared `after-finish` in the table, are excluded from the rule, and are
/// walked after the tag is spent rather than with the rest. So this verb
/// makes two passes where `beta` makes one.
///
/// *The tag is the consumer's.* The step that writes it is `finish:` in the
/// destination table, spawned like any other command. Composing `v$version`
/// here would be inventing somebody else's convention — the same mistake as
/// reading a release out of an `uploaded/` tag — and being silently wrong
/// wherever they spell it differently.
library;

import 'dart:io';

import 'destinations.dart';
import 'promoting_command.dart';
import 'promotion_ledger.dart';
import 'promotion_run.dart';
import 'record_writer.dart';
import 'step_command.dart';
import 'store_selection.dart';

class ProductionCommand extends PromotingCommand {
  ProductionCommand({
    super.output,
    super.root,
    super.openGit,
    super.console,
    super.spawn,
    super.push,
  });

  @override
  String get name => 'production';

  @override
  String get description =>
      'Promote one build to production at every destination, then spend the '
      'version tag once every one of them is recorded.';

  @override
  Future<void> run() async {
    refuseStrayArguments();
    final table = readTable();
    final build = candidateBuild();
    final version = candidateRelease();
    final uploadedTag = uploadedTagFor(version: version, build: build);

    final selection = selectionFor(table, Stage.production);
    final before = _split(selection, afterFinish: false);
    final after = _split(selection, afterFinish: true);
    final finish = table.finish;

    // **Everything the second half needs is resolved before the first half
    // spends anything.** The run already preflights the commands it is about
    // to spawn; what it did not cover is the commands it will spawn *later*.
    // A `{artifact}` in the `fdroid` row, or in the `finish` template, was
    // found after every store had been handed over — the refusal arriving
    // once it could no longer save anything.
    final finishArgv = finish == null
        ? null
        : _finishArgv(finish, version, build);
    _resolveAfter(after, version: version, build: build);

    final report = await runFor(
      selection: before,
      stage: Stage.production,
      build: build,
      version: version,
      uploadedTag: uploadedTag,
    ).perform();
    // A narrowed run that covers nothing before the tag — `--store fdroid` —
    // would otherwise print an empty block saying every destination it covers
    // is recorded, about a destination it has not reached.
    if (report.steps.isNotEmpty || before.skipped.isNotEmpty) {
      output.write(report.render());
    }

    // **The rule is asked of a freshly read ledger**, because the walk above
    // has just written records and the question is what the repository holds
    // now — not what it held when this process started.
    final ledger = ledgerFor(build: build, version: version);
    final rule = finishRule(table: table, ledger: ledger);
    final held = _stillHeld(rule, report);
    if (held.isNotEmpty) {
      output.write(_held(held, narrowed: !selection.coversEveryDestination));
      throw PromotionIncomplete(report);
    }

    if (finish == null) {
      // Not a failure of the release: every destination is recorded, and the
      // table simply never said how this project writes its version tag.
      output.write(
        '\nEvery destination the version tag waits on is recorded at '
        'production, and the table declares no `finish` step, so there is no '
        'version tag to spend. Add one to finish a release from here.\n',
      );
      throw PromotionIncomplete(report);
    }

    await _finish(
      finishArgv!,
      version: version,
      build: build,
      uploadedTag: uploadedTag,
    );

    if (after.acting.isNotEmpty) {
      final afterReport = await runFor(
        selection: after,
        stage: Stage.production,
        build: build,
        version: version,
        uploadedTag: uploadedTag,
        pass: 'after the version tag',
      ).perform();
      output.write(afterReport.render());
      if (!afterReport.complete) {
        throw PromotionIncomplete(afterReport);
      }
    }
  }

  /// The half of [selection] whose `after-finish` flag is [afterFinish].
  ///
  /// `skipped` travels with the first pass only: a destination with no
  /// production step is reported once, and reporting it again under the
  /// after-finish heading would read as a second set of destinations.
  StoreSelection _split(
    StoreSelection selection, {
    required bool afterFinish,
  }) => StoreSelection(
    acting: [
      for (final destination in selection.acting)
        if (destination.afterFinish == afterFinish) destination,
    ],
    skipped: afterFinish ? const [] : selection.skipped,
    coversEveryDestination: selection.coversEveryDestination,
  );

  /// The finish command, resolved.
  List<String> _finishArgv(DestinationStep finish, String version, int build) =>
      resolveStepCommand(
        finish.command!,
        values: {
          'version': version,
          'build': '$build',
          // **The two a destination has and a finish does not.** A finish is
          // not about one destination, so there is no honest value for
          // either — and a template using one is a table saying something it
          // cannot mean. Leaving them out makes that a refusal naming the two
          // names it does have, rather than a tag with the word `finish` in
          // it.
        },
        where: '`finish`.command',
      );

  /// Resolves the commands the after-finish pass will need, and discards them.
  ///
  /// Called for its refusals. The pass resolves them again when it runs, which
  /// is cheap and keeps the run the single place that decides what to spawn.
  void _resolveAfter(
    StoreSelection after, {
    required String version,
    required int build,
  }) {
    for (final destination in after.acting) {
      final step = destination.stepAt(Stage.production);
      if (step.kind.spawns) {
        resolveStepCommand(
          step.command!,
          values: {
            'version': version,
            'build': '$build',
            'destination': destination.name,
            'stage': Stage.production.name,
          },
          where: '${destination.name}.production.command',
        );
      }
    }
  }

  /// What is still holding the tag, given what this run did or would do.
  ///
  /// **A dry run records nothing, so the rule would always say the tag is
  /// held** — and `production --dry-run` on a fresh candidate then stopped
  /// before the finish step and before every after-finish destination. §8
  /// step 1 is explicit that the dry run *is* the README checklist for this
  /// build, and a checklist missing "create tag" and F-Droid is missing the
  /// end of the release. So a dry run subtracts what it has just said it
  /// would do, and goes on to print the rest.
  List<Destination> _stillHeld(FinishRule rule, RunReport report) {
    if (!dryRun) {
      return rule.waitingOn;
    }
    final wouldRecord = {
      for (final step in report.steps)
        if (step.outcome == StepOutcome.wouldAct) step.destination,
    };
    return [
      for (final destination in rule.waitingOn)
        if (!wouldRecord.contains(destination.name)) destination,
    ];
  }

  /// Spends the version tag, and records that it did.
  Future<void> _finish(
    List<String> argv, {
    required String version,
    required int build,
    required String uploadedTag,
  }) async {
    if (dryRun) {
      output.write('\nwould finish  ${argv.join(' ')}\n');
      return;
    }

    // **Skipped because a ref says it happened, exactly like every other
    // step.** Without this the one irreversible thing in the package was the
    // only thing with no record: a re-run of a finished release spent the tag
    // again, which with a real `release finish` either tags a second commit
    // or fails on the taken name and then reports that the tag was not spent
    // when it had been.
    final git = gitAt(root);
    final ref = finishedRef(version: version, build: build);
    if (alreadyTagged(git, ref)) {
      output.write('\nalready finished: `$ref` records the version tag.\n');
      return;
    }

    output.write('\nfinish  ${argv.join(' ')}\n');
    final int code;
    try {
      code = await (spawn ?? spawnInheritingStdio)(
        argv,
        workingDirectory: root,
      );
    } on ProcessException catch (error) {
      // The program is not on the path, or the script is not executable. A
      // destination's step reports the same thing as a failed step; here
      // there is no step to report it on, and left to propagate it ended a
      // run that had just recorded every destination as a stack trace.
      throw PromotionRunException(
        'The finish step could not be started — `${argv.first}`: '
        '${error.message} — so the version tag was not spent. Every '
        'destination is still recorded, so fixing the `finish` command and '
        'running production again resumes here.',
      );
    }
    if (code != 0) {
      throw PromotionRunException(
        'The finish step exited $code, so the version tag was not spent. '
        'Every destination is still recorded, so fixing whatever that was '
        'and running production again resumes here.',
      );
    }

    final result = writeFinish(
      git: git,
      version: version,
      build: build,
      uploadedTag: uploadedTag,
      push: push,
    );
    output.write('  recorded $ref');
    if (result == UploadRecordResult.writtenNotPushed) {
      output.write(' (written here, not pushed — push it when you can)');
    }
    output.write('\n');
  }

  /// What is holding the version tag.
  String _held(List<Destination> waitingOn, {required bool narrowed}) {
    final names = waitingOn.map((it) => it.name).join(', ');
    final count = waitingOn.length;
    return '\nThe version tag is not spent: '
        '${count == 1 ? '1 destination is' : '$count destinations are'} not '
        'recorded at production — $names.'
        '${narrowed ? ' This run was narrowed with --store, and the rule is '
                  'about the record rather than about one invocation, so the '
                  'tag is spent by whichever run finishes the last of them.' : ''}'
        '\n';
  }
}
