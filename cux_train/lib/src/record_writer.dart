/// Writing a promotion record, which is the first thing in this package that
/// touches git.
///
/// **Everything else here parses and answers questions; this does not, and the
/// line is worth keeping visible.** `DestinationTable`, `PromotionLedger` and
/// `evidenceFor` are pure because a caller hands them text — which is what lets
/// every case be tested with no credential and no network, and that property is
/// deliberately preserved rather than abandoned here: the git this file runs is
/// `cux_ship`'s [Git] handle over a checkout root, so a test points it at a
/// temporary repository and gets the real behaviour.
///
/// **It writes almost nothing itself.** §9 item 4 asked whether the writer
/// belongs in `cux_train` or in `cux_ship`, and the answer turned out to be
/// neither-as-posed: `cux_ship` already had the writer, in `recordUpload`,
/// whose [UploadRecord] has said since it was written that *the caller owns the
/// convention* for the tag name. So the split is along that seam —
/// `promotion_record.dart` owns the grammar, `cux_ship` owns the tag, and this
/// file is the forty lines between them.
///
/// What that seam buys, none of which is reimplemented here: a refusal when the
/// name already points at a different commit, a refusal when something else
/// left a lightweight tag under the name, the retry that distinguishes a
/// rejected push from a collision, and the check against `origin` rather than
/// against this clone.
library;

import 'package:cux_ship/provenance.dart';

import 'promotion_record.dart';

/// **Re-exported, because they are in this function's signature.** A caller
/// that has `writePromotion` but cannot name [Git], [UploadRecordResult] or
/// [UploadCollisionException] without a second import is being asked to know
/// which package each half came from — which is exactly the seam this file
/// exists to make invisible.
export 'package:cux_ship/provenance.dart'
    show Git, UploadCollisionException, UploadRecordResult;

