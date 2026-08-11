// SPDX-License-Identifier: Apache-2.0
//
// Credentials the build reads from the working tree, written there and left.
//
//   cux_ship secrets place
//   cux_ship secrets clean
//
// Everything else in this tool materializes into a temp directory removed
// however the run ends, and `secrets exec` promises exactly that. These cannot:
// `flutter build` and the analyzer read them from fixed paths and a test
// imports one, so they have to exist between commands or the day job breaks.
//
// So the guarantee is a different one, and it is worth stating rather than
// implying. Not *plaintext never outlives the run* — plaintext **never enters
// history**. Everything below exists to make that true even when someone is
// careless: a target that git could ever track is refused, not documented.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'project.dart';

/// What placing one file would do, decided before anything is written.
enum PlaceOutcome {
  /// Nothing there. Write it.
  absent,

  /// Already exactly this. Writing would change nothing.
  matching,

  /// Something else is there. Refuse — it is probably somebody's work.
  differing,
}

/// One placed credential, resolved against the repository.
class PlacedFile {
  PlacedFile({required this.at, required this.path, required this.content});

  /// Where it is declared, for messages: `placed.env_secrets`.
  final String at;

  /// Repository-relative, as written in the file.
  final String path;

  final List<int> content;

  PlaceOutcome outcomeIn(String repoRoot) {
    final file = File(p.join(repoRoot, path));
    if (!file.existsSync()) {
      return PlaceOutcome.absent;
    }
    final existing = file.readAsBytesSync();
    if (existing.length != content.length) {
      return PlaceOutcome.differing;
    }
    for (var i = 0; i < existing.length; i++) {
      if (existing[i] != content[i]) {
        return PlaceOutcome.differing;
      }
    }
    return PlaceOutcome.matching;
  }
}

/// Refuses any path that git could ever track, or that leaves the repository.
///
/// Called before a single byte is written, and again by `clean`, because the
/// repository can change between the two.
void checkPlaceable(String repoRoot, String at, String path) {
  // Syntax first, so nothing below has to reason about a path that was never
  // going to be legal. `..` is refused outright rather than resolved: a path
  // that needs resolving to be judged safe is a path somebody will get wrong.
  if (path.isEmpty ||
      p.isAbsolute(path) ||
      path.startsWith('~') ||
      path.contains('\\') ||
      p.split(path).contains('..')) {
    throw ProjectException(
      '$at.path is $path — it must be inside the repository, written with '
      'forward slashes and no .. segments',
    );
  }

  final target = p.join(repoRoot, path);

  // The deepest ancestor that exists, resolved. A symlink anywhere above the
  // target can leave the repository while every lexical check passes.
  var ancestor = Directory(p.dirname(target));
  while (!ancestor.existsSync() && ancestor.parent.path != ancestor.path) {
    ancestor = ancestor.parent;
  }
  final realAncestor = ancestor.resolveSymbolicLinksSync();
  final realRoot = Directory(repoRoot).resolveSymbolicLinksSync();
  if (!p.isWithin(realRoot, realAncestor) && realAncestor != realRoot) {
    throw ProjectException(
      '$at.path is $path, which resolves outside the repository',
    );
  }

  // The target itself being a symlink means a write would go through it, and a
  // delete would remove the link rather than what it points at. Both are wrong.
  final type = FileSystemEntity.typeSync(target, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw ProjectException('$at.path is $path, which is a symlink');
  }
  if (type == FileSystemEntityType.directory) {
    throw ProjectException('$at.path is $path, which is a directory');
  }

  // Crossing into a submodule: the superproject's ignore rules do not answer
  // for anything inside one, so a file placed there is trackable in a
  // repository this check never consulted.
  for (final part in _ancestorsOf(path)) {
    if (Directory(p.join(repoRoot, part, '.git')).existsSync() ||
        File(p.join(repoRoot, part, '.git')).existsSync()) {
      throw ProjectException(
        '$at.path is $path, which is inside the submodule $part — its ignore '
        'rules are its own, and this cannot answer for them',
      );
    }
  }

  // Tracked beats ignored: .gitignore does not apply to a file git already
  // knows about, so a path once added with `git add -f` stays trackable
  // forever, and the next `git commit -a` publishes the plaintext.
  if (_git(repoRoot, ['ls-files', '--error-unmatch', path]) == 0) {
    throw ProjectException(
      '$at.path is $path, which git already tracks — placing a secret there '
      'would commit it on the next `git commit -a`.\n'
      'Remove it from the index (git rm --cached) and ignore it first.',
    );
  }
  if (_git(repoRoot, ['check-ignore', '-q', path]) != 0) {
    throw ProjectException(
      '$at.path is $path, which is not ignored by git — add it to '
      '.gitignore before a secret goes there',
    );
  }
}

/// Writes [file], atomically and readable only by its owner.
void place(String repoRoot, PlacedFile file) {
  checkPlaceable(repoRoot, file.at, file.path);
  final target = File(p.join(repoRoot, file.path));
  target.parent.createSync(recursive: true);
  // Written beside the target and renamed, so a crash never leaves a partial
  // source file for the analyzer to read.
  final temporary = File('${target.path}.cux-ship-partial');
  temporary.writeAsBytesSync(file.content, flush: true);
  _chmod600(temporary.path);
  temporary.renameSync(target.path);
}

/// Removes [file] only if it is still exactly what was placed.
///
/// Content rather than a receipt: a record of "what this run wrote" is state
/// that drifts, and the question being asked — is this still ours to delete —
/// is answered by looking.
bool clean(String repoRoot, PlacedFile file) {
  final outcome = file.outcomeIn(repoRoot);
  if (outcome == PlaceOutcome.absent) {
    return false;
  }
  if (outcome == PlaceOutcome.differing) {
    throw ProjectException(
      '${file.path} has been edited since it was placed.\n'
      'Keep it with `cux_ship secrets pack`, or discard it with '
      '`cux_ship secrets clean --discard-local`.',
    );
  }
  File(p.join(repoRoot, file.path)).deleteSync();
  return true;
}

Iterable<String> _ancestorsOf(String path) sync* {
  final parts = p.split(p.dirname(path));
  var at = '';
  for (final part in parts) {
    if (part == '.' || part.isEmpty) {
      continue;
    }
    at = at.isEmpty ? part : '$at/$part';
    yield at;
  }
}

int _git(String repoRoot, List<String> arguments) => Process.runSync(
  'git',
  arguments,
  workingDirectory: repoRoot,
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
).exitCode;

void _chmod600(String path) {
  if (Platform.isWindows) {
    return;
  }
  Process.runSync('chmod', ['600', path]);
}
