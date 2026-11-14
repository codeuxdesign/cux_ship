/// The command's usage text, and the exit code an unusable invocation gets.
///
/// **This is the whole of the *command* today, and no longer of the package.**
/// The library beside it parses a destination table and reads a promotion
/// record, and the entry point reaches none of it yet: the orchestration
/// `cux_train` is named for still lives in How It Went's `tool/train/`, and
/// `docs/design/release-train.md` is the plan for moving it. The member came
/// first so that the move lands as commits against a package CI already
/// builds, publishes a dry run of and runs `dart format` over, rather than as
/// one commit that creates a package and fills it at the same time.
library;

/// The exit code for an invocation this command cannot make sense of.
///
/// **Hardcoded, and it will stop being.** `cux_ship` already owns this
/// vocabulary in `package:cux_ship/exit_codes.dart`, where `UsageException`
/// maps to 64, and this package will import it the moment it has any other
/// reason to depend on `cux_ship` — which the first moved step gives it, since
/// every step spawns the command. Depending on it now, for one integer, would
/// put googleapis and a JWT signer in the lockfile of a package that does
/// nothing, and the number is fixed by the same convention either way: 64 is
/// `EX_USAGE` from `sysexits.h`, which is where both stores' tooling and
/// `package:args` take it from.
const int usageExit = 64;

/// What the command prints when asked how to use it, or when it cannot tell.
///
/// A function rather than a constant because the text will take arguments
/// before long — the step list it prints is the thing the move brings, and a
/// consumer's own destinations belong in it.
String usageText() => '''
cux_train — order the steps of a release.

usage: cux_train <command>

  help    print this text

No release commands yet. This package is the workspace member the release
train moves into; see docs/design/release-train.md for what is planned and
what has already been verified. Until a step lands here, the orchestration
to use is still How It Went's tool/train.sh.
''';
