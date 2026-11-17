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
/// Five kinds, and the last two are why the table works for AuthPass at all: a
/// cell nobody can automate is still a row, declared rather than omitted, so
/// the five verbs mean the same thing before anything is automated.
enum StepKind {
  /// The train spawns `cux_ship` through the consumer's shim.
  ship,

  /// The train spawns a script the consumer owns.
  run,

  /// A person acts. The train instructs, waits, and records.
  manual,

  /// Something elsewhere acts, and the train watches for the result.
  ///
  /// **This is §5's remote lane, and it is a kind rather than an absence
  /// because the difference is the whole of `internal`.** AuthPass's CI builds
  /// and uploads fifteen of its nineteen destinations; the train's `internal`
  /// spawns one dispatch and then has nothing left to *do* at those rows —
  /// but something is certainly happening at them, so they are not `none`, and
  /// nobody is being asked to act, so they are not `manual`. What the train
  /// does instead is read, until the destination shows the candidate or the
  /// clock runs out.
  ///
  /// **A `wait` row has to declare `read`**, enforced below: the wait's only
  /// other exit is the timeout, so a wait with nothing to read is an hour of
  /// nothing followed by a `pending` that was never going to be anything else.
  ///
  /// **`internal` only**, also enforced below. The tempting second use is a
  /// production row nobody acts at but whose state can be read — AuthPass's
  /// `flathub`, whose production cell §3 calls "observe only" — and taking it
  /// would hold the version tag until Flathub's bot got around to building,
  /// days later. §6.3 is explicit that the publishing decision there is not the
  /// train's, and §4 makes such a row `none`: satisfied vacuously, observed by
  /// `status` afterwards.
  wait,

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
    this.publicAtInternal = false,
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
  ///
  /// **The contract is one build number on stdout**, and nothing else: exit 0
  /// having printed a number means the destination holds that build, exit 0
  /// having printed nothing means it holds no build this command could see,
  /// and a non-zero exit means the read could not answer — §6.2's `Unreadable`,
  /// which is not evidence about the step. It is deliberately not a document:
  /// every one of AuthPass's reads is a URL and a field, and a schema here
  /// would make each of them a program.
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
  /// Two things follow from it and nothing else does: the finish rule does
  /// not count this destination, and `production` walks it in a second pass,
  /// after the finish step has run. Among themselves, the destinations
  /// declared this way keep declaration order like any others.
  final bool afterFinish;

