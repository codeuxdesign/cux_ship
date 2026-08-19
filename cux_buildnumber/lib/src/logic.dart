/// The counter arithmetic, the retry decisions and the on-disk content
/// builders — pure functions with no process calls, ported from
/// git-buildnumber.sh v1.3.
library;

/// The next number a plain allocation takes. `counter` is what
/// `refs/buildnumbers/last` holds, or null when the ref does not exist yet.
int nextBuildNumber(int? counter) => (counter ?? 0) + 1;

/// The number `force-incr` writes.
///
/// **The next number comes from the counter, never from HEAD's own note.**
/// Those differ whenever anything else has allocated since: with HEAD on 1 and
/// the counter on 3, counting from the note yields 2 — a number another commit
/// already owns — and publishing it rolls the shared counter backwards, so the
/// following allocation hands out 3 a second time. The lease does not catch
/// it, because nothing else moved.
///
/// [current] is the number HEAD already carries (allocating one first if it
/// had none); [counter] is the shared counter, or null when unreadable.
int forceIncrNext({required int? counter, required int current}) {
  var last = counter ?? current;
  if (last < current) {
    last = current;
  }
  return last + 1;
}

/// **Only the first attempt may trust a local note.** On a retry the local
/// note is the one just written for the number that lost the race, and
/// returning it hands back a number another commit already owns — which was
/// the whole failure the retry exists to recover from.
bool mayTrustLocalNote(int attempt) => attempt == 1;

/// Bounded attempts: unbounded, a remote that keeps refusing burned a number
/// per attempt and never stopped.
bool shouldRetryAfterLostPush({
  required int attempt,
  required int maxAttempts,
}) => attempt < maxAttempts;

/// The content of the `refs/buildnumbers/last` blob.
///
/// **The trailing newline is part of the hash.** The shell writes the counter
/// with `echo`, which appends one, and a port writing the bare number produces
/// a different blob and therefore a different ref.
String counterBlobContent(String number) => '$number\n';

/// The blob hash of the entry named [entryName] in `git ls-tree` output, or
/// null when the tree has no such entry. Lines look like
/// `100644 blob <hash>\t<name>`.
String? lsTreeEntryHash(String lsTree, String entryName) {
  for (final line in lsTree.split('\n')) {
    if (line.endsWith('\t$entryName')) {
      final fields = line.split('\t').first.split(' ');
      if (fields.length >= 3) {
        return fields[2];
      }
    }
  }
  return null;
}

/// The `git mktree` input for a chain entry's tree: the existing entries with
/// any previous entry of the same name filtered out, then the new entry.
///
/// The filter matters only when a number is rewritten (`force`, `force-incr`):
/// leaving the old entry in place makes `mktree` write a tree with two entries
/// of the same name, which is invalid to `git fsck`.
String chainTreeInput({
  required String existingLsTree,
  required String entryName,
  required String blobHash,
}) {
  final kept = existingLsTree
      .split('\n')
      .where((line) => line.isNotEmpty && !line.endsWith('\t$entryName'))
      .toList();
  final lines = [...kept, '100644 blob $blobHash\t$entryName'];
  return lines.map((line) => '$line\n').join();
}

/// The content of a chain entry's `b<n>` blob: any previous content for the
/// same number (a rewrite keeps the history of who held it), then the built
/// commit's SHA with a trailing newline.
List<int> chainBlobContent({
  required List<int> previous,
  required String headSha,
}) => [...previous, ...'$headSha\n'.codeUnits];

/// `uniq` over lines: adjacent duplicates collapse, trailing newlines are
/// stripped. Used only for the `find-commit` INFO line on stderr.
String uniqueAdjacentLines(String text) {
  var trimmed = text;
  while (trimmed.endsWith('\n')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  final out = <String>[];
  for (final line in trimmed.split('\n')) {
    if (out.isEmpty || out.last != line) {
      out.add(line);
    }
  }
  return out.join('\n');
}
