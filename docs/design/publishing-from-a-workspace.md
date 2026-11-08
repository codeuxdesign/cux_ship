# `resolution: workspace` reaches consumers, and it stays

Status: **decided**, 21 August 2026, after the second time somebody proposed
dropping the key. Everything below was verified by running it against
`cux_ship 3.4.1` and Dart 3.13.0, not read off an issue tracker.

Every consumer of a package published from this repository sees this on `pub
get` and on **`dart run`** — so on nearly every build script and CI step:

```
Found a pubspec.yaml at ~/.pub-cache/hosted/pub.dev/cux_ship-3.4.1.
But it has resolution `workspace`.
But found no workspace root including it in parent directories.

See https://dart.dev/go/pub-workspaces for more information.
```

It is noise, it is permanent, and **it is not a bug to fix here.**

**It is, however, avoidable at the call site, which this document used to deny.**
`dart <entry>` — no `run` — does not inspect the entry's enclosing package and
prints nothing. Measured on `--help` by the consumer that found it, 4 September
2026: stdout byte-identical at 25 lines, same exit code, stderr four lines
against none, startup unchanged at 2.7–3.0 s either way. So a project pinning
this package can have a clean log today by invoking the entry directly instead
of through `dart run`. That does not change anything below — `pub get` still
warns, the key still stays — but the claim that every invocation carries it was
wrong, and a reader who takes "permanent" to mean "unavoidable" spends an
afternoon confirming it.

**And the advice above has a trap in it, found 9 September 2026 by a consumer
pinning a branch of this repository as a git dependency.** `dart <entry>` needs
a package config, and the obvious guess for where one is — beside the package,
at `cux_ship/.dart_tool/package_config.json` — is wrong here for the same
reason this whole document exists: `resolution: workspace` means `pub get`
writes one config at the **workspace root**, one level up, and none beside the
member. Passing the member path fails as a wall of `Couldn't resolve the
package` lines, which reads like a broken checkout rather than a wrong flag,
and the reader then goes looking at their pin rather than at their path.

```bash
dart --packages=<checkout>/.dart_tool/package_config.json \
     <checkout>/cux_ship/bin/cux_ship.dart …
```

This is the condition the closing section names — it *fails* a resolution
rather than printing beside one — so it is written here rather than treated as
noise. It does not reopen the decision below: nothing about the key is wrong,
and the fix is a path, not a pubspec.

**And the entry is no longer a path at all, which closes the question the two
paragraphs above were working around.** Since 8 November 2026 the CLI is
declared in `lib/cli.dart`, so the VM resolves it through `--packages` and the
advice becomes a line a consumer can write without knowing where the package
landed:

```bash
dart --packages=<checkout>/.dart_tool/package_config.json \
     package:cux_ship/cli.dart …
```

**The path version was worse than "a path, not a pubspec" made it sound, and
that is why this changed.** For a git pin the path is writable by hand, which is
the case above. For a *hosted* pin it is a version-stamped directory under
`~/.pub-cache`, so the launcher has to read `rootUri` out of
`package_config.json` to find it — and nothing here told anybody that, so they
reached for a regex. The one that did met all three of its failure modes, in one
release tool:

- `"name": "cux_ship"` is a prefix of `"name": "cux_ship_verify"`, which is the
  next entry in the file. The match was anchored on a trailing comma and on pub
  pretty-printing with `rootUri` on the following line — both shapes pub happens
  to emit rather than anything the format promises. **The same trap is in this
  package's own README**, where the lockfile `grep` is anchored on a `$` for
  exactly this reason, and two readers wrote that one unanchored before it was
  noticed. Three readers, two files, one prefix.
- A `rootUri` is **relative** for a `path:` dependency, resolved against the
  directory holding `package_config.json`. The `file://` pattern matched
  nothing, so the launcher refused a healthy checkout — and a `path:` pin is how
  that project develops against an unreleased fix here, so the failure landed on
  the people most likely to be helping.
- A `file:` URI is percent-encoded, so a pub cache under a path containing a
  space arrives as `%20` and goes through verbatim, failing as a missing file in
  the pub cache rather than as an encoding.

A parser fixes all three and the consumer wrote one. But the three defects were
only reachable because this package made the entry a path, and the fix for
*that* is one file here rather than a parser in every consumer.

**`main` rather than a named function**, because the VM looks up `main` in the
library it is given as the script — the name is what makes the invocation above
work with no file in between. `bin/cux_ship.dart` becomes `export
'package:cux_ship/cli.dart' show main;`, which keeps `dart run cux_ship` and
`dart pub global activate` working, and the exception-to-exit-code mapping moves
into the library with the body, so a consumer writing its own entry cannot end
up with a stale copy of it.