  /// Whether reaching this destination at `internal` already reaches users.
  ///
  /// **§6.2's one annotation, and it sits beside the mark rather than among
  /// them** because it is a property of the destination's stages and not of
  /// any cell's evidence. AuthPass has three: `web` and `packagecloud` are
  /// public the moment CI finishes, and the snap is on `edge`, which anyone
  /// can install. The donor has none, and whether AuthPass's three *should*
  /// stay that way is §9 item 2 — the train reports it and changes nothing.
  final bool publicAtInternal;

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
  DestinationTable(
    List<Destination> destinations, {
    this.dispatch,
    this.finish,
    Map<Stage, List<DestinationStep>> gates = const {},
  }) : destinations = List.unmodifiable(destinations),
       gates = Map.unmodifiable({
         for (final entry in gates.entries)
           entry.key: List<DestinationStep>.unmodifiable(entry.value),
       });

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
    _checkKeys(document, const {
      'destinations',
      'dispatch',
      'finish',
      'gates',
    }, source);

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
    final table = DestinationTable(
      destinations,
      dispatch: _parseDispatch(document, source),
      finish: _parseFinish(document, source),
      gates: _parseGates(document, source),
    );
    table._checkNamesAreUsable(source);
    return table;
  }

  final List<Destination> destinations;

  /// What has to pass before a release spends anything, in order.
  ///
  /// **§3 step 1, and the placement is the whole value.** `production` opens
  /// with the `pre-release` hook and `release finish --dry-run` so that a
  /// refusal — the wrong branch, a changelog with no section for this
  /// version, a missing F-Droid changelog file — arrives *while it is still
  /// free*. Without them the same refusal arrives from the finish step, after
  /// a person has stood at eleven consoles, and there is nothing to be done
  /// with it but start again tomorrow.
  ///
  /// **The bodies are the consumer's and the contract is not.** §7 puts the
  /// hook *bodies* in the consumer and the hook *contract* here, so this is a
  /// list of commands the train spawns, each of which must exit 0, with
  /// `HOOK_STORES` naming the destinations the run will act on. A gate that
  /// wants to know whether this is a narrowed run reads that.
  ///
  /// **A gate must spend nothing**, because `--dry-run` runs them. A dry run
  /// that skipped the gates could not answer the question §8 step 1 wants a
  /// dry run for — whether this release is ready — and `release finish
  /// --dry-run` is itself a gate of exactly that shape.
  ///
  /// **Keyed by the stage that runs them, and it was a flat list for exactly
  /// one verb.** The argument for the list was that `production` runs every
  /// gate it has in order, so hook names would be documentation the parser
  /// enforced without reading. The second acting verb ended that: §3's
  /// `internal` opens with the `pre-build` hook and `production` with
  /// `pre-release`, and running one table's single list at both would put
  /// `release finish --dry-run` — which refuses anywhere but the release
  /// branch — in front of the dispatch that *creates* the build it is
  /// checking. The names the donor uses are stage names here, which is why
  /// this is a stage key and not a hook name.
  final Map<Stage, List<DestinationStep>> gates;

  /// The gates [stage] runs, in declaration order. Empty where none are
  /// declared, which is the ordinary state.
  List<DestinationStep> gatesAt(Stage stage) => gates[stage] ?? const [];

  /// The one step `internal` performs that is not about a destination.
  ///
  /// **§3's step 2: the push CI reacts to, typed by the train instead of by a
  /// person reading README step 2.** It is top-level rather than a row because
  /// it is not a row: one `git push origin HEAD:stable` is what fifteen of
  /// AuthPass's destinations are built by, and writing it on one of them would
  /// make that destination's turn the thing every other destination depends
  /// on.
  ///
  /// **Optional, and its absence is the donor's shape rather than a gap.** A
  /// consumer whose `internal` builds locally at each destination — the donor
  /// itself, with `build.sh` and `upload.sh` per platform — has nothing to
  /// dispatch and declares none; `internal` then walks its rows and, with no
  /// `wait` rows either, has nothing to wait for.
  ///
  /// **Idempotence is the command's business, not the train's.** There is no
  /// `dispatched/` record: pushing the same commit twice is a no-op, and what
  /// a re-run would otherwise skip is the one step that makes the next wait
  /// mean anything.
  final DestinationStep? dispatch;

  /// The step that spends the version tag, once the finish rule is met.
  ///
  /// **Optional, and a table without one cannot finish a release.** §3 step 5
  /// names it as `cux_ship release finish`, which writes `vX.Y.Z` under the
  /// consumer's configured namespace — so the train spawns a command it is
  /// given rather than composing a tag name. Guessing `v$version` here would
  /// be the same mistake as reading the release out of an `uploaded/` tag:
  /// inventing somebody else's convention and being wrong silently wherever
  /// they spell it differently.
  ///
  /// `production` says so when it is absent, rather than treating a release
  /// with every destination recorded as finished.
  final DestinationStep? finish;

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
      'public-at-internal',
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

    final read = _optionalString(value, 'read', where);
    _checkWaits(steps, read, where);

    return Destination(
      name: name,
      // **Unmodifiable, as `DestinationTable.destinations` is.** A parsed
      // destination is what `--store` resolves over, and a caller that could
      // put a step into this map could make the train act on a destination at
      // a stage the consumer never declared.
      steps: Map.unmodifiable(steps),
      read: read,
      identity: _parseIdentity(value['identity'], where),
      afterFinish: _parseStageFlag(
        value,
        steps,
        where,
        key: 'after-finish',
        stage: Stage.production,
        // It excludes a destination from the finish rule, and one with no
        // production step is already excluded — vacuously, because nothing
        // writes a record for it.
        pointless: 'the finish rule already does not wait on it',
      ),
      publicAtInternal: _parseStageFlag(
        value,
        steps,
        where,
        key: 'public-at-internal',
        stage: Stage.internal,
        // Nobody acts at internal, so nothing this release does can make it
        // public there.
        pointless: 'nothing this release does reaches it at that stage',
      ),
    );
  }

  /// **A `wait` step belongs to `internal`, and needs something to read.**
  ///
  /// Both rules are [StepKind.wait]'s doc comment made enforceable, and both
  /// are about a table that would otherwise parse and then behave as if the
  /// row said something else. A `wait` at `beta` or `production` reaches a
  /// walk that has no case for it; a `wait` with no `read` reaches a loop
  /// whose only remaining exit is the timeout, which is an hour spent
  /// producing the `pending` it started with.
  static void _checkWaits(
    Map<Stage, DestinationStep> steps,
    String? read,
    String where,
  ) {
    for (final entry in steps.entries) {
      if (entry.value.kind != StepKind.wait) {
        continue;
      }
      if (entry.key != Stage.internal) {
        throw DestinationTableException(
          '$where is `wait` at `${entry.key.name}`, and only `internal` '
          'dispatches and waits. A destination nobody acts at but whose state '
          'can be read is `none` here and is read by `status` afterwards — '
          'waiting for it at ${entry.key.name} would hold the release open '
          'for however long somebody else takes.',
        );
      }
      if (read == null) {
        throw DestinationTableException(
          '$where is `wait` at `internal` and declares no `read`. The wait '
          'ends when the destination shows the build or when the clock runs '
          'out, so with nothing to read it can only ever end the second way.',
        );
      }
    }
  }

  /// **A flag about a stage is only meaningful where somebody acts at it.**
  ///
  /// Both of these annotate what happens at one stage, and on a row where
  /// nobody acts there, each says nothing — a key that does nothing is read by
  /// the next person as doing something. The likeliest way to write one is to
  /// mark the right destination and then delete its step, which is exactly the
  /// case worth being told about rather than left to read correctly.
  static bool _parseStageFlag(
    YamlMap value,
    Map<Stage, DestinationStep> steps,
    String where, {
    required String key,
    required Stage stage,
    required String pointless,
  }) {
    if (!value.containsKey(key)) {
      return false;
    }
    final declared = value[key];
    if (declared is! bool) {
      throw DestinationTableException(
        '$where: `$key` must be true or false, and YAML read '
        '`$declared` as ${declared == null ? 'null' : declared.runtimeType}',
      );
    }
    final step = steps[stage] ?? DestinationStep.absent;
    if (declared && step.kind == StepKind.none) {
      throw DestinationTableException(
        '$where is `$key` but nobody acts at `${stage.name}` — $pointless',
      );
    }
    return declared;
  }

  /// The optional top-level `gates:` map, stage to steps in order.
  ///
  /// **The stage is the key, and the first draft had one flat list**, on the
  /// argument that `production` runs every gate it has so a key would be
  /// documentation the parser enforced without reading. That argument was true
  /// of one verb and false of two: §3 gives `internal` a `pre-build` gate and
  /// `production` a `pre-release` one, and a single list would hand each verb
  /// the other's. Within a stage it is still a list, because the order is the
  /// consumer's — a `pre-release` hook and a `release finish --dry-run` go in
  /// whichever order refuses soonest.
  ///
  /// Each entry is a step, and each has to spawn: `manual` would be asking a
  /// person to assert a gate the train could check, and `none` would be a gate
  /// that passes by being empty — which is the one thing a gate must never do.
  static Map<Stage, List<DestinationStep>> _parseGates(
    YamlMap document,
    String source,
  ) {
    final declared = document['gates'];
    if (declared == null) {
      // **Absent and empty are the same here, unlike a stage.** A table with
      // no gates is the ordinary state — §8 step 1's table has none, and the
      // hook bodies are the consumer's to write later — so this is not the
      // "written and left empty" case `_parseDestination` refuses.
      return const {};
    }
    if (declared is YamlList) {
      // **The shape that used to be right gets its own sentence.** A list is
      // what the released schema took, and the generic "must be a map" would
      // send somebody who wrote a working table off to find a typo.
      throw DestinationTableException(
        '$source: `gates` is a list, and gates are now keyed by the stage '
        'that runs them — `gates: {production: [...]}`. One list cannot serve '
        'both verbs: `internal` runs its gates before the build exists and '
        '`production` runs its own before the release does.',
      );
    }
    if (declared is! YamlMap) {
      throw DestinationTableException(
        '$source: `gates` must be a map of stage to a list of steps, each '
        'with a command that has to pass before that stage spends anything',
      );
    }
    if (declared.isEmpty) {
      throw DestinationTableException(
        '$source: `gates` is empty. A gate that checks nothing passes always, '
        'which is the one thing a gate must not do — leave the key out '
        'instead.',
      );
    }
    final gates = <Stage, List<DestinationStep>>{};
    for (final entry in declared.entries) {
      final key = entry.key;
      final stage = key is String ? Stage.byName(key) : null;
      if (stage == null) {
        throw DestinationTableException(
          '$source: `gates` is keyed by stage, and `${entry.key}` is not one '
          '— expected ${Stage.values.map((it) => it.name).join(', ')}. '
          '`status` and `ready` spend nothing, so neither has a gate to run.',
        );
      }
      final steps = entry.value;
      if (steps is! YamlList || steps.isEmpty) {
        throw DestinationTableException(
          '$source: `gates.${stage.name}` must be a non-empty list of steps. '
          'A stage keyed with nothing under it is a gate that passes by being '
          'empty — leave the key out instead.',
        );
      }
      gates[stage] = [
        for (var i = 0; i < steps.length; i++)
          _checkedGate(steps[i], '$source: `gates.${stage.name}[$i]`'),
      ];
    }
    return gates;
  }

  /// One gate: a step, which has to be one that spawns.
  static DestinationStep _checkedGate(Object? declared, String where) {
    final step = _parseStep(declared, where);
    if (!step.kind.spawns) {
      throw DestinationTableException(
        '$where is `${step.kind.name}`, and a gate has to run something. A '
        '`manual` gate asks a person to assert what the train could check, '
        'and a `none` gate passes by being empty.',
      );
    }
    return step;
  }

  /// The optional top-level `dispatch:` step.
  ///
  /// **It has to spawn something**, for `finish`'s reason in another place: a
  /// `manual` dispatch would be instructing a person to push a branch the
  /// train could push and then believing them about it, and a `none` dispatch
  /// is a table that declares a dispatch and has none.
  static DestinationStep? _parseDispatch(YamlMap document, String source) {
    if (!document.containsKey('dispatch')) {
      return null;
    }
    final declared = document['dispatch'];
    if (declared == null) {
      throw DestinationTableException(
        '$source declares `dispatch` with nothing in it — give it a `ship` or '
        '`run` command, or leave the key out',
      );
    }
    final step = _parseStep(declared, '$source: `dispatch`');
    if (!step.kind.spawns) {
      throw DestinationTableException(
        '$source: `dispatch` is `${step.kind.name}`, and the dispatch is the '
        'command that sets the build going — it has to run something. Give it '
        'a `ship` or `run` command, or leave `dispatch` out.',
      );
    }
    return step;
  }

  /// The optional top-level `finish:` step.
  ///
  /// **It has to spawn something.** `manual` would mean instructing a person
  /// to write the version tag by hand, and the train would then be believing
  /// them about a tag it can see for itself; `none` would mean a table that
  /// declares a finish and has none. Both say more than they mean, so each is
  /// refused by name.
  static DestinationStep? _parseFinish(YamlMap document, String source) {
    if (!document.containsKey('finish')) {
      return null;
    }
    // **Absent is no finish; written-and-left-empty is a mistake** — the rule
    // a stage key follows in `_parseDestination`, for the same reason. A bare
    // `finish:` is a body deleted mid-edit, and reading it as absent would
    // have `production` say the table declares none of a key its author can
    // see in the file.
    final declared = document['finish'];
    if (declared == null) {
      throw DestinationTableException(
        '$source declares `finish` with nothing in it — give it a `ship` or '
        '`run` command, or leave the key out',
      );
    }
    final step = _parseStep(declared, '$source: `finish`');
    if (!step.kind.spawns) {
      throw DestinationTableException(
        '$source: `finish` is `${step.kind.name}`, and finishing a release '
        'has to run something — it is the step that spends the version tag. '
        'Give it a `ship` or `run` command, or leave `finish` out.',
      );
    }
    return step;
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
