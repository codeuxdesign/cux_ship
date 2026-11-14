/// What `status` is allowed to claim about one cell, and on what grounds.
///
/// **The grid's job is to say which kind of evidence it has, never to render
/// two kinds the same way.** §6.2: "Where only attestation exists, the grid
/// says so in the cell and never promotes it to *holds*." A record says a
/// person pressed `d` in a console; a read says the store answered. Rendering
/// "submitted to Huawei" and "Play production holds 2196" identically is the
/// failure §2 calls *not being able to tell*, and it is the reason this is six
/// marks rather than a boolean.
///
/// **Nothing here performs a read.** An [Observation] is handed in, already
/// made, by whatever could reach the destination — which keeps the rules
/// testable without a network and keeps `status` honest about the case where
/// the read itself fell over.
library;

import 'destinations.dart';
import 'promotion_ledger.dart';
import 'promotion_record.dart';

/// §6.2's six marks.
enum EvidenceMark {
  /// The destination was read and holds the build in the cell.
  observed,

  /// A `promoted/` record says a person or a script did it, and nothing
  /// independent confirms it. Huawei, Amazon, the PPA.
  attested,

  /// A read and a record name different builds.
  ///
  /// **The most valuable line the tool can print** (§6.2), and the reason it
  /// needs a mark rather than a sentence in prose: snap `stable` would be
  /// recorded at 2196 while `api.snapcraft.io` answers 1940.
  disagreed,

  /// A step ran, or was attempted, and did not land — a CI job that failed, a
  /// console that refused the binary. Never [pending]: rendering a refusal as
  /// "nothing is known" loses exactly the distinction the record exists for.
  failed,

  /// No evidence either way: nothing was read, nothing is recorded, and
  /// nothing is known to have failed.
  pending,

  /// This destination has no such stage. Every non-store `beta` cell.
  notApplicable,
}

/// What a read found, if one was made.
///
/// **Sealed, because the cases are not variations on a number.** "The store
/// answered 1940", "CI says the job failed" and "the endpoint timed out" lead
/// to three different marks, and a nullable build number could express only
/// the first.
sealed class Observation {
  const Observation();
}

/// The destination was read and holds [build].
class Holds extends Observation {
  const Holds(this.build);

  final int build;
}

/// Something that ran on this destination's behalf did not land.
///
/// §3's `internal` reports "its CI job has failed"; §6.1's `f` is the operator
/// recording the same shape by hand, and that one arrives as a record instead.
class StepFailed extends Observation {
  const StepFailed(this.reason);

  final String reason;
}

/// A read was attempted and could not answer.
///
/// **Not evidence about the step**, which is why it does not produce
/// [EvidenceMark.failed]: an endpoint that times out says nothing about
/// whether the build is there. The cell falls back to whatever the record
/// says and carries [reason] so the grid can show why it is not better.
class Unreadable extends Observation {
  const Unreadable(this.reason);

  final String reason;
}

/// One cell of the grid.
class Evidence {
  const Evidence({
    required this.mark,
    this.build,
    this.note,
    this.publicAtInternal = false,
  });

  final EvidenceMark mark;

  /// The build the cell names, which is **not always the candidate**.
  ///
  /// §3 is explicit that a cell holding something else is named as such and
  /// "never normalised away, because that difference is the thing worth
  /// seeing". Null where there is nothing to name.
  final int? build;

  /// Why the cell is what it is, where that is not obvious from the mark: the
  /// refusal's reason, the read's error, the two builds that disagree.
  final String? note;

  /// §6.2's one annotation, which sits beside the mark rather than among them.
  ///
  /// True for a destination that reaches users the moment the release is
  /// pushed — AuthPass's `web`, `packagecloud` and snap `edge`. It is a
  /// property of the destination's stages, not of this cell's evidence, which
  /// is why it is not a mark.
  final bool publicAtInternal;
}

/// The mark for one destination at one stage.
///
/// [observation] is null where no read was made — the destination declares no
/// `read`, or this run did not attempt one.
Evidence evidenceFor({
  required Destination destination,
  required Stage stage,
  required int candidate,
  required PromotionLedger ledger,
  Observation? observation,
}) {
  final annotation = destination.publicAtInternal;

  // **`n/a` first, because it is a fact about the table rather than about
  // this release.** A destination nobody acts at cannot be pending: there is
  // nothing to wait for, and a grid that shows fifty-seven cells of which
  // twenty-four say "pending" has buried the four that matter.
  if (destination.stepAt(stage).kind == StepKind.none) {
    return Evidence(
      mark: EvidenceMark.notApplicable,
      publicAtInternal: annotation,
    );
  }

  final record = ledger.recordFor(destination.name, stage);
  final attested = record?.outcome == PromotionOutcome.handedOver;

  switch (observation) {
    case Holds(:final build):
      if (build != candidate) {
        // **A read that found something else is still a read.** With a record
        // claiming the candidate, the two disagree and that is the headline.
        // With no record, nothing is being contradicted — the destination
        // simply holds an older build, which the cell names.
        return Evidence(
          mark: attested ? EvidenceMark.disagreed : EvidenceMark.observed,
          build: build,
          note: attested ? 'recorded at $candidate, holds $build' : null,
          publicAtInternal: annotation,
        );
      }
      // It holds the candidate. A refusal on record is contradicted by the
      // destination itself, which is worth saying rather than quietly
      // preferring the read.
      if (record?.outcome == PromotionOutcome.attemptedAndRefused) {
        return Evidence(
          mark: EvidenceMark.disagreed,
          build: build,
          note: 'recorded as refused, but holds $build',
          publicAtInternal: annotation,
        );
      }
      return Evidence(
        mark: EvidenceMark.observed,
        build: build,
        publicAtInternal: annotation,
      );

    case StepFailed(:final reason):
      return Evidence(
        mark: EvidenceMark.failed,
        build: candidate,
        note: reason,
        publicAtInternal: annotation,
      );

    // **An unreadable destination falls back to the record, and says why.**
    // The read failing is not evidence that the step did not land.
    // Shared body on purpose: "the read could not answer" and "no read was
    // made" are the same thing as far as the mark goes. They differ only in
    // whether there is a reason to show, so the reason is read off the
    // observation rather than destructured — a pattern variable bound in one
    // case and not the other cannot be shared.
    case Unreadable():
    case null:
      return _fromRecordAlone(
        record: record,
        candidate: candidate,
        note: observation is Unreadable ? observation.reason : null,
        publicAtInternal: annotation,
      );
  }
}

Evidence _fromRecordAlone({
  required PromotionRecord? record,
  required int candidate,
  required String? note,
  required bool publicAtInternal,
}) {
  switch (record?.outcome) {
    case PromotionOutcome.handedOver:
      return Evidence(
        mark: EvidenceMark.attested,
        build: candidate,
        note: note,
        publicAtInternal: publicAtInternal,
      );
    case PromotionOutcome.attemptedAndRefused:
      return Evidence(
        mark: EvidenceMark.failed,
        build: candidate,
        // **The refusal is why this cell is `failed`, so it is always said.**
        // An unreadable endpoint adds its reason and never replaces this one:
        // on its own, "504 from the API" under `failed` would read as the
        // step having failed for that reason.
        note: note == null
            ? 'attempted and refused'
            : 'attempted and refused; $note',
        publicAtInternal: publicAtInternal,
      );
    case null:
      return Evidence(
        mark: EvidenceMark.pending,
        note: note,
        publicAtInternal: publicAtInternal,
      );
  }
}
