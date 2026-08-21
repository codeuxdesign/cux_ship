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
// written when an artifact is handed to a store**, so the repository records
// what was published rather than only what was built.
//
// **What the tag means, stated precisely, because it is not what the name
// suggests.** It is written *before* the store is contacted — see the third
// decision below — so it means "an upload was attempted, with this artifact, at
// this commit". It does not mean the store accepted. A signature refusal or an
// API validation failure leaves the tag standing over an artifact that never
// reached anyone. That is the right trade, because the alternative failure mode
// is "shipped but unprovable", but anything reading these tags — a promotion
// script, a person scanning the tag list — has to read them as attempts. A
// consumer that treats the tag as proof of acceptance is making an assumption
// this file does not support.
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
import 'config.dart' show TagKindConfig;
import 'release.dart'
    show Git, ReleaseException, remoteTaggedCommit, resolveCommit, taggedCommit;

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

/// One build number naming two commits — the thing [recordUpload] exists to
/// refuse.
///
/// **Its own type so a wrapper can tell it apart from an ordinary upload
/// failure**, which matters more than it looks. Release scripts routinely
/// tolerate a store refusing a build it already has — re-running a release is
/// meant to be a no-op, so the upload is called under `|| exitCode=$?` and the
/// pipeline carries on. A collision exiting through that same path is reported
/// as the tolerable kind and the release finishes green, which turns the
/// loudest error here into the quietest. A distinct type gives the CLI a
/// distinct exit code, and the wrapper something to match on.
/// What `cux_ship` exits with when [UploadCollisionException] is raised.
///
/// **A number, because a shell wrapper cannot match on a Dart type.** The class
/// above has existed since 3.3.0 saying it "gives the CLI a distinct exit code";
/// it did not, so the only thing a wrapper could see was 1 — the same as every
/// other failure, including the tolerable one it deliberately swallows.
///
/// 3 rather than 1, and not 2, which `screenshots flatten --check` already uses
/// for "there is work to do". Deliberately not 65 or any other sysexits value:
/// those describe *categories* a caller might already be branching on, and this
/// needs to be unmistakably one thing.
const uploadCollisionExit = 3;

class UploadCollisionException extends ReleaseException {
  UploadCollisionException(super.message);
}

