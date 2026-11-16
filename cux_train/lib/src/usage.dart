/// The exit code an unusable invocation gets.
///
/// **The usage *text* used to live here too, and the command tree took it
/// over.** `CommandRunner` composes it from the verbs and their flags, which
/// is the whole reason to use one: a verb added without its help text showing
/// up is not a thing that can happen. What is left here is the number, which
/// belongs to the contract rather than to the presentation — a consumer
/// branches on it, nobody branches on a paragraph.
library;

/// The exit code for an invocation this command cannot make sense of.
///
/// **Hardcoded, and the reason it would stop being has turned out to be
/// wrong.** The note here used to say that `cux_ship` owns this vocabulary in
/// `package:cux_ship/exit_codes.dart` and that this package would import it
/// once it depended on `cux_ship` for anything else. It now does depend on it
/// — `provenance.dart`, for the record writer — and there is nothing to
/// import: that library's own header says 64 "comes from the argument parser
/// rather than from any of these", and its exported constants are five codes
/// for outcomes of its own commands. `cux_ship`'s entry writes the digit with
/// an `EX_USAGE` comment. So the duplication is not temporary, and it is not
/// a duplication of anything: both packages take 64 from `sysexits.h`'s
/// `EX_USAGE` — `package:args` defines no code at all, and its README's
/// example exits with the same number — and a constant in each is the correct
/// amount of coupling to a number that is fixed by convention.
const int usageExit = 64;

/// The exit code for a `ready` that answered no.
///
/// **A state, not a failure, and it has its own number for that reason.**
/// `cux_ship` draws the same line — `noSuchVersionExit` is documented there as
/// "an ordinary state, not a failure" — and the distinction is what lets a
/// launcher write `train ready && train production` without a blocked `ready`
/// reading as a crashed tool. A 1 here would be indistinguishable from a table
/// that would not parse.
///
/// **2 rather than a number continuing `cux_ship`'s list.** The two binaries
/// are typed one after the other and share a code where one is fixed by
/// convention — `usageExit` is 64 in both because `sysexits.h` says so — but
/// these belong to a command's own outcomes, and `cux_ship`'s 2 through 6 are
/// five of *its* commands' states. Numbering around them would imply one list
/// a reader could look up in one place, and there is no such list.
const int notReadyExit = 2;
