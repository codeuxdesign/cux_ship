// SPDX-License-Identifier: Apache-2.0
//
// What happens in the repository *after* a release, and exactly once.
//
// Two things, and both are consequences of the release rather than causes of
// one:
//
//   1. The released commit is tagged. The tag triggers nothing; it is a record
//      of what went out.
//   2. The release branch moves to the next patch version, with an empty
//      changelog section for it.
//
// The second is not a convenience. A released version is public, and every
// build after it would otherwise claim a name that is already in front of
// users — which a release build should refuse, so a release would quietly break
// the next push. Doing it here means the state that guard protects against
// never exists.
//
// Always a patch bump, because that is the only choice that cannot be wrong
// before the work exists. Deciding it is really a 1.1.0 is an ordinary commit
// afterwards and needs nothing from here.
//
// **Why this is not part of `appstore promote` or `play promote`.** Those are
// per-store; this is per-release. One commit gets one build number, both stores
// promote that same build, and the version they publish is the same one — which
// only holds if promotion cannot move it. Folding the bump into a store command
// would mean a two-store release ran it twice, and the only thing standing
// between that and two different published versions would be a guard nobody
// reads. Here it is structurally once.
//
// Every step is idempotent anyway, because a release is exactly the situation
// where something fails half way and gets run again: an existing tag is left
// alone, and a branch already past the released version is not bumped.
import 'dart:io';

import 'package:pub_semver/pub_semver.dart';

import 'config.dart' show TagKindConfig, defaultReleaseTagFormat;

