// SPDX-License-Identifier: Apache-2.0
//
// The one type every check in this package returns.
//
// It has its own file so that a checker can live beside the model it checks —
// play_metadata.dart and data_safety.dart both need this, and both are imported
// by cux_ship_verify.dart, so leaving it there would make the dependency a
// cycle. Splitting it is cheaper than the alternative, which is putting every
// check in one file and separating it from the loader that produces its
// evidence.
library;

/// One thing wrong with a repository's release inputs.
///
/// Returned rather than thrown, and in a list, because a caller checking a
/// whole changelog wants every over-long section named at once. Being told
/// about them one release at a time is how a limit gets hit twice.
class ReleaseProblem {
  const ReleaseProblem(this.where, this.message);

  /// What was being checked, in terms a reader can go and look at — a version
  /// heading and a platform, or a locale and a screenshot directory.
  final String where;

  /// What is wrong, and where possible what to do instead.
  final String message;

  @override
  String toString() => '$where: $message';
}
