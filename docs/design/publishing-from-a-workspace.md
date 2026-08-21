# `resolution: workspace` reaches consumers, and it stays

Status: **decided**, 21 August 2026, after the second time somebody proposed
dropping the key. Everything below was verified by running it against
`cux_ship 3.4.1` and Dart 3.13.0, not read off an issue tracker.

Every consumer of a package published from this repository sees this on **every
invocation** — `pub get`, `dart run`, a build script, a CI step:

```
Found a pubspec.yaml at ~/.pub-cache/hosted/pub.dev/cux_ship-3.4.1.
But it has resolution `workspace`.
But found no workspace root including it in parent directories.

See https://dart.dev/go/pub-workspaces for more information.
```

It is noise, it is permanent, and **it is not a bug to fix here.**

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
