/// What `--store` resolves to, over a consumer's declared destinations.
///
/// **The flag keeps its name and its spelling.** `--store play` and `--store
/// appstore:ios` are typed identically in both repositories, which is the
/// parity the consumer asked for; what changes is that the values come from
/// the table rather than from a four-row map compiled into the tool. The word
/// "store" is slightly wrong for a direct download or a web app, and it stays
/// anyway: two spellings of one flag across two repositories is the opposite
/// of the thing being asked for.
///
/// **The rule this file exists for: a flag that would do nothing is refused,
/// not dropped.** That is the donor's rule — it already refuses `--prepare`
/// for Play rather than ignoring it — and it is what makes a narrowed run
/// trustworthy. `--store amazon beta` cannot be a no-op success, because an
/// operator who typed it believes a beta went somewhere.
library;

import 'destinations.dart';

/// A `--store` value this file would have to guess about.
class StoreSelectionException implements Exception {
  StoreSelectionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The destinations one invocation acts on.
class StoreSelection {
  StoreSelection({
    required List<Destination> acting,
    required List<Destination> skipped,
    required this.coversEveryDestination,
  }) : acting = List.unmodifiable(acting),
       skipped = List.unmodifiable(skipped);

  /// The destinations with something to do at this stage, in declaration order.
  final List<Destination> acting;

  /// Destinations the names selected that have no step at this stage.
  ///
  /// **Reported rather than silently dropped.** A family is the case that
  /// makes this necessary: `--store direct production` acts on four rows and
  /// `--store direct beta` on none, but `--store appstore beta` acts on two
  /// and those two are the whole family, so there is nothing to report. In
  /// between — a family where some members are staged and some are not — the
  /// operator has to be told which, or a narrowed run reads as broader than it
  /// was.
  final List<Destination> skipped;

  /// Whether the names covered every destination the consumer declares.
  ///
  /// **Not the finish rule**, which asks whether every destination with a
  /// production step has been *recorded*; this only says the invocation was
  /// not narrowed. The finish rule consumes it and adds the record.
  final bool coversEveryDestination;
}

/// Resolves [names] against [table] for [stage].
///
/// An empty [names] is "every destination", and it is the default.
///
/// **It is not a precondition of the finish rule**, and the draft of this
/// comment said it was. §4 of `authpass-on-the-train.md` settles the rule as
/// "every declared destination that has a production step is *recorded* at
/// production" — a question about the record, not about whether this
/// invocation was narrowed. §3's `production` is resumable across days, so the
/// last console finished with `--store ppa production` has to be able to spend
/// the version tag; a rule keyed on this argument could never let it.
StoreSelection resolveStores({
  required DestinationTable table,
  required List<String> names,
  required Stage stage,
}) {
  final chosen = names.isEmpty
      ? table.destinations.toList()
      : _expand(table, names);

  final acting = <Destination>[];
  final skipped = <Destination>[];
  for (final destination in chosen) {
    if (destination.stepAt(stage).kind == StepKind.none) {
      skipped.add(destination);
    } else {
      acting.add(destination);
    }
  }

  // **Nothing to do is a refusal, and it names what was asked for.** With no
  // narrowing this cannot fire for a sane table, so in practice it is the
  // answer to a narrowed invocation — and the message says which stages the
  // destination does have, because the next thing the operator wants is not
  // "that failed" but "then what can I do with it".
  if (acting.isEmpty) {
    throw StoreSelectionException(_nothingToDo(names, skipped, stage));
  }

  return StoreSelection(
    acting: acting,
    skipped: skipped,
    // **One comparison, not two.** The draft also asked whether `chosen` held
    // a destination twice, which cannot happen: `_expand` rebuilds the list
    // from the table filtered by a set of wanted names, and the unnarrowed
    // path copies a list whose names a `YamlMap` already made unique. A second
    // condition that can never be false reads as a guard and is not one —
    // whoever next changed `_expand` would have trusted it. The repetition it
    // was aimed at is caught by the length comparison alone, which the
    // `is not fooled by a repeated name` case holds.
    coversEveryDestination: chosen.length == table.destinations.length,
  );
}

/// Turns names into destinations, refusing anything it would have to guess at.
List<Destination> _expand(DestinationTable table, List<String> names) {
  final chosen = <Destination>[];
  for (final name in names) {
    final destination = table.byName(name);
    if (destination != null) {
      chosen.add(destination);
      continue;
    }
    final members = table.membersOf(name);
    if (members.isNotEmpty) {
      chosen.addAll(members);
      continue;
    }
    throw StoreSelectionException(_unknown(table, name));
  }
  // **Back into declaration order, and this is also what deduplicates.** Two
  // cases need it and neither is an error: `--store play play` is a typo
  // rather than a quantity, and `--store appstore appstore:ios` names a family
  // and one of its members. Rebuilding from the table filtered by a set of
  // wanted names answers both at once, and makes a report read the same
  // however the invocation was typed.
  //
  // The draft also kept a `seen` set in the loop above to skip a repeated
  // name. Mutation testing killed it: removing it left every case green,
  // because this rebuild had already done the work. It was a second guard for
  // something one line guarantees — the same shape as the dead second
  // condition in `coversEveryDestination` above, found the same way, and both
  // would have read to the next person as load-bearing.
  final wanted = chosen.map((d) => d.name).toSet();
  return [
    for (final destination in table.destinations)
      if (wanted.contains(destination.name)) destination,
  ];
}

String _unknown(DestinationTable table, String name) {
  final colon = name.indexOf(':');
  if (colon > 0) {
    final family = name.substring(0, colon);
    final members = table.membersOf(family);
    if (members.isNotEmpty) {
      return '`$name` is not a destination. `$family` has '
          '${members.map((d) => '`${d.name}`').join(', ')}.';
    }
  }
  return '`$name` is not a destination. Declared: '
      '${table.selectableNames.map((n) => '`$n`').join(', ')}.';
}

String _nothingToDo(
  List<String> names,
  List<Destination> skipped,
  Stage stage,
) {
  if (skipped.length == 1) {
    final destination = skipped.single;
    final has = Stage.values
        .where((s) => destination.stepAt(s).kind != StepKind.none)
        .map((s) => '`${s.name}`')
        .toList();
    final alternative = has.isEmpty
        ? 'it has no stage at all — nothing about this release reaches it'
        : 'the stages it has are ${has.join(' and ')}';
    return '`${destination.name}` has no `${stage.name}` stage; $alternative.';
  }
  // **The unnarrowed run gets its own sentence**, because the narrowed one's
  // subject is the names that were typed and there are none to put there. The
  // draft interpolated `no destination` into the same frame and read "no
  // destination have no `beta` stage", which is both ungrammatical and the
  // opposite of what it means. Reachable without a typo: `beta` over a table
  // where nobody declares one.
  final skippedNames = skipped.map((d) => '`${d.name}`').join(', ');
  if (names.isEmpty) {
    return 'no destination has a `${stage.name}` stage: '
        '$skippedNames declare nothing at that stage.';
  }
  return '${names.map((n) => '`$n`').join(', ')} '
      '${names.length == 1 ? 'has' : 'have'} no `${stage.name}` stage: '
      '$skippedNames declare nothing at that stage.';
}