/// A record this file would not write, and why.
class PromotionWriteException implements Exception {
  PromotionWriteException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Writes [record] as an annotated tag at the commit [uploadedTag] names.
///
/// [uploadedTag] is the `uploaded/` tag for the build — `cux_ship`'s own record
/// that this artifact was handed to a store, named by that repository's
/// `tag.upload.format` and therefore **passed in rather than composed here**.
/// The default is `uploaded/v{version}+{build}`; a consumer that changed it
/// would otherwise get a writer looking for a tag nobody writes.
///
/// [note] is the operator's line of why, required for a refusal and optional
/// otherwise.
///
/// **[push] is for tests, exactly as it is on [recordUpload].** A promotion
/// that is not pushed is a record only on this machine, and the push is also
/// the only thing that sees the same name recorded at another commit from
/// somewhere else.
///
/// Returns what `cux_ship` reports, including
/// [UploadRecordResult.writtenNotPushed] — see `failedPushIsFatal` on
/// [recordUpload] for why a promotion tolerates a failed push and an upload
/// record must not.
UploadRecordResult writePromotion({
  required Git git,
  required PromotionRecord record,
  required String uploadedTag,
  String? note,
  bool push = true,
  bool dryRun = false,
}) {
  // **Nothing is written that this package could not read back.**
  // `PromotionRecord` is a plain value and takes what it is given — a build of
  // 0, a version with a `/` in it, a destination spelt `direct/apk` — and its
  // `ref` formats every one of them. The tag would be created and pushed, and
  // the next ledger read, which insists that every ref in the namespace
  // parses, would then refuse the namespace for every build, not only this
  // one. So the name is read back before anything is written, and has to come
  // out as the record that went in.
  _refuseUnreadable(record);

  // **A refusal with nothing said about it is the state `s` already covers.**
  // §6.1 gives the operator three keys: `d` records, `s` leaves the cell
  // unrecorded so the next run stops at it again, and `f` records "that it was
  // *attempted and refused*, with a line of why". Writing an unexplained
  // refusal puts a permanent, pushed tag in the repository saying a console
  // said no and nothing more, which a person reading it next week cannot act
  // on — and the step it describes is one only a person can repeat.
  if (record.outcome == PromotionOutcome.attemptedAndRefused &&
      (note == null || note.trim().isEmpty)) {
    throw PromotionWriteException(
      'Refusing to record ${record.ref} with no reason. A refusal is written '
      'to be read by whoever picks the release up next, and "the console said '
      'no" without the rest is what leaving it unrecorded already says.',
    );
  }

  // **The commit comes from the `uploaded/` tag, never from a search.**
  // `UploadRecord.commit` is explicit that the tag must name the commit the
  // artifact was *built from* rather than one found by looking for a version,
  // and gives the failure: a version bump lands, review adds more commits, the
  // release is built from the branch tip, and a tag placed at "the commit
  // carrying the version" names code predating every one of those fixes. The
  // `uploaded/` tag is the one thing in the repository that already knows the
  // right answer, because `cux_ship` wrote it from the build manifest's
  // `gitSha` at upload.
  final commit = taggedCommit(git, uploadedTag);
  if (commit == null) {
    throw PromotionWriteException(
      'No tag `$uploadedTag` in this checkout, so there is no commit to '
      'record ${record.ref} at. Build ${record.build} was either never '
      'uploaded from here or its tag has not been fetched — `git fetch '
      'origin "+refs/tags/*:refs/tags/*"` and try again. Promotions are '
      'recorded against the commit the artifact was built from, which only '
      'that tag knows.',
    );
  }

  return recordUpload(
    git,
    UploadRecord(
      name: record.ref,
      commit: commit,
      annotation: _annotation(record, note),
    ),
    push: push,
    dryRun: dryRun,
    // A promotion record is written after the promotion happened. See
    // `recordUpload`'s doc: failing the run here does not un-promote anything,
    // it costs the operator the console step they just finished.
    failedPushIsFatal: false,
  );
}

/// Throws unless [record]'s ref parses back to [record].
void _refuseUnreadable(PromotionRecord record) {
  final PromotionRecord reread;
  try {
    reread = PromotionRecord.parse(record.ref, source: 'writePromotion');
  } on PromotionRecordException catch (e) {
    throw PromotionWriteException(
      'Refusing to record `${record.ref}`, which would not read back as a '
      'promotion record — ${e.message}',
    );
  }
  if (reread.destination != record.destination ||
      reread.stage != record.stage ||
      reread.version != record.version ||
      reread.build != record.build ||
      reread.outcome != record.outcome) {
    throw PromotionWriteException(
      'Refusing to record `${record.ref}`: it was written for '
      '`${record.destination}` at ${record.stage.name}, version '
      '${record.version}, and reads back as `${reread.destination}` at '
      '${reread.stage.name}, version ${reread.version}. A `/` in a '
      'destination or a version changes where the name is split.',
    );
  }
}

/// The tag body.
///
/// First line matches `cux_ship`'s own `uploaded/` annotation — `build 69 of
/// 1.1.0` — because the two namespaces are read side by side and a reader
/// should not have to learn two shapes.
///
/// **The second line carries the destination in its `family:member` spelling**,
/// which the tag name cannot: the name writes `appstore:ios` as
/// `appstore/ios`, and although [PromotionRecord.parse] recovers it by reading
/// from the right, a person running `git show` gets no such help. It costs one
/// line to make the tag say what it is without the parser.
String _annotation(PromotionRecord record, String? note) {
  final what = switch (record.outcome) {
    PromotionOutcome.handedOver => 'handed over',
    PromotionOutcome.attemptedAndRefused => 'attempted and refused',
  };
  final lines = [
    'build ${record.build} of ${record.version}',
    '${record.destination} ${record.stage.name} — $what',
    if (note != null && note.trim().isNotEmpty) note.trim(),
  ];
  return lines.join('\n');
}