/// Something wrong that the caller should report rather than a bug.
class ReleaseException implements Exception {
  ReleaseException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The `x.y.z` at the start of a pubspec `version:` line, ignoring any `+build`.
///
/// Returns null when there is no version line at all, which a caller may treat
/// as "not a pubspec" rather than an error.
///
/// **A [Version] rather than the string that was matched**, so a caller
/// comparing it against something compares versions and not text. The regex
/// stays because it is doing the *extraction* — finding the line and dropping
/// the `+build` a pubspec is allowed to carry — and only what it extracted is
/// handed to the parser. Its three capture groups are numeric by construction,
/// so the parse cannot fail on anything the match accepted.
Version? pubspecVersion(String pubspec) {
  final matched = RegExp(
    r'^version:\s*(\d+\.\d+\.\d+)',
    multiLine: true,
  ).firstMatch(pubspec)?.group(1);
  return matched == null ? null : Version.parse(matched);
}

/// Where `pubspec.yaml` sits relative to the repository root, for an app in
/// [appDir].
///
/// Repository-relative rather than absolute because every use of it is a git
/// argument — `git show REV:PATH`, `git status -- PATH`, `git commit PATH` —
/// and git takes none of those as an absolute path. The one caller that opens
/// the file joins it onto the root itself.
String pubspecPathFor(String appDir) =>
    appDir.isEmpty ? 'pubspec.yaml' : '$appDir/pubspec.yaml';

/// The `+build` suffix on a pubspec `version:` line, if there is one.
String? pubspecBuildSuffix(String pubspec) => RegExp(
  r'^version:\s*\d+\.\d+\.\d+(\+\S+)',
  multiLine: true,
).firstMatch(pubspec)?.group(1);

/// [version] as a [Version] this tool is willing to bump, or a [ReleaseException]
/// saying why not.
///
/// **Two questions the old regex answered as one.** `^(\d+)\.(\d+)\.(\d+)$` both
/// parsed and enforced a policy, so "is this a version" and "is this a version
/// we will bump" were the same match — and the second is deliberately stricter
/// than the first. `1.0.3-beta` and `1.0.3+41` are perfectly good semver; they
/// are refused here because a pre-release or a build-metadata version has no
/// obviously correct patch bump, and guessing one during a release is worse
/// than stopping.
///
/// Stating that as a check on `isPreRelease` and `build` rather than as a
/// pattern that happens to exclude them means the reason survives in the code.
/// It also means the *parse* is the library's, which matters for the ordering
/// this type brings with it: `1.0.10` sorts above `1.0.9`, and build metadata
/// is excluded from precedence — the rule the `vX.Y.Z+<build>` tag scheme rests
/// on, held by something that implements semver rather than by a comment.
Version parseBumpableVersion(String version) {
  final Version parsed;
  try {
    parsed = Version.parse(version);
  } on FormatException {
    throw ReleaseException(
      'cannot bump "$version" — it is not a version number. Edit the version '
      'by hand and pass --no-bump',
    );
  }
  if (parsed.isPreRelease || parsed.build.isNotEmpty) {
    throw ReleaseException(
      'cannot bump the patch level of "$version" — a '
      '${parsed.isPreRelease ? 'pre-release' : 'build-metadata'} version has no '
      'obviously correct next patch. Edit the version by hand and pass '
      '--no-bump',
    );
  }
  return parsed;
}

/// The next patch version after [version].
///
/// `Version.nextPatch` rather than arithmetic on captured groups — same answer,
/// and it is the package's job to know that the next patch of a release version
/// is not the same question as the next patch of a pre-release.
Version nextPatchVersion(String version) =>
    parseBumpableVersion(version).nextPatch;

/// Rewrites the `version:` line of [pubspec] to [next], keeping any `+build`.
///
/// The `+N` is carried across untouched: it is the build number, which a build
/// script overrides per build, so its value here has never mattered — but
/// rewriting it would look like it did.
///
/// Throws rather than returning the input unchanged. The whole point of the
/// bump is that the version *changes*; a pattern that quietly stopped matching
/// would leave the file alone, report success, and hand the branch a version
/// that is already public — which is the exact failure this exists to prevent.
String bumpPubspecVersion(String pubspec, Version next) {
  final pattern = RegExp(r'^version:.*$', multiLine: true);
  if (!pattern.hasMatch(pubspec)) {
    throw ReleaseException('no version: line in pubspec.yaml');
  }
  final suffix = pubspecBuildSuffix(pubspec) ?? '';
  var replaced = false;
  final result = pubspec.replaceFirstMapped(pattern, (_) {
    replaced = true;
    return 'version: $next$suffix';
  });
  if (!replaced || !result.contains('version: $next$suffix')) {
    throw ReleaseException(
      'rewriting the version in pubspec.yaml did not take',
    );
  }
  return result;
}

/// Inserts an empty `## <version>` section above the newest existing one.
///
/// Empty because nothing has happened in it yet — and an empty section is a
/// real answer that publishes a "nothing you can see changed" note, not a
/// placeholder somebody has to remember to fill in.
String insertChangelogSection(String changelog, Version version) {
  final heading = RegExp(r'^##\s+\d', multiLine: true);
  final match = heading.firstMatch(changelog);
  if (match == null) {
    throw ReleaseException(
      'CHANGELOG.md has no version sections to insert above',
    );
  }
  final result =
      '${changelog.substring(0, match.start)}'
      '## $version\n\n'
      '${changelog.substring(match.start)}';
  if (!RegExp(
    '^## ${RegExp.escape('$version')}\$',
    multiLine: true,
  ).hasMatch(result)) {
    throw ReleaseException('inserting the $version section did not take');
  }
  return result;
}

/// Runs git, and treats a non-zero exit as fatal unless [allowFailure].
class Git {
  Git(this.root);

  final String root;

  String run(List<String> args, {bool allowFailure = false}) {
    final result = Process.runSync('git', args, workingDirectory: root);
    if (result.exitCode != 0 && !allowFailure) {
      throw ReleaseException(
        'git ${args.join(' ')} failed:\n${result.stderr}'.trimRight(),
      );
    }
    return (result.stdout as String).trim();
  }

