// SPDX-License-Identifier: Apache-2.0
//
// What reached a store, and from which commit.
//
// A build number answers "which commit is build 49?" only for as long as the
// commit exists. Nothing in a note keeps it alive — the SHA is recorded as
// content, never as a reference — so `git gc` collects it once the last branch
// containing it goes away, and the lookup then succeeds while naming an object
// that is gone. Two repositories using this tooling already carry such commits:
// 8 of 46 in one, 3 in the other, reachable from no ref at all.
//
// That half is fixed upstream in git-buildnumber, by giving the allocation chain
// the built commit as a parent. This file is the other half: **an annotated tag
// written when an artifact actually reaches a store**, so the repository records
// what was published rather than only what was built.
//
// Three decisions, each of which has a failure behind it.
//
// **Written by the first store that succeeds, not when all of them have.**
// Partial success is the steady state rather than an edge case: platforms ship
// from independent workflows on different triggers, and many commits ship on
// some and never on others. There is no all-shipped moment to wait for, so
// waiting for one means the record is missing during exactly the window it
// exists for.
//
// **Annotated, and the annotation carries the build number.** The number lives
// in a git note, not in `pubspec.yaml`, so the file at that commit reads
// whatever it read at the time — one repository's orphaned commits all say
// `1.0.3+1` while being builds 45, 47 and 53. Anything reconstructing "what was
// build 47" from the commit's pubspec gets the version right, the build wrong,
// and no warning. The annotation is where the truth goes.
//
// **The tag is created before the store is contacted**, and a failed push fails
// the caller. An unpushed tag is indistinguishable from no tag on the machine
// that will do the upload, and tagging afterwards makes the failure mode
// "shipped but unprovable" — an artifact in front of users whose commit nobody
// can name.
import 'release.dart' show Git, ReleaseException;

/// The tag recording that [commit] reached a store.
///
/// [name] is the whole tag name, including any namespace — the caller owns the
/// convention, because what a *released* tag is called differs per repository
/// and this must never assume a shape.
class UploadRecord {
  const UploadRecord({
    required this.name,
    required this.commit,
    required this.annotation,
  });

  final String name;

  /// The commit the artifact was **built from** — the build manifest's
  /// `gitSha`, never a commit found by searching for a version.
  ///
  /// Those are not the same commit and the difference has shipped wrong code: a
  /// version bump lands, review then adds several more commits, and the release
  /// is published from the branch tip. A tag placed at "the commit carrying the
  /// version" names code predating every one of those fixes.
  final String commit;

  /// Free text for the tag body: the build number, the artifact checksum, and
  /// which store took it.
  final String annotation;
}

/// Outcome of [recordUpload], so a caller can report without re-deriving it.
enum UploadRecordResult {
  /// The tag did not exist and now does.
  created,

  /// The tag already pointed at this commit. Re-running an upload is ordinary —
  /// a second store, a retried job — and must not be an error.
  alreadyRecorded,
}

/// Records that [record] reached a store, and pushes it.
///
/// Idempotent for a repeated upload of the same artifact, and a hard error when
/// the same name already names a *different* commit.
///
/// **"The tag exists" is not idempotence**, and the distinction is the whole
/// point of this function. `git tag` refuses an existing name whether it points
/// at the same commit or a different one, so a caller that treats refusal as
/// success will publish one artifact while the record names another. Where a
/// build number can be allocated twice — concurrent CI on different commits, or
/// a forced number — that is precisely how it happens.
UploadRecordResult recordUpload(
  Git git,
  UploadRecord record, {
  bool push = true,
  bool dryRun = false,
}) {
  final existing = _taggedCommit(git, record.name);

  if (existing != null) {
    if (existing == record.commit) {
      return UploadRecordResult.alreadyRecorded;
    }
    throw ReleaseException(
      'Tag ${record.name} already names a different commit.\n'
      '  it points at:   $existing\n'
      '  this artifact:  ${record.commit}\n'
      'One build number has been used for two commits, so publishing this '
      'would leave the record naming the wrong one. Nothing was uploaded.',
    );
  }

  if (dryRun) {
    return UploadRecordResult.created;
  }

  git.run(['tag', '-a', record.name, record.commit, '-m', record.annotation]);

  if (push) {
    // Deliberately not `allowFailure`. Elsewhere a failed tag push is a warning
    // because the release has already gone out and the tag is bookkeeping; here
    // nothing has gone out yet, and an unpushed tag protects nothing on the
    // machine that will do the upload.
    git.run(['push', 'origin', 'refs/tags/${record.name}']);
  }

  return UploadRecordResult.created;
}

/// The commit an existing tag resolves to, or null when the tag is absent.
///
/// **`^{commit}` is load-bearing.** These are annotated tags, so plain
/// `rev-parse <tag>` yields the *tag object* rather than the commit. Compared
/// against a manifest's `gitSha` that mismatches on every legitimate repeat,
/// turning the idempotent case into a hard error — the inverse of the bug the
/// comparison exists to catch, and one that only shows on the happy path.
String? _taggedCommit(Git git, String name) {
  if (!git.ok(['rev-parse', '--verify', '--quiet', 'refs/tags/$name'])) {
    return null;
  }
  return git.run(['rev-parse', 'refs/tags/$name^{commit}']);
}