/// Outcome of [recordUpload], so a caller can report without re-deriving it.
enum UploadRecordResult {
  /// The tag did not exist, and now does — or under `dryRun`, would.
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
/// **[push] is for tests, and an upload path must never pass false.** The push
/// is not bookkeeping here — it is the only guard that sees a collision raised
/// on another machine. Locally this function can compare against a tag this
/// clone happens to have; the concurrent-CI case it exists for is precisely the
/// one where the other allocation is on a different runner, and the *only* way
/// this process learns of it is the remote rejecting the push. Passing false to
/// save a network round trip keeps every local check and silently forfeits the
/// cross-machine one, with nothing to indicate the guarantee is gone.
UploadRecordResult recordUpload(
  Git git,
  UploadRecord record, {
  bool push = true,
  bool dryRun = false,
}) {
  // "The whole tag name" means the name, not the ref path — and the difference
  // is invisible without this, because every use here is consistent. `git tag`
  // would create `refs/tags/refs/tags/…`, lookups would find it, pushes would
  // publish it, and the run would be green while the record sat under a name
  // nobody will ever look up.
  if (record.name.startsWith('refs/')) {
    throw ReleaseException(
      'Tag name "${record.name}" starts with refs/, which git would nest '
      'under refs/tags/ rather than treat as a path. Pass the name only.',
    );
  }

  final commit = resolveCommit(git, record.commit);
  final existing = taggedCommit(git, record.name);

  if (existing != null && existing != commit) {
    throw UploadCollisionException(
      'Tag ${record.name} already names a different commit.\n'
      '  it points at:   $existing\n'
      '  this artifact:  $commit\n'
      'One build number has been used for two commits, so publishing this '
      'would leave the record naming the wrong one. Nothing was uploaded.',
    );
  }

  if (existing != null && !_isAnnotated(git, record.name)) {
    throw ReleaseException(
      'Tag ${record.name} exists at the right commit but is lightweight, so '
      'it carries no annotation — the build number, the checksum and which '
      'store took it are all absent, and treating it as the record would put '
      'an empty one in the repository. This tool only writes annotated tags, '
      'so something else created it. Delete it and re-run, or annotate it by '
      'hand. Nothing was uploaded.',
    );
  }

  final result = existing == null
      ? UploadRecordResult.created
      : UploadRecordResult.alreadyRecorded;

  if (dryRun) {
    return result;
  }

  if (existing == null) {
    git.run(['tag', '-a', record.name, commit, '-m', record.annotation]);
  }

  if (push) {
    // **Pushed on both paths, not only the one that created the tag.** A local
    // tag is not a record — the machine that will read it is the next CI job,
    // and that one clones. So the run whose push failed must be repairable by
    // the retry, and it is not if the retry sees a local tag, calls that
    // `alreadyRecorded` and returns without pushing: the artifact then uploads
    // against a record that exists nowhere but the machine that has since been
    // torn down. A retried job after a network failure is the ordinary case,
    // not the exotic one.
    //
    // **A rejected push does not mean a collision, and assuming it did broke
    // every parallel release.** The sentence that used to be here said pushing
    // a tag the remote already holds at this commit is a no-op. That is true
    // for lightweight tags and for byte-identical objects, and false for the
    // case that actually happens: two CI jobs sharing a commit and a build
    // number each mint their *own* annotated tag object — different timestamp,
    // different message — and git refuses to replace one with the other. The
    // rejection reads `! [rejected] ... (already exists)`, which is the same
    // words as the collision it is not.
    //
    // So the remote is asked what its tag actually names, exactly as the local
    // path asks above.
    //
    // Deliberately not `allowFailure` beyond this. Elsewhere a failed tag push
    // is a warning because the release has already gone out and the tag is
    // bookkeeping; here nothing has gone out yet, and an unpushed tag protects
    // nothing.
    final pushed = git.ok(['push', 'origin', 'refs/tags/${record.name}']);
    if (!pushed) {
      final remote = remoteTaggedCommit(git, record.name);
      if (remote == null) {
        // Rejected, and origin does not hold this tag — so the push failed for
        // some other reason (credentials, network, a hook). Re-run it without
        // `ok` to surface git's own message rather than inventing one.
        git.run(['push', 'origin', 'refs/tags/${record.name}']);
        // **And return, because the retry may have worked.** Falling through
        // with `remote` still null compared null against the commit and threw
        // a collision reading `origin points at: null` — exit 3, the code
        // wrappers are documented to treat as unrecoverable — for a push that
        // had just landed. A transient failure that succeeds on the second
        // attempt is the ordinary reason to reach this branch.
        return result;
      }
      if (remote != commit) {
        throw UploadCollisionException(
          'Tag ${record.name} already names a different commit on origin.\n'
          '  origin points at:  $remote\n'
          '  this artifact:     $commit\n'
          'One build number has been used for two commits, so publishing this '
          'would leave the record naming the wrong one. Nothing was uploaded.',
        );
      }
      // Same commit, someone else's tag object. Another job recorded this exact
      // build first, which is the ordinary outcome of a release matrix rather
      // than an error: the record exists, on origin, naming the right commit.
      return UploadRecordResult.alreadyRecorded;
    }
  }

  return result;
}

/// Records an upload if the repository asked for it, and does nothing if not.
///
/// **Called before the store is contacted, from the command that contacts it.**
/// An earlier design had each consuming repository write its own record from a
/// shell wrapper for one store and let `cux_ship` do the other — one guarantee
/// implemented twice, in two languages, and skipped entirely by any CI job that
/// called the uploader directly. The refusal in [recordUpload] only protects
/// anything from the path that actually uploads.
///
/// Returns null when recording is off, which is the default: writing pushes a
/// tag to `origin`, so a repository that has not asked for it would suddenly
/// need push credentials on its upload job.
UploadRecordResult? recordUploadIfConfigured(
  String repoRoot,
  TagKindConfig config, {
  required String store,
  required String? version,
  required String? build,
  required String? commit,
  required String? checksum,
  bool dryRun = false,
}) {
  if (!config.enabled) {
    return null;
  }

  // Named individually rather than as "missing arguments", because the fix
  // differs: --commit is the caller's to pass, while a missing version or build
  // usually means the artifact was not described to this command at all.
  if (commit == null || commit.isEmpty) {
    throw ReleaseException(
      'tag.upload.enabled is on and --commit was not given.\n'
      'Pass the commit the artifact was BUILT from — your build manifest\'s '
      'gitSha. It is not inferred from HEAD on purpose: an upload job often '
      'runs on a different checkout from the build, and a record naming the '
      'wrong commit is worse than none.',
    );
  }
  if (version == null || build == null) {
    throw ReleaseException(
      'tag.upload.enabled is on, and the ${version == null ? 'version' : 'build number'} '
      'is not known here — pass --version-name and --build-number so the tag '
      'can be named.',
    );
  }

  return recordUpload(
    Git(repoRoot),
    UploadRecord(
      name: config.nameFor(version: version, build: build),
      commit: commit,
      annotation: <String>[
        'build $build of $version',
        // **No `store:` line, because one tag cannot honestly carry it.** The
        // record is keyed by (version, build) and therefore by commit, and the
        // stores that share a commit share the tag: the first to upload writes
        // it and every other finds it already there and moves on. So a
        // `store:` line named whichever store happened to go first and read as
        // the whole truth — How It Went's build 69 went to Play, TestFlight
        // iOS and TestFlight macOS under a tag saying `store: play`.
        //
        // Recording all of them would mean rewriting a published tag, which is
        // a force-push: the one operation that makes a record stop being
        // evidence, since clones that already fetched it keep the old body and
        // nothing reconciles them. Saying less is the honest fix. What the tag
        // claims now is exactly what it can prove — this commit, this build
        // number, these bytes, uploaded somewhere.
        //
        // Per-store records would need per-store tag *names*; that is a
        // namespace decision, recorded as open in
        // docs/design/upload-record-scope.md.
        if (checksum != null) ...<String>['sha256 $checksum'],
        // Deliberately not a timestamp: the tag object carries its own, and a
        // second one in the body is a thing that can disagree with it.
      ].join('\n'),
    ),
    dryRun: dryRun,
  );
}

/// The refs a build-number allocator keeps, and what `remote.origin.fetch` has
/// to carry for an ordinary `git fetch` to bring them.
///
/// **A clone does not get these.** `refs/buildnumbers/*` and
/// `refs/notes/buildnumbers` are outside `refs/heads` and `refs/tags`, so the
/// default refspec ignores them entirely: a fresh clone has no allocation
/// history until something fetches it explicitly, and the allocator is the only
/// thing that does. That is survivable while the allocator is the only reader —
/// and it stops being survivable the moment the chain is what keeps built
/// commits alive, because then a clone that never fetched the chain is a clone
/// whose `git gc` sees nothing holding them.
const buildnumberFetchRefspecs = <String>[
  '+refs/buildnumbers/*:refs/buildnumbers/*',
  '+refs/notes/buildnumbers:refs/notes/buildnumbers',
];

/// Adds [buildnumberFetchRefspecs] to `remote.<remote>.fetch`, and says what it
/// did. Idempotent.
///
/// **Added rather than replaced**, and with `--add`, because the branch refspec
/// already there is the one every other git operation depends on — a plain
/// `git config remote.origin.fetch <value>` overwrites the whole multi-valued
/// key and would leave a repository that can fetch build numbers and not
/// branches.
List<String> configureBuildnumberRefspecs(
  Git git, {
  String remote = 'origin',
  bool dryRun = false,
}) {
  final key = 'remote.$remote.fetch';
  final existing = git
      .run(['config', '--get-all', key], allowFailure: true)
      .split('\n')
      .where((line) => line.isNotEmpty)
      .toSet();

  final log = <String>[];
  for (final refspec in buildnumberFetchRefspecs) {
    if (existing.contains(refspec)) {
      log.add('already configured: $refspec');
      continue;
    }
    if (!dryRun) {
      git.run(['config', '--add', key, refspec]);
    }
    log.add('${dryRun ? 'would add' : 'added'}: $refspec');
  }
  return log;
}

/// Whether the tag is a tag *object* rather than a ref pointing straight at a
/// commit. Only an annotated tag has a body, and the body is the record.
bool _isAnnotated(Git git, String name) =>
    git.run(['cat-file', '-t', 'refs/tags/$name'], allowFailure: true) == 'tag';