  bool ok(List<String> args) =>
      Process.runSync('git', args, workingDirectory: root).exitCode == 0;
}

/// What [finishRelease] should do, and to what.
class FinishOptions {
  const FinishOptions({
    required this.commit,
    required this.version,
    this.buildNumber,
    this.appDir = '',
    this.destination = 'production',
    this.branch = 'main',
    this.tag = true,
    this.releaseTag = const TagKindConfig(
      enabled: true,
      format: defaultReleaseTagFormat,
    ),
    this.bump = true,
    this.push = true,
    this.dryRun = false,
  });

  /// The commit that was released — what gets tagged.
  final String commit;

  /// Where the Flutter app lives relative to the repository root, so
  /// `pubspec.yaml` can be found in a monorepo. Empty when the app *is* the
  /// repository, which is the ordinary case.
  ///
  /// `CHANGELOG.md` is deliberately not moved by this: the changelog describes
  /// what the repository shipped, and most of what a user notices usually
  /// changed in some package other than the app.
  final String appDir;

  /// The marketing version that was released.
  /// The version that was published.
  ///
  /// A [Version] rather than a string, so `current != options.version` compares
  /// versions and the tag name is rendered from a parsed value rather than
  /// echoed from an argument.
  final Version version;

  /// Only used in messages, so a tag says which build it was.
  final String? buildNumber;

  /// How the tag is named, and whether it is written at all.
  ///
  /// **`tag: false` overrides `releaseTag.enabled: true`, and the log says
  /// which won.** A flag and a config key answering the same question is how a
  /// repository ends up with a setting that appears to do nothing — so one
  /// wins, it is the one typed at the call site, and the reason is printed
  /// rather than inferred.
  final TagKindConfig releaseTag;

  /// Where it went, for the tag and commit messages.
  final String destination;

  /// The branch the bump commit belongs on.
  final String branch;

