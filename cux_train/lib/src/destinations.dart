/// The destination table: what a release has to reach, and who acts at each
/// stage.
///
/// **This is the piece that lets one train serve two repositories**, and it is
/// the first thing `docs/design/authpass-on-the-train.md` §8 asks for. The
/// donor validates `--store` against a hardcoded four-row map of the stores it
/// happens to publish to; a consumer with nineteen destinations, six of them
/// Android and four of them direct downloads, cannot be expressed in that map
/// — and the donor's own comment reaches for the same answer, anticipating a
/// second Android store and saying of F-Droid that "A row in the table below
/// can express that" (the comment as §2 records it). So the map becomes data
/// the consumer declares, and the donor becomes the degenerate case with three
/// rows.
///
/// **What is deliberately not here.** No step is executed and no store is
/// contacted: this file parses a declaration and answers questions about it.
/// Running a step needs the record and the evidence model, which are later
/// commits, and keeping those apart is what makes this one testable without a
/// network or a store credential.
library;

import 'package:yaml/yaml.dart';

/// A declaration this file could not make sense of.
///
/// **Its message names the file and the key**, because the reader is an
/// operator who has just typed a release command and needs to know which line
/// of which file to open — not a stack trace. The same reasoning as
/// `cux_ship`'s `ProjectException` (`lib/src/project.dart`, which no public
/// library of that package exports today), and this becomes it if and when
/// that type is exported alongside `exit_codes.dart`.
class DestinationTableException implements Exception {
  DestinationTableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The audiences a release moves through, in the order it moves through them.
///
/// **The names are the donor's verbs and that is the whole point.** The ask
/// this table answers is "use `train.sh` the same way in both repositories", so
/// a stage is not a consumer-defined concept — a consumer declares *what
/// happens* at each of these, never a stage of its own. `status` and `ready`
/// are not here because they read the table rather than appearing in it.
enum Stage {
  internal,
  beta,
  production;

  /// The stage called [name], or null.
  ///
  /// Null rather than a throw, so a caller can tell "not a stage" from "a
  /// stage I cannot serve" and say which.
  static Stage? byName(String name) {
    for (final stage in values) {
      if (stage.name == name) {
        return stage;
      }
    }
    return null;
  }
}

/// Who acts on a destination at one stage.
///
/// Four kinds, and the fourth is why the table works for AuthPass at all: a
/// cell nobody can automate is still a row, declared rather than omitted, so
/// the five verbs mean the same thing before anything is automated.
enum StepKind {
  /// The train spawns `cux_ship` through the consumer's shim.
  ship,

  /// The train spawns a script the consumer owns.
  run,

  /// A person acts. The train instructs, waits, and records.
  manual,

  /// Nobody acts, and that is a fact about the destination rather than a gap.
  /// Every "no beta audience" cell is one of these.
  none;

  static StepKind? byName(String name) {
    for (final kind in values) {
      if (kind.name == name) {
        return kind;
      }
    }
    return null;
  }

  /// Whether this kind names something for the train to spawn.
  bool get spawns => this == ship || this == run;
}

/// What happens to one destination at one stage.
class DestinationStep {
  const DestinationStep({
    required this.kind,
    this.command,
    this.console,
    this.note,
  });

  /// The step that applies where a destination declares no stage at all.
  ///
  /// **Absent means `none`, and that is a deliberate asymmetry with the
  /// unknown-key policy below.** A missing key is refused everywhere else in
  /// this file; a missing *stage* is not, because nineteen destinations times
  /// three stages is fifty-seven cells, twenty-four of them "nobody acts", and
  /// a table that makes the author write them all out is a table whose rows
  /// get copied rather than read.
  ///
  /// **What that trades away, exactly.** A stage *written and left empty* is
  /// refused at parse time — `_parseDestination` tells absent from
  /// explicit-null. A stage whose key is gone is not, so the omission shows up
  /// at the stage: `--store x beta` refuses when the cell is `none`, and an
  /// unnarrowed run reports the destination as skipped. The second is weaker
  /// than a refusal and is the real cost of the default.
  static const absent = DestinationStep(kind: StepKind.none);

