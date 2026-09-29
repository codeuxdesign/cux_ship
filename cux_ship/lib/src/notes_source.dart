// SPDX-License-Identifier: Apache-2.0
//
// Release notes must come from committed text.
//
// **The defect this exists for.** Both stores' uploaders take a path to a
// changelog and read whatever is on disk — so a half-written sentence, a
// paragraph somebody was still editing, or an unreviewed edit made to get a
// release out goes to real users. In one consuming repository the script doing
// it carried a header stating that *"the working tree is not consulted at
// all"*, which had been true of everything else it did.
//
// **Refusing a dirty file is the whole fix, and reading from `HEAD` instead
// would be over-specification.** The two are byte-identical whenever the file
// is clean, and the refusal makes the dirty case unreachable — so there is no
// second mechanism to keep in step, and no `git show` plumbing to get wrong.
//
// **Scoped to the files the notes were resolved from**, rather than to a
// filename. This repository's notes come from `CHANGELOG.md`; another's come
// from per-locale `changelogs/<versionCode>.txt` and a cross-store CSV, 23
// locales of them. Naming the file in the rule would mean rewriting the rule
// the day the second shape arrives.
//
// **It has.** `CHANGELOG.<locale>.md` beside the changelog is that locale's
// notes (see `locale_notes.dart`), so one release now reads several files, and
// every one of them is handed here. The refusal names the resolved path, which
// carries the locale — with 23 files, "uncommitted changes in the release
// notes" would not say which.
//
// **A link to nothing is refused, not skipped.** An absent file is skipped
// because there is nothing to be dirty; under the locale convention an absent
// file also means "publish the default", and `File.existsSync` answers false
// for a dangling symlink. Skipping it would let a translation somebody linked
// in be replaced by the English notes with no word said.
//
// **No override.** Committing costs seconds, and an escape hatch here reopens
// the exact hole — the reason someone reaches for it is always that they are in
// a hurry, which is when unreviewed text ships.
import 'dart:io';

import 'release.dart' show Git, ReleaseException;

/// Refuses when any file the notes were resolved from has uncommitted changes.
///
/// A path outside a git repository is not an error: a `dist/` published from a
/// tarball on a machine with no checkout has no working tree to be dirty, and
/// the notes there came from wherever the tarball did.
///
/// [what] names the text in the refusal — the rule covers everything published
/// to testers or shoppers, not only release notes, and the beta app
/// description takes the same guard for the same reason.
void requireCommittedNotes(
  Iterable<String> paths, {
  String what = 'release notes',
}) {
  for (final path in paths) {
    final file = File(path);
    if (!file.existsSync()) {
      if (FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw ReleaseException(
          '$what would come from $path, which is a symlink to nothing.\n'
          'Point it at the file it was meant to name, or delete it.',
        );
      }
      continue;
    }
    // Through the symlink, not at it. `git status -- <link>` answers for the
    // link object, which stays clean while the file it points at is mid-edit
    // — and the link's parent decides which repository gets asked, which for
    // a link into another checkout is the wrong one. One consuming repository
    // keeps CHANGELOG.md as a root symlink into its package directory, and an
    // uncommitted section walked straight past this guard through it.
    final resolved = File(file.resolveSymbolicLinksSync());
    final directory = resolved.parent.absolute.path;
    final git = Git(directory);
    if (!git.ok(['rev-parse', '--is-inside-work-tree'])) {
      continue;
    }
    final status = git.run([
      'status',
      '--porcelain',
      '--',
      resolved.path,
    ], allowFailure: true);
    if (status.isNotEmpty) {
      // The resolved path is the one to commit, so a refusal through a link
      // names it — naming only the link would send somebody to `git add` a
      // file whose object has not changed.
      final via = resolved.path == file.absolute.path
          ? ''
          : ' (reached through $path)';
      throw ReleaseException(
        '$what would come from uncommitted changes in '
        '${resolved.path}$via.\n'
        'Commit it first. What reaches a store should have been reviewed, and '
        'a working tree is the one copy nobody else has seen.',
      );
    }
  }
}