  final bool tag;
  final bool bump;
  final bool push;
  final bool dryRun;
}

/// Tags [FinishOptions.commit] and moves [FinishOptions.branch] to the next
/// patch version.
///
/// Returns the lines to report. Does the checks that can be done without
/// touching anything first, so "you are on the wrong branch" costs nothing.
List<String> finishRelease(Git git, FinishOptions options) {
  final log = <String>[];
  final pubspecPath = pubspecPathFor(options.appDir);

  // Checked up front, both of them, because a half-finished release is worse
  // than one that refused to start.
  if (options.bump) {
    final branch = git.run(['rev-parse', '--abbrev-ref', 'HEAD']);
    if (branch != options.branch) {
      throw ReleaseException(
        'the bump commit belongs on ${options.branch}, and this is "$branch" '
        '— switch, or pass --no-bump',
      );
    }
    // Only these two paths are committed, and only if nothing else has already
    // touched them: `git commit <paths>` takes the working tree's version of a
    // path, so an unrelated edit sitting in either would be swept into the
    // release commit. The rest of the tree is deliberately not required to be
    // clean — that is not this command's business.
    for (final file in [pubspecPath, 'CHANGELOG.md']) {
      final dirty = git.run(['status', '--porcelain', '--', file]);
      if (dirty.isNotEmpty) {
        throw ReleaseException(
          '$file has uncommitted changes, and the bump commit would carry '
          'them — commit or stash it first',
        );
      }
    }
  }

  final hasOrigin = git.ok(['remote', 'get-url', 'origin']);

  // ------------------------------------------------------------------ the tag

  // Config decides, the flag overrides, and a skip says which asked for it —
  // "nothing happened" must never be the same output as "nothing was asked".
  final wantsTag = options.tag && options.releaseTag.enabled;
  if (!wantsTag) {
    log.add(
      options.tag
          ? 'not tagging: tag.release.enabled is false'
          : 'not tagging: --no-tag',
    );
  }
  if (wantsTag) {
    // **Named here rather than at the top of the function, because naming can
    // refuse.** A format carrying `{build}` is legal, and a run with no build
    // number cannot fill it — so computing the name up front made `--no-tag`
    // and `tag.release.enabled: false` fail over a tag they had just decided
    // not to write. Was `v` plus the version, hardcoded; `tag.release.format`
    // is the source now, so a repository whose releases are named `rel/1.2.3`
    // stops needing a fork.
    final tagName = options.releaseTag.nameFor(
      version: options.version.toString(),
      build: options.buildNumber,
    );
    // **Existence is not the question — where it points is.** Leaving an
    // existing tag alone is right when it already names this release, and is
    // how a half-finished run is safely repeated. It is wrong when the name
    // names a *different* commit: that is one version recorded against two
    // commits, and carrying on would leave whichever is wrong standing as the
    // record of what shipped.
    final commit = resolveCommit(git, options.commit);
    final tagged = taggedCommit(git, tagName);
    if (tagged != null && tagged != commit) {
      throw ReleaseException(
        'Tag $tagName already names a different commit.\n'
        '  it points at:  $tagged\n'
        '  this release:  $commit\n'
        'Retag deliberately or pick another version; nothing was changed.',
      );
    }
    if (tagged != null) {
      log.add('$tagName already exists at ${_short(tagged)}');
    } else if (options.dryRun) {
      log.add('would tag $tagName at ${_short(commit)}');
    } else {
      final build = options.buildNumber == null
          ? ''
          : ' (${options.buildNumber})';
      git.run([
        'tag',
        '-a',
        tagName,
        commit,
        '-m',
        '${options.version}$build released to ${options.destination}',
      ]);
      log.add('tagged $tagName');
    }
    // **Outside the branch above, because the tag existing locally says nothing
    // about the remote having it.** The previous shape pushed only on the run
    // that created the tag, so a run whose push failed left a tag that no later
    // run would ever try again: every repeat found it locally, reported
    // "leaving it alone", and finished green while the remote stayed without
    // it.
    //
    // **A rejected push is not a collision**, and the sentence that used to be
    // here said it was — that pushing a tag the remote already holds at this
    // commit is a no-op. True for lightweight tags and byte-identical objects;
    // false for the case that happens. A clone without the tag locally mints
    // its own annotated object, with this run's timestamp and message, and git
    // refuses to replace origin's with it. The rejection reads
    // `! [rejected] ... (already exists)`.
    //
    // Read as a failure it was worse than a wrong error: the tag now existed
    // locally, so every retry took the "already exists" branch, pushed, was
    // rejected again, and failed again — stuck until somebody deleted the local
    // tag, which nothing said to do.
    //
    // So origin is asked what its tag actually names. This also delivers what
    // the old comment only claimed: a genuine cross-machine collision now gets
    // the collision message and its exit code, rather than raw git output.
    if (options.push && hasOrigin && !options.dryRun) {
      if (git.ok(['push', 'origin', 'refs/tags/$tagName'])) {
        log.add('pushed $tagName');
      } else {
        final remote = remoteTaggedCommit(git, tagName);
        if (remote == null) {
          // Rejected, and origin does not hold this tag — the push failed for
          // some other reason. Re-run it without `ok` so git's own message
          // reaches the operator rather than one invented here.
          git.run(['push', 'origin', 'refs/tags/$tagName']);
          log.add('pushed $tagName');
        } else if (remote != commit) {
          throw ReleaseException(
            'Tag $tagName already names a different commit on origin.\n'
            '  origin points at:  $remote\n'
            '  this release:      $commit\n'
            'One version recorded against two commits. Retag deliberately or '
            'pick another version; nothing was changed.',
          );
        } else {
          log.add('$tagName already on origin at ${_short(commit)}');
        }
      }
    }
  }

  // ----------------------------------------------------------------- the bump

  if (!options.bump) {
    return log;
  }

  final pubspecFile = File('${git.root}/$pubspecPath');
  if (!pubspecFile.existsSync()) {
    throw ReleaseException('no $pubspecPath in ${git.root}');
  }
  final pubspec = pubspecFile.readAsStringSync();
  final current = pubspecVersion(pubspec);

  if (current != options.version) {
    // Somebody bumped by hand, or an older build than the branch is on was
    // released. Either way the branch is already past the released version,
    // which is all this cares about — and it is what makes running this twice
    // for a two-store release harmless.
    log.add('$pubspecPath is already past ${options.version} — not bumping');
    return log;
  }

  final next = nextPatchVersion('${options.version}');
  final changelogFile = File('${git.root}/CHANGELOG.md');
  if (!changelogFile.existsSync()) {
    throw ReleaseException('no CHANGELOG.md in ${git.root}');
  }

  if (options.dryRun) {
    // Still computed rather than announced blind, so a changelog that would
    // fail to take says so during the rehearsal.
    bumpPubspecVersion(pubspec, next);
    insertChangelogSection(changelogFile.readAsStringSync(), next);
    log.add('would bump $pubspecPath to $next and add its changelog section');
    return log;
  }

  pubspecFile.writeAsStringSync(bumpPubspecVersion(pubspec, next));
  changelogFile.writeAsStringSync(
    insertChangelogSection(changelogFile.readAsStringSync(), next),
  );

  git.run([
    'commit',
    '-q',
    pubspecPath,
    'CHANGELOG.md',
    '-m',
    'Move ${options.branch} to $next, now that ${options.version} is on '
        '${options.destination}',
  ]);
  log.add('bumped to $next');

  if (options.push && hasOrigin) {
    // Not fatal. The release happened; a rejected push means the branch moved
    // underneath, and that is a rebase rather than an emergency — but it has to
    // be loud, because until it lands the branch is still on the public
    // version.
    if (git.ok(['push', 'origin', options.branch])) {
      log.add('pushed the bump to ${options.branch}');
    } else {
      log.add(
        'WARNING: could not push the bump — ${options.branch} is still on '
        '${options.version} until you do',
      );
    }
  }

  return log;
}

String _short(String sha) => sha.length > 8 ? sha.substring(0, 8) : sha;

/// The commit `release finish` tags, and one line saying where it came from.
typedef ReleasedCommit = ({String commit, String how});

/// Which commit was released, when the caller did or did not say.
///
/// [commit] wins outright when given: it is the manifest's `gitSha` handed
/// over by a script that already knows, and no tag is consulted. Otherwise,
/// with a [buildNumber] and [uploadTag] recording enabled, the upload record
/// is asked — `uploaded/v{version}+{build}` is this tool's own tag naming the
/// commit the artifact was built from, so with the version globbed and the
/// build fixed there is at most one honest answer. This used to be refused as
/// the project's business, because *allocating* a build number is; but
/// reading a record this tool wrote is not, and until now the record was
/// written on upload and ignored on finish, leaving every consumer to
/// dereference the tag by hand or default to HEAD — which during a promotion
/// is very often not the promoted commit.
///
/// Exactly one match resolves. None is refused, naming `--commit`: with
/// recording on, every upload since it was switched on carries a record, so no
/// match means a wrong number or a build from before recording, and HEAD is
/// the least likely answer to either — a first draft fell back to it and said
/// so, and review measured that on a real repository as "tagging HEAD" several
/// commits past anything that was built, followed by doing it. More than one
/// is refused naming them: one build number on two commits is the collision
/// the record exists to make visible, not something to pick from. HEAD stays
/// the default only when nothing asked for a lookup — no build number, or
/// recording off.
ReleasedCommit resolveReleasedCommit(
  Git git, {
  required String? commit,
  required String? buildNumber,
  required TagKindConfig uploadTag,
}) {
  if (commit != null) {
    // Shortened only when it is a sha: `HEAD` or a branch name is shown as
    // typed, and the other lines here print eight characters.
    final shown = RegExp(r'^[0-9a-fA-F]{9,}$').hasMatch(commit)
        ? _short(commit)
        : commit;
    return (commit: commit, how: 'tagging $shown, from --commit');
  }
  if (buildNumber == null || !uploadTag.enabled) {
    final head = git.run(['rev-parse', 'HEAD']);
    return (commit: head, how: 'tagging HEAD, ${_short(head)}');
  }
  // The version is the unknown: a glob for it, and the build number literal,
  // is the format with its two holes filled the two different ways.
  final pattern = uploadTag.format
      .replaceAll('{version}', '*')
      .replaceAll('{build}', buildNumber);
  final matches = git
      .run(['tag', '--list', pattern])
      .split('\n')
      .where((line) => line.isNotEmpty)
      .toList();
  if (matches.isEmpty) {
    throw ReleaseException(
      'no upload record matches $pattern, so build $buildNumber cannot be '
      'placed. Recording is on, so either the number is wrong or the build '
      'went up before recording was — pass --commit to say which commit '
      'was released. Nothing was tagged.',
    );
  }
  if (matches.length > 1) {
    throw ReleaseException(
      'build $buildNumber has more than one upload record:\n'
      '${matches.map((m) => '  $m').join('\n')}\n'
      'One build number on more than one version is what the record exists '
      'to catch. Pass --commit to say which was released.',
    );
  }
  final tag = matches.single;
  // `^{commit}` because the record is an annotated tag, whose own id is not a
  // commit — the same reason taggedCommit dereferences.
  final recorded = git.run(['rev-parse', 'refs/tags/$tag^{commit}']);
  return (
    commit: recorded,
    how: 'build $buildNumber was uploaded from ${_short(recorded)}, by $tag',
  );
}

/// The commit a tag resolves to, or null when the tag is absent.
///
/// `^{commit}` because these are annotated tags: plain `rev-parse <tag>` yields
/// the tag object, which never equals a commit SHA and would report every
/// re-run as a collision with itself.
String? taggedCommit(Git git, String name) {
  if (!git.ok(['rev-parse', '--verify', '--quiet', 'refs/tags/$name'])) {
    return null;
  }
  return git.run(['rev-parse', 'refs/tags/$name^{commit}']);
}

/// The commit origin's copy of [name] points at, or null if it has no such tag.
///
/// The remote counterpart of [taggedCommit], and deliberately beside it: the
/// local answer alone is what let a clone without the tag mint its own and be
/// refused by a remote that already had one.
///
/// **`^{}` is load-bearing.** Without it `ls-remote` answers with the *tag
/// object* id, and two clones that tagged the same commit have two different
/// tag objects — so comparing those would report a collision on every parallel
/// run and never on a real one. One network call, no fetch.
String? remoteTaggedCommit(Git git, String name) {
  final line = git.run([
    'ls-remote',
    'origin',
    'refs/tags/$name^{}',
  ], allowFailure: true);
  if (line.isEmpty) {
    return null;
  }
  return line.split(RegExp(r'\s+')).first;
}

/// [spec] as the full 40-character SHA of a commit that exists here.
///
/// **Every comparison against a tag has to go through this**, because the other
/// side of that comparison is `rev-parse` output and is therefore always full
/// and always lowercase. Compare it against what a caller happened to pass —
/// `HEAD`, a short SHA, a branch name, a SHA some tool upper-cased — and the
/// first run succeeds while the legitimate repeat is accused of naming a second
/// commit. That accusation is the loudest error either of these functions can
/// raise, and it would be false.
///
/// It also converts the absent-commit case from git's `fatal: bad object type.`
/// into something that says which commit and where to look. A commit missing
/// from the checkout is the ordinary consequence of a shallow clone or of an
/// upload job triggered separately from the build that produced the artifact.
String resolveCommit(Git git, String spec) {
  final result = git.run([
    'rev-parse',
    '--verify',
    '--quiet',
    '$spec^{commit}',
  ], allowFailure: true);
  if (result.isEmpty) {
    throw ReleaseException(
      '"$spec" does not name a commit in ${git.root}.\n'
      'If this is a shallow or partial clone, or a job that did not check out '
      'the branch the artifact was built from, the commit is simply not here '
      'yet — deepen the clone rather than picking a different commit.',
    );
  }
  return result;
}