  final StepKind kind;

  /// What to spawn, for [StepKind.ship] and [StepKind.run].
  final String? command;

  /// Where a person goes, for [StepKind.manual].
  final String? console;

  /// A line for the operator, shown with the instruction.
  final String? note;
}

/// One place a release has to reach.
class Destination {
  const Destination({
    required this.name,
    required this.steps,
    this.read,
    this.identity = const {},
    this.afterFinish = false,
  });

  /// The name typed after `--store`.
  ///
  /// Either a bare word (`play`) or `family:member` (`appstore:ios`), which is
  /// the form the donor already uses — generalized rather than invented, so
  /// `--store appstore:ios` is typed identically in both repositories.
  final String name;

  /// What happens at each stage. A stage absent here is [DestinationStep.absent].
  final Map<Stage, DestinationStep> steps;

  /// How to read what this destination currently holds, if it can be read.
  ///
  /// Null means unreadable, which is not a defect — it is what makes a
  /// destination *attested* rather than *observed*, and four of AuthPass's
  /// are: the store consoles, with two more the plan takes no position on.
  final String? read;

  /// Per-destination identity: `package`, `bundle-id`, whatever the step needs.
  ///
  /// **A map rather than named fields, because the donor's singular
  /// `appleBundleId`/`playPackageName` is exactly what cannot express a
  /// consumer with two App Store records and two Play packages.**
  final Map<String, String> identity;

  /// Whether this destination's production step runs *after* the version tag.
  ///
  /// **The one exclusion from the finish rule that is not vacuous**, and the
  /// reason it is table data rather than a name in the rule: AuthPass's
  /// `fdroid` step pushes `fdroid-vX.Y.Z`, which cannot sensibly precede the
  /// `vX.Y.Z` it annotates, so finish must not wait on it (§3 step 5). The
  /// next consumer will have the same shape under another name, or none at
  /// all — the donor has none.
  ///
  /// It says nothing about *order within* the run; it says only that the
  /// finish rule does not count this destination.
  final bool afterFinish;

  /// The part before the colon, or null for a bare name.
  String? get family {
    final colon = name.indexOf(':');
    return colon < 0 ? null : name.substring(0, colon);
  }

  /// The part after the colon, or null for a bare name.
  String? get member {
    final colon = name.indexOf(':');
    return colon < 0 ? null : name.substring(colon + 1);
  }

  /// What happens at [stage].
  DestinationStep stepAt(Stage stage) => steps[stage] ?? DestinationStep.absent;
}

/// Every destination a consumer declares.
class DestinationTable {
  DestinationTable(List<Destination> destinations)
    : destinations = List.unmodifiable(destinations);