**It does not cover `dart compile kernel`, which refuses a `package:` URI** —
`"package:cux_ship/cli.dart" file not found`, where the plain `dart` above
resolves it. A consumer caching a snapshot (the one here went from ~4 s a run to
~420 ms, and a release makes ten invocations) still needs a real file, but it can
be a one-line `export` committed in its own tree rather than a path recovered
from the pub cache. Measured both ways before choosing the form:
`dart compile kernel` accepts an export-only entry and the snapshot runs.

`cux_ship/test/cli_library_entry_test.dart` holds this, because the only users
of the contract are outside this repository: it spawns the `package:` form,
compares it byte-for-byte against `bin/cux_ship.dart`, and asserts stderr is
empty — the last of which is the property this whole document is about.

**`cux_buildnumber` got the same treatment in the same change**, with
`lib/cli.dart` and a copy of that test, because the consumer that hit the regex
launches both and `_common.sh` was reading `rootUri` for that one too. The
remaining member, `cux_ship_verify`, has no `bin/` and so has no entry to
declare. Worth saying plainly: **a published member with an executable wants a
`lib/cli.dart`**, and the reason is this document's whole subject — the key
stays, so `dart run` warns, so consumers invoke the entry, so the entry has to
be nameable without a path.

## The four facts, each checked

**1. Dropping the key is a hard error, not a trade-off.** `resolution: workspace`
is what makes a directory a member of the workspace its root `pubspec.yaml`
lists. Remove it from `cux_ship/pubspec.yaml` and `dart pub get` at the root
refuses outright:

```
cux_ship/pubspec.yaml is included in the workspace from ./pubspec.yaml,
but does not have `resolution: workspace`.
```

So the repository does not resolve at all — not "resolves differently". This is
the whole question, and it is closed.

**2. `pub publish` copies the key verbatim, and considers that correct.**
`dart pub publish --dry-run` reports **0 warnings**, and pub.dev serves the key
in the published pubspec:

```
$ curl -s https://pub.dev/api/packages/cux_ship | ... ['pubspec']['resolution']
workspace
```

There is no publish-time strip, no flag to request one, and no warning
suggesting there should be. Pub is not treating this as a mistake.

**3. It is cosmetic. Resolution succeeds and the consumer works.** How It Went
built a 69 MB signed `.aab`, wrote a manifest, cross-checked it against the
bundle, and uploaded to Play internal — through the published 3.4.1, with that
warning printed twice along the way. Nothing degrades. The cost is entirely in
build logs.

**4. A workaround exists, works, and is rejected.** Moving the key into a
committed `cux_ship/pubspec_overrides.yaml` was tried end to end: the workspace
still resolves to one root lockfile, the CLI still runs, `publish --dry-run`
gains no warning, and `pubspec_overrides.yaml` is **excluded from the published
archive** — so consumers would see a clean pubspec.

It is still the wrong thing to do, for a reason that has nothing to do with
whether it works:

> **`pubspec_overrides.yaml` is, by convention, a local file that is not
> committed** — it exists so a developer can point at a checkout on their own
> machine. Putting load-bearing repository configuration in one inverts what
> the file is for, and the failure mode is silent: anyone whose *global*
> gitignore lists `pubspec_overrides.yaml` — a common entry — has `git add`
> quietly skip it, and their clone does not resolve. The error they get names
> the missing resolution key, which is nowhere in the repository they can see.

It also depends on `pub publish` ignoring `pubspec_overrides.yaml`, which is a
documented *omission* rather than a guarantee (dart-lang/pub#3781). Building on
"this is currently not read" means a future release that does read it breaks
publishing, and the break arrives at the worst moment.

Trading a visible cosmetic warning for an invisible structural one is the
trade this repository refuses everywhere else.

## What would actually fix it

Pub stripping `resolution:` from the published pubspec, upstream — it is
meaningless outside the repository that owns the workspace root, which is
exactly why consumers are told there is no root. That is a change to pub, and
until it happens the warning is the correct cost of publishing from a
workspace.

The workspace itself is worth that cost, and the root `pubspec.yaml` says why:
one `pub get` and one lockfile for the whole repository, while each member still
declares ordinary hosted constraints — so `cux_ship`'s dependency on
`cux_ship_verify` resolves to the copy on disk here and to pub.dev everywhere
else, with no `path:` rewriting around a publish and no melos.

## If you are here because you saw the warning

Nothing is wrong. Do not drop the key, do not move it to an override file, and
do not add a `# ignore` for it. If it becomes more than noise — if it ever
fails a resolution rather than printing beside one — that is a new fact and
this document is wrong; say so here with what you ran.
