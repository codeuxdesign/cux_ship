/// Whether `production` could run for one candidate, and what is in its way.
///
/// **§3's `ready` is "could `production` run, and what is missing", and this is
/// the half of it that needs nothing but the table and the record.** The other
/// half is reads — an artifact for the candidate at every CI-built destination,
/// the local `direct:macos` build, the `pre-release` hook's CHANGELOG and
/// F-Droid checks — and §8 stages those as step 2 together with the pin move
/// they force at the consumer. Landing this half first is the same bet `status`
/// was: the part that spends nothing goes in while it can still be rewritten
/// cheaply, and [Readiness.render] says out loud that a clean answer here is
/// narrower than a clean `ready`, so that nobody reads it as the whole check.
///
/// **What it adds over `status` is a verdict rather than a picture.** The grid
/// shows every cell and leaves the reading to a person; this answers one
/// question with a yes or a no, which is what a launcher can put in front of
/// `production` and what a person can act on without knowing the evidence
/// model.
///
/// **The version tag is deliberately not checked here**, and it is the obvious
/// next idea: `production`'s last step spends `vX.Y.Z`, so a tag that already
/// exists is a collision `ready` could see coming. The name is the problem.
/// That tag is written by `cux_ship release finish` under the consumer's
/// configured tag namespace — not by this package — so `cux_train` guessing
/// `v$version` would be the same mistake as reading the release out of an
/// `uploaded/` tag: inventing a convention that belongs to somebody else, and
/// being wrong silently when the consumer spells it differently.
library;

import 'destinations.dart';
import 'promotion_ledger.dart';
import 'promotion_record.dart';
import 'store_selection.dart';

