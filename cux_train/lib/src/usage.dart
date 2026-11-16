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

// **There was briefly a `notReadyExit = 2` here, and removing it is the
// finding rather than the tidying.** `ready` was written as a gate that
// refused when a destination had turned the build down. §6.1 records a
// refusal so that the next `production` run returns to that destination, so
// the refusal is a reason to run rather than a veto — and since nothing
// clears one, the gate never reopened: `train ready && train production`,
// which this package's own README recommended, stopped that build's release
// for good. With the veto gone there is no state this half of the verb can
// answer no to, every refusal left is an error, and an exit code nothing can
// produce is the donor's dropped flag in another spelling. The number comes
// back with the reads, where §3's refusals actually live.