  /// Parses a `destinations:` declaration.
  ///
  /// [source] is the filename to name in any refusal — the caller's, because
  /// §4 of the plan leaves the file's *name* unsettled (a `train:` block in
  /// `.cux-ship.yaml` once that file's key list knows the word, a sibling
  /// `.cux-train.yaml` until then) and this parser should not have an opinion
  /// about which it was handed.
  factory DestinationTable.parse(String yaml, {required String source}) {
    final Object? document;
    try {
      document = loadYaml(yaml);
    } on YamlException catch (error) {
      throw DestinationTableException('$source is not valid YAML: $error');
    }
    if (document == null) {
      throw DestinationTableException('$source is empty');
    }
    if (document is! YamlMap) {
      throw DestinationTableException(
        '$source must be a map with a `destinations` key',
      );
    }
    _checkKeys(document, const {'destinations'}, source);

    // **Missing and malformed are separate messages**, because they are
    // separate mistakes: the first is a file that has not been written yet,
    // the second is one whose author meant something this parser cannot read.
    // Collapsing them tells an operator the wrong thing to go and look at —
    // and the first draft of this parser did collapse them, which is what the
    // `an empty or absent destinations` case caught.
    if (!document.containsKey('destinations')) {
      throw DestinationTableException(
        '$source must be a map with a `destinations` key',
      );
    }
    final declared = document['destinations'];
    if (declared is! YamlMap) {
      throw DestinationTableException(
        '$source: `destinations` must be a map of name to destination',
      );
    }
    if (declared.isEmpty) {
      throw DestinationTableException(
        '$source: `destinations` is empty, so there is nothing to release to',
      );
    }

    final destinations = <Destination>[];
    for (final entry in declared.entries) {
      // **A name YAML did not read as text is refused, not stringified.**
      // `'${entry.key}'` accepts anything and what it produces is a *plausible
      // name*: an unquoted `~:` becomes the four letters `null`, `true:`
      // becomes `true`, and `--store null` then selects a destination nobody
      // declared. The name pattern cannot catch it, because the stringified
      // form is a legal name — which is why this has to be a check on the
      // type rather than on the spelling. Quoting it is the fix.
      final key = entry.key;
      if (key is! String) {
        throw DestinationTableException(
          '$source: a destination name must be text, and YAML read '
          '`${entry.key}` as ${key == null ? 'null' : key.runtimeType} — '
          'quote it if that is the name you meant',
        );
      }
      destinations.add(_parseDestination(key, entry.value, source));
    }
    final table = DestinationTable(destinations);
    table._checkNamesAreUsable(source);
    return table;
  }

  final List<Destination> destinations;

  /// The destination called [name], or null.
  Destination? byName(String name) {
    for (final destination in destinations) {
      if (destination.name == name) {
        return destination;
      }
    }
    return null;
  }

  /// The members of the family called [name], in declaration order.
  List<Destination> membersOf(String name) => [
    for (final destination in destinations)
      if (destination.family == name) destination,
  ];

  /// Every family name, in declaration order of their first member.
  List<String> get familyNames {
    final names = <String>[];
    for (final destination in destinations) {
      final family = destination.family;
      if (family != null && !names.contains(family)) {
        names.add(family);
      }
    }
    return names;
  }

  /// Every name `--store` accepts, families included, sorted for a message.
  List<String> get selectableNames =>
      [...destinations.map((d) => d.name), ...familyNames]..sort();

  /// **A family name and a destination name must not collide.**
  ///
  /// Declaring both `direct` and `direct:macos` makes `--store direct`
  /// ambiguous — one destination, or four? — and the ambiguity would be
  /// resolved silently by whichever lookup ran first. Refused at parse time
  /// instead, because a release tool that guesses which destinations it was
  /// asked for is the failure this whole table exists to prevent.
  void _checkNamesAreUsable(String source) {
    final families = familyNames.toSet();
    for (final destination in destinations) {
      if (families.contains(destination.name)) {
        throw DestinationTableException(
          '$source: `${destination.name}` is declared as a destination and is '
          'also the family of '
          '${membersOf(destination.name).map((d) => '`${d.name}`').join(', ')}'
          ' — `--store ${destination.name}` could mean either, so one of them '
          'has to be renamed',
        );
      }
    }
  }

  static Destination _parseDestination(
    String name,
    Object? value,
    String source,
  ) {
    _checkName(name, source);
    final where = '$source: destination `$name`';
    if (value is! YamlMap) {
      throw DestinationTableException('$where must be a map');
    }
    _checkKeys(value, const {
      'internal',
      'beta',
      'production',
      'read',
      'identity',
      'after-finish',
    }, where);

    final steps = <Stage, DestinationStep>{};
    for (final stage in Stage.values) {
      // **Absent is `none`; written-and-left-empty is a mistake.** The two
      // are different acts and only the first is a decision: `beta: none` is
      // how an author says nobody acts, so a bare `beta:` — a body deleted, a
      // step commented out mid-edit — is the unknown-key argument applied to a
      // key that happens to be spelt right. This file already refuses the same
      // shape one level up (`play:` with no body is "destination `play` must
      // be a map"), and reading it as `none` here would have the two levels
      // disagree about what an empty body means.
      if (!value.containsKey(stage.name)) {
        continue;
      }
      final declared = value[stage.name];
      if (declared == null) {
        throw DestinationTableException(
          '$where declares `${stage.name}` with nothing in it — write '
          '`${stage.name}: none` for a stage nobody acts at, or leave the key '
          'out',
        );
      }
      steps[stage] = _parseStep(declared, '$where, `${stage.name}`');
    }

    return Destination(
      name: name,
      // **Unmodifiable, as `DestinationTable.destinations` is.** A parsed
      // destination is what `--store` resolves over, and a caller that could
      // put a step into this map could make the train act on a destination at
      // a stage the consumer never declared.
      steps: Map.unmodifiable(steps),
      read: _optionalString(value, 'read', where),
      identity: _parseIdentity(value['identity'], where),
      afterFinish: _parseAfterFinish(value, steps, where),
    );
  }