/// A readiness question this file could not answer.
class ReadinessException implements Exception {
  ReadinessException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// How a blocked `ready` reaches the process exit code.
///
/// **Thrown after the report has been written, which reads oddly and is
/// right.** `cli.dart` is the only thing in this package that knows about exit
/// codes — deliberately, so that every verb can be driven in process by a test
/// — and an exception is the only channel a verb has to it. The alternative,
/// setting `exitCode` from inside the command the way `cux_ship` does, makes a
/// test mutate the VM's own exit status as a side effect of asserting on text.
///
/// It carries a sentence rather than the blockers, because the blockers are
/// already on stdout: this is what a reader of a release log sees when the
/// report went somewhere else.
class ProductionNotReady implements Exception {
  ProductionNotReady(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Something that has to change before `production` is worth running.
///
/// **A blocker is not the same as outstanding work**, and keeping the two apart
/// is the whole value of the verb. Five destinations nobody has reached yet are
/// what `production` is *for*; a destination that turned this build down is a
/// thing `production` will walk straight back into. Rendered together they
/// would read as one list of five-plus-one problems.
class ReadinessBlocker {
  const ReadinessBlocker({
    required this.destination,
    required this.summary,
    required this.detail,
  });

  /// The destination this is about, as the table spells it.
  final String destination;

  /// One line, which is what a reader scanning a list of these gets.
  final String summary;

  /// The paragraph under it: what it means, and what would clear it.
  final String detail;
}

/// `ready`'s answer for one build of one release.
class Readiness {
  Readiness({
    required this.version,
    required this.candidate,
    required List<ReadinessBlocker> blockers,
    required List<Destination> acting,
    required List<Destination> outstanding,
    required this.finish,
  }) : blockers = List.unmodifiable(blockers),
       acting = List.unmodifiable(acting),
       outstanding = List.unmodifiable(outstanding);

  /// Reads [table] and [ledger] for what `production` would meet.
  ///
  /// Throws [StoreSelectionException] when the table declares no production
  /// step at all — that refusal lives in [resolveStores] and is reused rather
  /// than restated, because "nothing to do" means the same thing to every verb.
  factory Readiness.of({
    required DestinationTable table,
    required PromotionLedger ledger,
    required String version,
    required int candidate,
  }) {
    // The same two guards the grid makes, for the same reason: every line
    // below names a build, and a build number alone does not say which release
    // it belongs to. They are restated rather than shared because the sentence
    // is what makes them useful, and a verdict and a grid need different ones.
    if (version.trim().isEmpty) {
      throw ReadinessException(
        'A readiness answer needs the release it is about: `production` is '
        'ordered per release, and its last step spends that release\'s tag.',
      );
    }
    if (candidate < 1) {
      throw ReadinessException(
        'A readiness answer needs a candidate build, and $candidate is not '
        'one. Build numbers are allocated from 1 upwards; see `--build N`.',
      );
    }

    final acting = resolveStores(
      table: table,
      names: const [],
      stage: Stage.production,
    ).acting;
    final outstanding = ledger.outstanding(acting, Stage.production);

    return Readiness(
      version: version,
      candidate: candidate,
      blockers: [
        for (final destination in acting)
          if (_refusalAt(ledger, destination) case final refusal?)
            ReadinessBlocker(
              destination: destination.name,
              summary: '${destination.name} turned this build down',
              detail:
                  '`${refusal.ref}` records that ${destination.name} was '
                  'offered build $candidate of $version at production and '
                  'refused it. `production` would walk back into it: a '
                  'refusal is outstanding, not finished, so the destination '
                  'comes up again on every re-run carrying what happened last '
                  'time. Nothing in this tool clears one — if the refusal has '
                  'since been resolved, the record still says otherwise, and '
                  'the finish rule still waits on it.',
            ),
      ],
      acting: acting,
      outstanding: outstanding,
      finish: finishRule(table: table, ledger: ledger),
    );
  }

  /// The release this is about.
  final String version;

  /// The build this is about.
  final int candidate;

  /// What has to change before `production` is worth running, in table order.
  final List<ReadinessBlocker> blockers;

  /// Every destination with a production step, in table order.
  final List<Destination> acting;

  /// Those of [acting] with no hand-over recorded for this candidate.
  final List<Destination> outstanding;

  /// Whether the version tag may be spent, and what is holding it.
  final FinishRule finish;

  /// Whether `production` could run.
  ///
  /// **An empty [outstanding] is not a no.** Everything already recorded means
  /// `production` has one step left — step 5, the version tag — and running it
  /// is exactly what an operator should then do. A verb that answered "no,
  /// there is nothing to do" would send them away from the one thing left.
  bool get couldRun => blockers.isEmpty;

  /// The answer as a block of text, ending in a newline.
  ///
  /// **A blocked answer does not list the outstanding work, and that is a
  /// choice rather than an omission.** A refused destination is outstanding
  /// too, so printing both would name it twice — once as the problem and once
  /// as a job — and a list of work under the words "cannot run" reads as an
  /// invitation to do it. `status` is where the whole picture lives.
  String render() {
    final blocks = <String>[
      '$version — build $candidate',
      _verdict(),
      if (blockers.isNotEmpty) _blockers(),
      if (blockers.isEmpty) _work(),
      _finish(),
      _notChecked(),
    ];
    return '${blocks.join('\n\n')}\n';
  }

  String _verdict() {
    if (blockers.isNotEmpty) {
      final count = blockers.length;
      return 'production cannot run: '
          '$count ${count == 1 ? 'blocker' : 'blockers'}.';
    }
    if (outstanding.isEmpty) {
      return 'production could run, and every destination it acts on is '
          'already recorded for this build — all that is left is the version '
          'tag.';
    }
    return 'production could run.';
  }

  String _blockers() => blockers
      .map(
        (blocker) =>
            '  ${blocker.summary}\n${_wrap(blocker.detail, indent: 4)}',
      )
      .join('\n\n');

  String _work() {
    final done = acting.length - outstanding.length;
    final heading = done == 0
        ? 'it would act on ${acting.length}, in table order:'
        : 'it would act on ${outstanding.length} of ${acting.length}, in '
              'table order; the '
              '${done == 1 ? 'other one is' : 'other $done are'} recorded:';

    // **The three columns are padded**, for the reason the grid's are: an
    // operator reads down the middle one to find out how much of this is
    // theirs to do by hand, and §3's AuthPass table has five manual consoles
    // in production. Ragged, that column is a thing to search for rather than
    // a thing to count.
    final rows = [
      for (final destination in outstanding)
        (
          destination.name,
          destination.stepAt(Stage.production).kind.name,
          _whereFor(destination),
        ),
    ];
    final names = _widest([for (final row in rows) row.$1]);
    final kinds = _widest([for (final row in rows) row.$2]);
    final lines = [
      for (final row in rows)
        '  ${row.$1.padRight(names)}  ${row.$2.padRight(kinds)}'
                '  ${row.$3}'
            .trimRight(),
    ];
    return [heading, ...lines].join('\n');
  }

  /// Where the operator goes for [destination]: a console, a command, a note.
  String _whereFor(Destination destination) {
    final step = destination.stepAt(Stage.production);
    return step.console ?? step.command ?? step.note ?? '';
  }

  String _finish() {
    // **A destination `production` acts on that the tag does not wait for is
    // named**, because otherwise two counts on adjacent lines disagree with no
    // explanation: AuthPass's `fdroid` is acted on at production and excluded
    // from the finish rule, so "acts on 2" sits above "waits on 1". §3 step 5
    // is why — its step pushes `fdroid-vX.Y.Z`, which cannot precede the tag
    // it annotates — and a reader who has to work that out from the table is
    // one who will assume the tool lost a row.
    final after = [
      for (final destination in acting)
        if (destination.afterFinish) destination.name,
    ];
    final note = after.isEmpty
        ? ''
        : ' ${after.join(', ')} ${after.length == 1 ? 'is' : 'are'} not '
              'counted: the step runs after the tag it annotates.';

    if (finish.isSatisfied) {
      return _wrap(
        'the version tag is not held up: every destination that has a '
        'production step is recorded.$note',
      );
    }
    final names = finish.waitingOn.map((it) => it.name).join(', ');
    return _wrap(
      'the version tag waits on ${finish.waitingOn.length}: $names.$note',
    );
  }

  /// What a clean answer here does *not* cover.
  ///
  /// **Printed on every run, including a clean one, and that is the point.**
  /// §3's `ready` is four bullets and this is one of them; an operator who
  /// reads "production could run" and takes it for the whole check is exactly
  /// the failure this verb exists to prevent, and they would be right to, since
  /// nothing else in the output says otherwise. It goes when the reads land.
  String _notChecked() => _wrap(
    'not checked here: whether an artifact for build $candidate exists at '
    'each destination, whether the local macOS build was made, and the '
    'pre-release hook (a CHANGELOG section for $version, the F-Droid '
    'changelog). Those are reads this verb does not have yet, so a clean '
    'answer above is narrower than a clean `ready`.',
  );

  /// Wraps [text] at 76 columns, optionally under an [indent].
  ///
  /// A blocker's detail is a paragraph and the terminal is not guaranteed to
  /// be wide; the grid never had this problem because a cell is three words.
  String _wrap(String text, {int indent = 0}) {
    final margin = ' ' * indent;
    final width = 76 - indent;
    final words = text.split(RegExp(r'\s+')).where((it) => it.isNotEmpty);
    final lines = <String>[];
    var line = StringBuffer();
    for (final word in words) {
      if (line.isNotEmpty && line.length + 1 + word.length > width) {
        lines.add('$margin$line');
        line = StringBuffer();
      }
      if (line.isNotEmpty) {
        line.write(' ');
      }
      line.write(word);
    }
    if (line.isNotEmpty) {
      lines.add('$margin$line');
    }
    return lines.join('\n');
  }
}

/// The longest of [values], or zero.
int _widest(List<String> values) =>
    values.fold(0, (widest, it) => it.length > widest ? it.length : widest);

/// The refusal recorded for [destination] at production, if there is one.
PromotionRecord? _refusalAt(PromotionLedger ledger, Destination destination) {
  final record = ledger.recordFor(destination.name, Stage.production);
  return record?.outcome == PromotionOutcome.attemptedAndRefused
      ? record
      : null;
}
