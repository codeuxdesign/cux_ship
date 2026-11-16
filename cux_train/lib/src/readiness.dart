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
/// **What it adds over `status` is a reading rather than a picture.** The grid
/// shows every cell and leaves the sense of it to a person who knows the
/// evidence model; this says what `production` would do next, what the version
/// tag is waiting for, and what an operator should take with them — in a form
/// somebody can act on without knowing what `attested` means.
///
/// **It is not a gate, and the first draft of it was.** That draft answered
/// no when a destination had refused the build, which is backwards: §6.1
/// records a refusal precisely so that the next `production` run returns to
/// that destination. [ReadinessWarning] has what that cost and how it was
/// found. A `ready` that can say no arrives with the reads, where §3's
/// refusals actually live.
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

/// Something an operator should know before `production` runs, not a veto.
///
/// **The first version of this type was called `ReadinessBlocker` and made
/// `ready` exit non-zero, which inverted the design.** §6.1 is explicit that a
/// refusal is recorded *so that* the next `production` run stops at that
/// destination again — `f` exists because `s` alone makes "the console
/// rejected the binary" look like "nobody has looked yet". A refusal is
/// therefore a reason to run `production`, not a reason not to.
///
/// The inversion was not cosmetic. Nothing clears a refusal, and
/// [PromotionLedger.recordFor] lets one win over a later hand-over, so a
/// `ready` that failed on a refusal failed forever: with `train ready &&
/// train production` — the line this package's own README recommended — one
/// `f` on Monday blocked that build's release permanently, including the five
/// other consoles still outstanding. Verified against a real repository
/// before this was changed.
///
/// **It is still kept apart from the outstanding work**, which is the useful
/// half of the original idea. Five destinations nobody has reached are what
/// `production` is for; a destination that turned this build down is one it
/// will walk back into carrying a rejection, and an operator who reads that as
/// an ordinary queue entry will resubmit the same binary.
class ReadinessWarning {
  const ReadinessWarning({
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
    required List<ReadinessWarning> warnings,
    required List<Destination> acting,
    required List<Destination> outstanding,
    required this.finish,
  }) : warnings = List.unmodifiable(warnings),
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

    // **A record for a destination the table does not declare is refused.**
    // The table says where this release goes and the records say where it has
    // been; one naming a place the other does not know is a disagreement about
    // the release itself, and the quiet reading of it is the bad one — the
    // destination would simply not appear, and an answer that silently left
    // out a rejection is the failure §2 says the record exists to prevent.
    // The same shape as the grid's refusal of an observation it cannot place.
    final declared = {for (final it in table.destinations) it.name};
    final undeclared =
        ledger.records
            .map((it) => it.destination)
            .where((name) => !declared.contains(name))
            .toSet()
            .toList()
          ..sort();
    if (undeclared.isNotEmpty) {
      throw ReadinessException(
        'Build $candidate of $version has a record for '
        '${undeclared.join(', ')}, which the destination table does not '
        'declare. It declares ${declared.join(', ')}. Either the release went '
        'somewhere this table does not list, or a destination was renamed '
        'after it was recorded — and an answer about what `production` has '
        'left to do cannot be right while the two disagree.',
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
      warnings: [
        for (final destination in acting)
          if (_refusalAt(ledger, destination) case final refusal?)
            ReadinessWarning(
              destination: destination.name,
              summary: '${destination.name} turned this build down',
              detail:
                  '`${refusal.ref}` records that ${destination.name} was '
                  'offered build $candidate of $version at production and '
                  'refused it. `production` is how that is retried: the '
                  'destination is outstanding rather than finished, so a '
                  're-run stops there again and asks. Take the rejection with '
                  'you — resubmitting the same binary unchanged is what the '
                  'record is warning against. Note that nothing clears a '
                  'refusal: once the console accepts it, this line stays'
                  // An after-finish destination is the one the finish rule
                  // never waited on, and the line under the warnings says so.
                  '${destination.afterFinish ? '' : ', and the finish rule '
                            'goes on waiting'}.',
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

  /// What an operator should know before starting, in table order.
  final List<ReadinessWarning> warnings;

  /// Every destination with a production step, in table order.
  final List<Destination> acting;

  /// Those of [acting] with no hand-over recorded for this candidate.
  final List<Destination> outstanding;

  /// Whether the version tag may be spent, and what is holding it.
  final FinishRule finish;

  /// The answer as a block of text, ending in a newline.
  ///
  /// **Nothing here can say no, and that is the honest shape of this half of
  /// the verb.** §3's `ready` refuses on four conditions and three of them are
  /// reads this package does not have. Of what is left, a refusal turned out
  /// to be a reason to *run* `production` rather than a veto (see
  /// [ReadinessWarning]), and the two states that genuinely are not answerable
  /// — a table that declares no production step, a record that disagrees with
  /// the table — are thrown rather than rendered. So `ready` reports, and the
  /// first thing that can make it refuse arrives with the reads.
  ///
  /// An answer with nothing outstanding prints no work block: the verdict has
  /// already said every destination is recorded, and a heading over no rows is
  /// a colon with nothing after it.
  String render() {
    final blocks = <String>[
      '$version — build $candidate',
      _verdict(),
      if (warnings.isNotEmpty) _warnings(),
      if (outstanding.isNotEmpty) _work(),
      _finish(),
      _notChecked(),
    ];
    return '${blocks.join('\n\n')}\n';
  }

  String _verdict() {
    if (outstanding.isEmpty) {
      return _wrap(
        'production could run, and every destination it acts on is already '
        'recorded for this build — all that is left is the version tag.',
      );
    }
    return 'production could run.';
  }

  String _warnings() {
    final count = warnings.length;
    final heading = count == 1
        ? 'one thing to take with you:'
        : '$count things to take with you:';
    final blocks = warnings.map(
      (warning) => '  ${warning.summary}\n${_wrap(warning.detail, indent: 4)}',
    );
    return [heading, ...blocks].join('\n\n');
  }

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
  /// **Named by category, not by AuthPass's instances.** The draft of this
  /// block said "the local macOS build" and "the F-Droid changelog", which are
  /// two rows of one consumer's table printed at every other consumer. The
  /// whole argument for the destination table is that the tool holds no list
  /// of stores, and a sentence that does is the same mistake in prose.
  String _notChecked() => _wrap(
    'not checked here: whether every CI-built destination has its artifact '
    'for build $candidate, whether anything built outside CI has been built, '
    'and whatever this repository checks before a release — a '
    'section for $version in the changelog, and the rest of its pre-release '
    'gate. Those are reads this verb does not have yet, so a clean answer '
    'above is narrower than a clean `ready`.',
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