  /// **`after-finish` is only meaningful where somebody acts at production.**
  ///
  /// It excludes a destination from the finish rule, and a destination with no
  /// production step is already excluded — vacuously, because nothing writes a
  /// record for it. So the key on such a row does nothing, and a key that does
  /// nothing is read by the next person as doing something. The likeliest way
  /// to write it is to mark the right destination and then delete its step,
  /// which is worth being told about.
  static bool _parseAfterFinish(
    YamlMap value,
    Map<Stage, DestinationStep> steps,
    String where,
  ) {
    if (!value.containsKey('after-finish')) {
      return false;
    }
    final declared = value['after-finish'];
    if (declared is! bool) {
      throw DestinationTableException(
        '$where: `after-finish` must be true or false, and YAML read '
        '`$declared` as ${declared == null ? 'null' : declared.runtimeType}',
      );
    }
    final production = steps[Stage.production] ?? DestinationStep.absent;
    if (declared && production.kind == StepKind.none) {
      throw DestinationTableException(
        '$where is `after-finish` but nobody acts at `production` — nothing '
        'would record it, so the finish rule already does not wait on it',
      );
    }
    return declared;
  }

  /// A step is either a bare kind or a map carrying what the kind needs.
  ///
  /// The bare form exists for the kind that dominates a real table: `beta:
  /// none` is sixteen of AuthPass's nineteen beta cells, `none` is twenty-four
  /// of its fifty-seven cells in all, and writing `beta: {kind: none}` sixteen
  /// times is how a table stops being read.
  static DestinationStep _parseStep(Object? declared, String where) {
    if (declared is String) {
      final kind = StepKind.byName(declared);
      if (kind == null) {
        throw DestinationTableException(
          '$where is `$declared`, which is not a step kind — '
          'expected one of ${_kindNames()}',
        );
      }
      return _checkedStep(DestinationStep(kind: kind), where);
    }
    if (declared is! YamlMap) {
      throw DestinationTableException(
        '$where must be a step kind (${_kindNames()}) or a map',
      );
    }
    _checkKeys(declared, const {'kind', 'command', 'console', 'note'}, where);

    // **Absent and present-but-not-a-kind are different mistakes**, and only
    // the first one is a missing `kind`. `kind: 7` told the operator it needed
    // a `kind` it had plainly written, which sends them looking for the wrong
    // thing; a non-string is a value this parser cannot read, so it gets the
    // same message as `kind: shp`.
    final kindName = declared['kind'];
    if (kindName == null) {
      throw DestinationTableException('$where needs a `kind`');
    }
    final kind = kindName is String ? StepKind.byName(kindName) : null;
    if (kind == null) {
      throw DestinationTableException(
        '$where has kind `$kindName`, which is not one of ${_kindNames()}',
      );
    }
    return _checkedStep(
      DestinationStep(
        kind: kind,
        command: _optionalString(declared, 'command', where),
        console: _optionalString(declared, 'console', where),
        note: _optionalString(declared, 'note', where),
      ),
      where,
    );
  }

