/// Every promotion record for one release candidate, and the questions a run
/// asks of them.
///
/// **Two questions, and they are the whole of resumable `production`.** What
/// is left to do (§3: "a re-run must skip what is recorded and pick up at the
/// first destination that is not"), and whether the version tag may be spent
/// (§4's finish rule). Both are counted over the table, never over the records
/// alone — a record names a destination, but only the table knows which
/// destinations were supposed to act.
///
/// **Keyed to one build, because a ledger is history.** `promoted/` holds
/// every release ever made, so "is `huawei` recorded?" is meaningless without
/// saying recorded *for which build*. §2 is emphatic that the candidate is
/// named rather than inferred, and this is the same discipline one layer down.
library;

import 'destinations.dart';
import 'promotion_record.dart';

/// The records for one build, read from ref names.
class PromotionLedger {
  PromotionLedger(Iterable<PromotionRecord> records)
    : records = List.unmodifiable(records);

  /// Reads every ref in [refs], keeping those for [build].
  ///
  /// [refs] is what a caller gets from globbing the namespaces
  /// [PromotionOutcome.namespaces] names — ref names without `refs/tags/`.
  /// Every one of them must parse; see [PromotionRecord.parse] for why a
  /// stray one is an error rather than a skip.
  factory PromotionLedger.forBuild(
    Iterable<String> refs, {
    required int build,
    required String source,
  }) {
    final records = <PromotionRecord>[];
    for (final ref in refs) {
      final record = PromotionRecord.parse(ref, source: source);
      if (record.build == build) {
        records.add(record);
      }
    }
    return PromotionLedger(records);
  }

  final List<PromotionRecord> records;

  /// What is recorded for [destination] at [stage], or null.
  ///
  /// **A refusal wins over a hand-over, whichever was written first.** They
  /// can both exist: an operator records `f` on Monday, the console accepts
  /// the resubmission on Thursday, and `d` is recorded — but also the reverse,
  /// a hand-over on Monday and a rejection email on Thursday. Returning the
  /// worse of the two is the fail-closed reading: it makes a re-run stop at
  /// the destination and show a human both refs, rather than walking past a
  /// destination that is in a state nobody intended. Writing both is rare
  /// enough that guessing which is newer from ref names — which carry no
  /// time — would be a worse answer than refusing to guess.
  PromotionRecord? recordFor(String destination, Stage stage) {
    PromotionRecord? found;
    for (final record in records) {
      if (record.destination != destination || record.stage != stage) {
        continue;
      }
      if (record.outcome == PromotionOutcome.attemptedAndRefused) {
        return record;
      }
      found ??= record;
    }
    return found;
  }

  /// Whether [destination] is done at [stage] for this build.
  bool isHandedOver(String destination, Stage stage) =>
      recordFor(destination, stage)?.outcome == PromotionOutcome.handedOver;

  /// The destinations in [acting] that this run still has to reach, in order.
  ///
  /// **A refusal is outstanding, which is what makes `f` different from a
  /// record of success and not merely a note.** The destination comes up
  /// again on the next run, carrying what happened last time.
  List<Destination> outstanding(List<Destination> acting, Stage stage) => [
    for (final destination in acting)
      if (!isHandedOver(destination.name, stage)) destination,
  ];
}

/// Whether the bare `vX.Y.Z` tag may be spent, and what is holding it.
class FinishRule {
  FinishRule({required List<Destination> waitingOn})
    : waitingOn = List.unmodifiable(waitingOn);

  /// Destinations that have a production step, are not ordered after finish,
  /// and are not recorded as handed over.
  final List<Destination> waitingOn;

  bool get isSatisfied => waitingOn.isEmpty;
}

/// §4's finish rule: every declared destination that has a production step is
/// recorded at production.
///
/// **Two exclusions, and without them the rule can never be met** — §3 step 5
/// sets out both.
///
/// A destination whose production kind is `none` is satisfied **vacuously**:
/// nobody acts, so nothing writes a record, and waiting for one would hold the
/// version tag forever. `web`, `packagecloud` and `flathub` are all this.
///
/// A destination declared [Destination.afterFinish] is excluded because its
/// step runs *after* the tag it annotates — AuthPass's `fdroid` pushes
/// `fdroid-vX.Y.Z`, which cannot precede `vX.Y.Z`. It is the one destination
/// finish does not wait on, and it is table data rather than a name in this
/// file because the next consumer's will not be called `fdroid`.
///
/// **It is not keyed on how this invocation was narrowed.** The donor's
/// `isEveryStore` asked whether `--store` named everything, which cannot
/// survive a `production` that spans days: the operator who finishes the last
/// console with `--store ppa production` would never be allowed to spend the
/// tag. The question is about the record, so the answer comes from the record.
FinishRule finishRule({
  required DestinationTable table,
  required PromotionLedger ledger,
}) => FinishRule(
  waitingOn: [
    for (final destination in table.destinations)
      if (destination.stepAt(Stage.production).kind != StepKind.none &&
          !destination.afterFinish &&
          !ledger.isHandedOver(destination.name, Stage.production))
        destination,
  ],
);
