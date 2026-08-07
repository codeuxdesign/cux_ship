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
String? pubspecVersion(String pubspec) => RegExp(
  r'^version:\s*(\d+\.\d+\.\d+)',
  multiLine: true,
).firstMatch(pubspec)?.group(1);

/// The `+build` suffix on a pubspec `version:` line, if there is one.
String? pubspecBuildSuffix(String pubspec) => RegExp(
  r'^version:\s*\d+\.\d+\.\d+(\+\S+)',
  multiLine: true,
).firstMatch(pubspec)?.group(1);

/// The next patch version after [version].
///
/// Refuses anything that is not three numeric components. A pre-release or
/// build-metadata version has no obviously correct patch bump, and guessing one
/// during a release is worse than stopping.
String nextPatchVersion(String version) {
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(version);
  if (match == null) {
    throw ReleaseException(
      'cannot bump the patch level of "$version" — edit the version by hand '
      'and pass --no-bump',
    );
  }
  final patch = int.parse(match.group(3)!) + 1;
  return '${match.group(1)}.${match.group(2)}.$patch';
}

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
String bumpPubspecVersion(String pubspec, String next) {
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
String insertChangelogSection(String changelog, String version) {
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
    '^## ${RegExp.escape(version)}\$',
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
    this.destination = 'production',
    this.branch = 'main',
    this.tag = true,
    this.bump = true,
    this.push = true,
    this.dryRun = false,
  });

  /// The commit that was released — what gets tagged.
  final String commit;

  /// The marketing version that was released.
  final String version;

  /// Only used in messages, so a tag says which build it was.
  final String? buildNumber;

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
  final tagName = 'v${options.version}';

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
    for (final file in const ['pubspec.yaml', 'CHANGELOG.md']) {
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

  if (options.tag) {
    if (git.run(['tag', '-l', tagName]).isNotEmpty) {
      log.add('$tagName already exists — leaving it alone');
    } else if (options.dryRun) {
      log.add('would tag $tagName at ${_short(options.commit)}');
    } else {
      final build = options.buildNumber == null
          ? ''
          : ' (${options.buildNumber})';
      git.run([
        'tag',
        '-a',
        tagName,
        options.commit,
        '-m',
        '${options.version}$build released to ${options.destination}',
      ]);
      log.add('tagged $tagName');
      if (options.push && hasOrigin) {
        git.run(['push', 'origin', tagName]);
        log.add('pushed $tagName');
      }
    }
  }

  // ----------------------------------------------------------------- the bump

  if (!options.bump) {
    return log;
  }

  final pubspecFile = File('${git.root}/pubspec.yaml');
  if (!pubspecFile.existsSync()) {
    throw ReleaseException('no pubspec.yaml in ${git.root}');
  }
  final pubspec = pubspecFile.readAsStringSync();
  final current = pubspecVersion(pubspec);

  if (current != options.version) {
    // Somebody bumped by hand, or an older build than the branch is on was
    // released. Either way the branch is already past the released version,
    // which is all this cares about — and it is what makes running this twice
    // for a two-store release harmless.
    log.add('pubspec.yaml is already past ${options.version} — not bumping');
    return log;
  }

  final next = nextPatchVersion(options.version);
  final changelogFile = File('${git.root}/CHANGELOG.md');
  if (!changelogFile.existsSync()) {
    throw ReleaseException('no CHANGELOG.md in ${git.root}');
  }

  if (options.dryRun) {
    // Still computed rather than announced blind, so a changelog that would
    // fail to take says so during the rehearsal.
    bumpPubspecVersion(pubspec, next);
    insertChangelogSection(changelogFile.readAsStringSync(), next);
    log.add('would bump pubspec.yaml to $next and add its changelog section');
    return log;
  }

  pubspecFile.writeAsStringSync(bumpPubspecVersion(pubspec, next));
  changelogFile.writeAsStringSync(
    insertChangelogSection(changelogFile.readAsStringSync(), next),
  );

  git.run([
    'commit',
    '-q',
    'pubspec.yaml',
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