  /// **A step that spawns must say what, and a step that spawns nothing must
  /// not pretend to.**
  ///
  /// Both halves have cost a release elsewhere in a milder form: a `ship` row
  /// with no command is a destination the train reports as handled and never
  /// touched, and a `none` row carrying a command is a command somebody wrote
  /// expecting it to run. Neither is recoverable later from the record,
  /// because the record only ever says what the train believes it did.
  static DestinationStep _checkedStep(DestinationStep step, String where) {
    // `command == null`, not also `command.isEmpty`: `_optionalString` has
    // already refused an empty one by the time this runs, so a second check
    // for it would read as a guard and never fire — the shape the mutation run
    // found twice in the first draft.
    if (step.kind.spawns && step.command == null) {
      throw DestinationTableException(
        '$where is `${step.kind.name}` and needs a `command` — a step that '
        'spawns nothing would be reported as done',
      );
    }
    if (!step.kind.spawns && step.command != null) {
      throw DestinationTableException(
        '$where is `${step.kind.name}` and carries a `command`, which nothing '
        'would run',
      );
    }
    if (step.kind != StepKind.manual && step.console != null) {
      throw DestinationTableException(
        '$where is `${step.kind.name}` and carries a `console`, which only a '
        '`manual` step shows anyone',
      );
    }
    return step;
  }

  static Map<String, String> _parseIdentity(Object? declared, String where) {
    if (declared == null) {
      return const {};
    }
    if (declared is! YamlMap) {
      throw DestinationTableException('$where: `identity` must be a map');
    }
    final identity = <String, String>{};
    for (final entry in declared.entries) {
      // Same stringification as the destination names above, same refusal: a
      // step reads these by key, so `identity['null']` is a value no step will
      // ever ask for.
      final rawKey = entry.key;
      if (rawKey is! String) {
        throw DestinationTableException(
          '$where: an `identity` key must be text, and YAML read '
          '`${entry.key}` as ${rawKey == null ? 'null' : rawKey.runtimeType}',
        );
      }
      final key = rawKey;
      final value = entry.value;
      if (value is! String || value.isEmpty) {
        throw DestinationTableException(
          '$where: `identity.$key` must be a non-empty string',
        );
      }
      identity[key] = value;
    }
    return Map.unmodifiable(identity);
  }

  /// A name has to be typeable after `--store` and unambiguous in a message.
  static final _namePattern = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

  static void _checkName(String name, String source) {
    final parts = name.split(':');
    if (parts.length > 2) {
      throw DestinationTableException(
        '$source: destination `$name` has more than one colon — a name is '
        '`family:member` at most',
      );
    }
    for (final part in parts) {
      if (!_namePattern.hasMatch(part)) {
        throw DestinationTableException(
          '$source: destination `$name` is not usable after `--store` — each '
          'part must be lower-case letters, digits and single hyphens',
        );
      }
    }
  }

  static String? _optionalString(YamlMap map, String key, String where) {
    final value = map[key];
    if (value == null) {
      return null;
    }
    if (value is! String || value.isEmpty) {
      throw DestinationTableException(
        '$where: `$key` must be a non-empty string',
      );
    }
    return value;
  }

  static String _kindNames() => StepKind.values.map((k) => k.name).join(', ');

  /// **An unknown key is an error, not a value to ignore** — `cux_ship`'s
  /// `config.dart` policy, for its reason, applied to the file that decides
  /// where a release goes. A misspelt `prodution:` that is quietly skipped is
  /// a destination the train will report as having no production step, which
  /// reads exactly like a destination that deliberately has none.
  static void _checkKeys(YamlMap map, Set<String> known, String where) {
    final unknown =
        map.keys
            .map((key) => '$key')
            .where((key) => !known.contains(key))
            .toList()
          ..sort();
    if (unknown.isEmpty) {
      return;
    }
    throw DestinationTableException(
      '$where has '
      '${unknown.length == 1 ? 'an unknown key' : 'unknown keys'}: '
      '${unknown.join(', ')}\n'
      '    known keys: ${(known.toList()..sort()).join(', ')}',
    );
  }
}
