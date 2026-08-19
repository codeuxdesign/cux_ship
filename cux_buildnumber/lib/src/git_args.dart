/// The git argument lists, as pure functions.
///
/// This file is the point of the port. The worst bug in the tool's history was
/// a property of an argv — a `+` on a refspec sitting beside
/// `--force-with-lease`, which overrides the lease — and no black-box run
/// reveals that until two runs race. Building each argument list here, as data
/// a unit test can read, is what makes that class of bug testable at all.
library;

const refsBase = 'refs/buildnumbers';
const refsLast = '$refsBase/last';
const refsCommits = '$refsBase/commits';
const refsNotes = 'refs/notes/buildnumbers';

/// What the last observation of the push remote saw, per ref.
///
/// `null` means the remote did not have the ref — the legitimate first-run
/// state, not a conflict — and such a ref gets no lease: there is nothing to
/// compare against, and its creation is the first-run case.
typedef ObservedRefs = ({String? last, String? commits, String? notes});

const ObservedRefs noObservedRefs = (last: null, commits: null, notes: null);

/// Scoped to our own notes ref on purpose. `+refs/notes/*:refs/notes/*`
/// force-fetches and force-pushes *every* notes ref, so a stale clone silently
/// rolls back notes it knows nothing about — refs/notes/commits used for
/// review comments, for example.
///
/// Kept as a glob rather than the exact ref because a plain refspec is fatal
/// when the ref does not exist yet: "couldn't find remote ref" on fetch, "src
/// refspec does not match any" on push. That is every first run.
///
/// **Fetch and push need different refspecs, and sharing one is what made the
/// shell version's retry unreachable.** The leading `+` is per-ref `--force`.
/// On the fetch that is wanted: the remote is the authority, and a local ref
/// that has drifted should be overwritten. On the push it means a diverged
/// remote is *overwritten rather than refused*, so `git push` cannot fail, so
/// the recovery paths could never run. Two clones allocating the same number
/// would both "succeed", and the second would erase the first's note.
///
/// Note `--force-with-lease` alone does not fix it: a `+` on the refspec
/// overrides the lease. Measured — with `+`, a push carrying a stale lease
/// value still reports "(forced update)".
const fetchRefspecs = ['+$refsBase/*:$refsBase/*', '+$refsNotes*:$refsNotes*'];

/// No `+` anywhere. See [fetchRefspecs] for why that is load-bearing.
const pushRefspecs = ['$refsBase/*:$refsBase/*', '$refsNotes*:$refsNotes*'];

/// `--depth=1` only when the clone is already shallow. Each chain entry
/// carries the built commit as a parent, so the ref's fetch closure is the
/// union of every built commit's ancestry — depth-limiting the chain avoids
/// paying that on every fresh CI runner, and appending to a shallow chain
/// still works because the remote already has both parents.
///
/// Never unconditionally: passing --depth to a full clone would introduce a
/// shallow boundary into a repository that did not have one.
List<String> fetchArgs({required String remote, required bool shallow}) => [
  'fetch',
  '-q',
  if (shallow) ...['--depth=1'],
  remote,
  ...fetchRefspecs,
];

/// What the push remote currently holds, read in one call for all our refs.
List<String> lsRemoteArgs({required String remote}) => [
  'ls-remote',
  remote,
  '$refsBase/*',
  '$refsNotes*',
];

/// `--force-with-lease=<ref>:<value>` for every ref a value was observed for.
///
/// Fast-forward is not available here: [refsLast] points at a *blob*, which
/// has no ancestry, so every update of it is a non-fast-forward and a plain
/// push would refuse even a healthy single-machine run. A lease is the check
/// that works — provided nothing in the argv overrides it.
List<String> leaseArgs(ObservedRefs observed) => [
  if (observed.last != null) ...[
    '--force-with-lease=$refsLast:${observed.last}',
  ],
  if (observed.commits != null) ...[
    '--force-with-lease=$refsCommits:${observed.commits}',
  ],
  if (observed.notes != null) ...[
    '--force-with-lease=$refsNotes:${observed.notes}',
  ],
];

/// `--atomic` so a rejected lease on one ref cannot leave the others landed.
/// Without it a partial push publishes a counter without its note, or a note
/// without its chain entry, and the retry then has to reason about halves.
List<String> pushArgs({
  required String remote,
  required ObservedRefs observed,
}) => [
  'push',
  '-q',
  '--atomic',
  remote,
  ...leaseArgs(observed),
  ...pushRefspecs,
];

/// The clean-tree check. [rawArgs] is the `DIFF_INDEX_ARGS` environment value,
/// word-split the way the shell would — it defaults to `--ignore-space-at-eol`,
/// and a port defaulting to a strict `diff-index` refuses trees the shell
/// accepts.
List<String> diffIndexArgs(String rawArgs) => [
  'diff-index',
  '--quiet',
  ...rawArgs.split(RegExp(r'\s+')).where((arg) => arg.isNotEmpty),
  'HEAD',
];
