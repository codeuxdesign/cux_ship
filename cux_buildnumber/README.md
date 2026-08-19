# cux_buildnumber

A build number that belongs to a **commit** rather than to a machine or a CI
run. Two hosts building the same SHA get the same answer, a number is never
reused for a different commit, and the counter never goes backwards — which
matters because Google Play requires `versionCode` to only ever increase, and
refuses an artifact forever once a number has been spent.

A Dart port of [`git-buildnumber.sh`][gbn] v1.3, and a drop-in replacement for
it: same refs, same commands, same output.

[gbn]: https://github.com/hpoul/git-buildnumber

```console
$ git-buildnumber generate
51
```

The state lives in the repository, shared through `origin`:

| Ref | What it holds |
|---|---|
| `refs/buildnumbers/last` | the counter, as a blob |
| `refs/buildnumbers/commits` | a commit chain, one entry per number, naming the commit it was allocated for |
| `refs/notes/buildnumbers` | a note on each numbered commit |

## Why not `git rev-list --count HEAD`

It looks equivalent and is not. The count collides across branches, and a rebase
or a squash makes it go **backwards** — so a repository that has already spent a
number cannot publish again until it grows past it. That is not a hypothetical:
it is why this tool exists.

## The one thing the port adds

**The git argument lists are pure functions returning `List<String>`, and the
tests read them directly.**

The worst defect in this tool's history was a `+` on the push refspec sitting
beside `--force-with-lease`. The two are contradictory — a `+` is per-ref
`--force` and overrides the lease — and git says nothing at all. The result was
a push that could not fail, so concurrent allocations silently overwrote each
other and the retry that exists for a lost race was unreachable code.

Nothing about a black-box run reveals that until two machines allocate at the
same instant, which is why it survived a version. A unit test reads it in
milliseconds:

```dart
test('no element of the push argv begins with "+"', () {
  expect(pushArgs(...), everyElement(isNot(startsWith('+'))));
});
```

The counter arithmetic and the retry decisions are pure functions for the same
reason. `lib/src/tool.dart` holds sequencing and I/O and nothing else.

## Commands

Compatibility is the point, so this is the shell script's surface exactly.
**Consumers parse stdout**, and each of these is depended on somewhere:

| Command | stdout |
|---|---|
| `generate` *(also the default)* | the bare integer, nothing else |
| `get` | the note if there is one — **exit 0 and empty output** when the commit has no number |
| `find-commit <n>` (`find`) | a `git log -1` block; callers grep the `^commit <sha>` line out of it |
| `fetch`, `push`, `sync` | nothing; all logging is on stderr |
| `force <n>` | `Written build number.` |
| `force-incr` | the new number |

Environment: `GIT_REMOTE`, `GIT_FETCH_REMOTE`, `GIT_PUSH_REMOTE`,
`MAX_ATTEMPTS`, `IGNORE_REPOSITORY_STATE`, `DIFF_INDEX_ARGS`, `VERBOSE`.

Needs **git 2.15 or newer** in practice — `push --atomic`,
`--force-with-lease=<ref>:<value>` and `rev-parse --is-shallow-repository`.
Older git is not refused; the shallow probe degrades, exactly as the shell does.

## Concurrency

Allocation is a race, and losing it is the ordinary case rather than the
exception. Every push is `--atomic` and leased against values read from **the
remote being pushed to** — not from local refs, which certify nothing. A run
that loses re-fetches and reallocates rather than returning the number it just
lost with, attempts are bounded, and a run that gives up restores the refs it
wrote.

## Compatibility with the shell script

Same refs, byte-for-byte where it matters: the counter blob keeps its trailing
newline, chain entries keep their tree shape, and chain entries written before
v1.3 — which every existing repository has — are read without complaint. The two
implementations can be used against one repository in either order.

**One deliberate divergence.** The shell invokes its fetch inside `&&` lists,
where bash suspends `errexit`, so a failed `git fetch` is silently continued
past and `fetch` can exit 0 having fetched nothing. Here a failed fetch is
fatal in every command. Stricter than the original, invisible to the shared
acceptance suite, and said out loud here so it is a choice rather than a
discovery.

## If this ever grows a salvage command

Repositories that allocated before the chain carried reachability have commits
no ref points at, and recovering them is a natural thing to want here. The trap
is worth writing down before anyone implements it, because it is silent:

**A pass that detects orphans by reachability must compute the whole set before
it writes anything.** Tagging one orphan makes every commit it can reach
reachable too, so a `--contains` test inside the same loop stops seeing the
orphans it has not got to yet. Two abandoned consecutive builds is enough — no
shared commit is required, only shared ancestry, which is the ordinary shape
when consecutive builds are abandoned together.

Both failure modes have been observed, in two repositories on the same
afternoon: one loop skipped a second build number sharing a commit with the
first, and the other would have skipped an ancestor had it tagged in the other
order. Neither reported anything; the output looked complete.

## Testing

`test/acceptance/test.sh` is the shell project's own suite, vendored unchanged
and run against the compiled binary — 16 cases, each of which was written
against a specific defect. `tool/acceptance.sh` compiles and runs it.

```console
$ dart test                 # the unit tests
$ tool/acceptance.sh        # the binary, against the shared suite
```

## Licence

Apache 2.0, the same as the rest of this repository.
