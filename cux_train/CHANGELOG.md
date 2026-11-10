# Changelog

## 0.1.0-dev.1

### Added

**The package, as the fourth workspace member**, ahead of the release train
that `docs/design/release-train.md` plans to move into it. It has an entry
point and a usage text; no release command exists yet, and the usage says so.

`package:cux_train/cli.dart` is launchable from the start, the way `cux_ship`
and `cux_buildnumber` became launchable in their last release, so no consumer
ever has to recover this package's path out of `package_config.json`:

```bash
dart --packages=<checkout>/.dart_tool/package_config.json \
     package:cux_train/cli.dart help
```

An invocation the command cannot run exits **64** — `EX_USAGE`, the code
`cux_ship` gives a `UsageException` — and writes the message and the usage to
stderr, leaving stdout empty. Both halves are tested: a release step driven
from a shell script treats a misspelled command that exits 0 as a step that
silently did not run, and a consumer capturing stdout for a step's result
should not find help text in it.

### Changed

**The Dart floor for the whole repository is unchanged, and that is a finding
rather than a default.** The donor package declares `sdk: ^3.13.0`, which
`release-train.md` §7 priced as forcing a Flutter bump on AuthPass — whose
pinned Flutter 3.44.7 bundles Dart 3.12.2. The constraint turned out to be
incidental: declared at `^3.12.2`, a copy of that package analyzes with no
issues, so it uses no 3.13 language feature. This member therefore sits at
`^3.12.2` with its three siblings and the workspace root, and the ordering
stage costs the consumer no SDK move. The design document records what was run.
