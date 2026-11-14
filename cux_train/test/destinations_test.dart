// What the destination table accepts, and what it refuses.
//
// **Every case here is about a refusal or about a default**, because those are
// the two ways a table can be wrong in a way nobody notices until a release.
// A table that parses and means something slightly different from what its
// author wrote is the failure `docs/design/authpass-on-the-train.md` §6 calls
// *not being able to tell* — the train reports a destination as handled and
// the store never heard from it.
//
// The happy path is asserted once, at the top, and then only deviations.
import 'package:cux_train/cux_train.dart';
import 'package:test/test.dart';

DestinationTable _parse(String yaml) =>
    DestinationTable.parse(yaml, source: '.cux-train.yaml');

Matcher _refused(String fragment) => throwsA(
  isA<DestinationTableException>().having(
    (e) => e.message,
    'message',
    contains(fragment),
  ),
);

void main() {
  group('a table that means what it says', () {
    test('reads kinds, commands, identity and reads', () {
      final table = _parse('''
destinations:
  play:
    identity:
      package: design.codeux.authpass
    internal: {kind: ship, command: "play upload --track internal"}
    beta: {kind: ship, command: "play promote --to beta"}
    production: {kind: ship, command: "play promote"}
    read: "play version-code --package design.codeux.authpass"
  amazon:
    internal: {kind: run, command: "_tools/upload-artifact.sh"}
    beta: none
    production:
      kind: manual
      console: "https://developer.amazon.com/apps-and-games"
      note: "the amazon keystore build, not the playstore one"
''');

      final play = table.byName('play')!;
      expect(play.stepAt(Stage.production).kind, StepKind.ship);
      expect(play.stepAt(Stage.production).command, 'play promote');
      expect(play.identity['package'], 'design.codeux.authpass');
      expect(play.read, 'play version-code --package design.codeux.authpass');

      final amazon = table.byName('amazon')!;
      expect(amazon.stepAt(Stage.internal).kind, StepKind.run);
      expect(amazon.stepAt(Stage.beta).kind, StepKind.none);
      expect(amazon.stepAt(Stage.production).kind, StepKind.manual);
      expect(amazon.stepAt(Stage.production).console, contains('amazon.com'));
      expect(amazon.read, isNull, reason: 'a console nobody can read');
    });

    test('an omitted stage is `none`, not an error', () {
      // The deliberate asymmetry with the unknown-key policy: fifty-seven
      // cells, most of them nobody-acts, and a table whose rows must all be
      // written out is a table whose rows get copied instead of read.
      final table = _parse('''
destinations:
  fosshub:
    production: {kind: run, command: "_tools/release/fosshub-release.sh"}
''');

      final fosshub = table.byName('fosshub')!;
      expect(fosshub.stepAt(Stage.internal).kind, StepKind.none);
      expect(fosshub.stepAt(Stage.beta).kind, StepKind.none);
      expect(fosshub.stepAt(Stage.production).kind, StepKind.run);
    });

    test('hands out nothing a caller can edit under it', () {
      // A parsed destination is what `--store` resolves over, so a caller that
      // could put a step into `steps` could make the train act on a
      // destination at a stage the consumer never declared — and the table
      // would still report the file it read.
      final table = _parse('''
destinations:
  play:
    identity: {package: design.codeux.authpass}
    production: {kind: ship, command: "play promote"}
''');
      final play = table.byName('play')!;

      expect(
        () => play.steps[Stage.beta] = const DestinationStep(
          kind: StepKind.ship,
          command: 'play promote --to beta',
        ),
        throwsUnsupportedError,
      );
      expect(() => play.identity['package'] = 'other', throwsUnsupportedError);
      expect(
        () => table.destinations.add(play),
        throwsUnsupportedError,
        reason: 'the list already held this',
      );
    });

    test('splits `family:member` and groups the family', () {
      final table = _parse('''
destinations:
  appstore:ios:
    production: {kind: ship, command: "appstore promote"}
  appstore:macos:
    production: {kind: ship, command: "appstore promote"}
  play:
    production: {kind: ship, command: "play promote"}
''');

      expect(table.byName('appstore:ios')!.family, 'appstore');
      expect(table.byName('appstore:ios')!.member, 'ios');
      expect(table.byName('play')!.family, isNull);
      expect(table.membersOf('appstore').map((d) => d.name), [
        'appstore:ios',
        'appstore:macos',
      ]);
      expect(table.familyNames, ['appstore']);
    });
  });

  group('refusals', () {
    test('an unknown key at any level, naming it and the known ones', () {
      // `cux_ship`'s config policy, for its reason: a misspelt `prodution:`
      // that is skipped is indistinguishable from a destination that
      // deliberately has no production step.
      expect(
        () => _parse('''
destinations:
  play:
    prodution: {kind: ship, command: "play promote"}
'''),
        _refused('unknown key: prodution'),
      );
      // The second half of this test's name: the message lists what the key
      // could have been, so the operator does not have to go and find the
      // spelling.
      expect(
        () => _parse('''
destinations:
  play:
    prodution: {kind: ship, command: "play promote"}
'''),
        _refused(
          'known keys: after-finish, beta, identity, internal, production, '
          'public-at-internal, read',
        ),
      );
      // And it names the file, as every other refusal here does — this one is
      // the level where the filename was being dropped.
      expect(
        () => _parse('''
destinations:
  play:
    prodution: {kind: ship, command: "play promote"}
'''),
        _refused('.cux-train.yaml: destination `play` has an unknown key'),
      );
      expect(
        () => _parse('''
destinations:
  play:
    production: {kind: ship, comand: "play promote"}
'''),
        _refused('unknown key: comand'),
      );
      expect(
        () => _parse('''
destinations:
  play:
    production: {kind: ship, command: "play promote"}
stores: {}
'''),
        _refused('unknown key: stores'),
      );
    });

    test('a `ship` or `run` step with no command', () {
      // A step that spawns nothing would be reported as done.
      for (final kind in ['ship', 'run']) {
        expect(
          () => _parse('''
destinations:
  play:
    production: {kind: $kind}
'''),
          _refused('needs a `command`'),
          reason: kind,
        );
      }
    });

    test('a `none` or `manual` step carrying a command', () {
      // The mirror case: a command somebody wrote expecting it to run.
      for (final kind in ['none', 'manual']) {
        expect(
          () => _parse('''
destinations:
  play:
    production: {kind: $kind, command: "play promote"}
'''),
          _refused('which nothing would run'),
          reason: kind,
        );
      }
    });

    test('a console on a step no person performs', () {
      expect(
        () => _parse('''
destinations:
  play:
    production:
      kind: ship
      command: "play promote"
      console: "https://play.google.com/console"
'''),
        _refused('only a `manual` step shows anyone'),
      );
    });

    test('a kind that is not a kind', () {
      expect(
        () => _parse('''
destinations:
  play:
    production: shp
'''),
        _refused('not a step kind'),
      );
      expect(
        () => _parse('''
destinations:
  play:
    production: {kind: shp, command: x}
'''),
        _refused('not one of'),
      );
      // A kind that was written but is not a string is not a *missing* kind —
      // "needs a `kind`" would send the operator looking for a line they can
      // see.
      expect(
        () => _parse('''
destinations:
  play:
    production: {kind: 7, command: x}
'''),
        _refused('has kind `7`, which is not one of'),
      );
      expect(
        () => _parse('''
destinations:
  play:
    production: {command: x}
'''),
        _refused('needs a `kind`'),
      );
    });

    test('a name that could not be typed after --store', () {
      for (final name in ['Play', 'play store', 'play_store', 'a:b:c']) {
        expect(
          () => _parse('''
destinations:
  "$name":
    production: {kind: run, command: x}
'''),
          _refused(name == 'a:b:c' ? 'more than one colon' : 'not usable'),
          reason: name,
        );
      }
    });

    test('a destination whose name is also a family', () {
      // `--store direct` could mean the one destination or the four members,
      // and whichever lookup ran first would decide it silently.
      expect(
        () => _parse('''
destinations:
  direct:
    production: {kind: run, command: x}
  direct:macos:
    production: {kind: run, command: y}
'''),
        _refused('could mean either'),
      );
    });

    test('an empty or absent `destinations`', () {
      // Three different mistakes, three different messages — a declared but
      // empty table, a file with no table at all, and a table that is not a
      // map. Collapsing the last two was a real defect in the first draft:
      // "must be a map of name to destination" sent an operator to look at a
      // key they had not written.
      // The fragments have to differ, or this case cannot tell the three
      // messages apart: `contains('is empty')` matches both the empty table
      // and the empty file, which is the collapse the case exists to refuse.
      expect(
        () => _parse('destinations: {}'),
        _refused('`destinations` is empty, so there is nothing to release to'),
      );
      expect(() => _parse('{}'), _refused('must be a map with a'));
      expect(() => _parse(''), _refused('.cux-train.yaml is empty'));
      expect(
        () => _parse('destinations: [play, amazon]'),
        _refused('must be a map of name to destination'),
      );
    });

    test('a destination that is not a map at all', () {
      // Without this guard the stage lookup goes to a String or a YamlList and
      // the operator gets a TypeError instead of the line to open. A body left
      // empty is the same refusal, which is worth pinning: `play: {}` is a
      // destination with no stages, `play:` is a mistake.
      for (final body in ['ship', '[internal, production]', '']) {
        expect(
          () => _parse('''
destinations:
  play: $body
'''),
          _refused('destination `play` must be a map'),
          reason: 'body `$body`',
        );
      }
    });

    test('identity that is not a map', () {
      expect(
        () => _parse('''
destinations:
  play:
    identity: [package]
    production: {kind: run, command: x}
'''),
        _refused('`identity` must be a map'),
      );
    });

    test('identity and read values that are not usable strings', () {
      expect(
        () => _parse('''
destinations:
  play:
    identity: {package: 7}
    production: {kind: run, command: x}
'''),
        _refused('`identity.package` must be a non-empty string'),
      );
      expect(
        () => _parse('''
destinations:
  play:
    read: ""
    production: {kind: run, command: x}
'''),
        _refused('`read` must be a non-empty string'),
      );
    });

    test('names the file it was handed, not a guess', () {
      // The reader is an operator mid-release who needs to know which file to
      // open — and §4 of the plan leaves the filename unsettled, so the
      // parser must not have an opinion about it.
      expect(
        () => DestinationTable.parse('destinations: {}', source: 'elsewhere'),
        _refused('elsewhere:'),
      );
    });

    test('a name YAML did not read as text', () {
      // The failure this prevents is not a crash but a plausible wrong
      // answer: stringifying the key gives `~` the name `null` and `true` the
      // name `true`, both of which pass the name pattern, so `--store null`
      // would select a destination nobody declared.
      for (final key in ['~', 'true', '7']) {
        expect(
          () => _parse('''
destinations:
  $key:
    production: {kind: run, command: x}
'''),
          _refused('a destination name must be text'),
          reason: 'key `$key`',
        );
      }
      // Quoted, the same three are ordinary names — the refusal is about how
      // YAML read the key, not about the characters in it.
      expect(
        _parse('''
destinations:
  "true":
    production: {kind: run, command: x}
''').byName('true'),
        isNotNull,
      );
    });

    test('an identity key YAML did not read as text', () {
      expect(
        () => _parse('''
destinations:
  play:
    identity: {~: design.codeux.authpass}
    production: {kind: run, command: x}
'''),
        _refused('an `identity` key must be text'),
      );
    });

    test('a stage written and left empty, which is not the same as absent', () {
      // `beta: none` is how an author says nobody acts, so a bare `beta:` is a
      // body deleted or a step commented out mid-edit. Refusing it is the one
      // place the stage default does not apply, and it keeps this level in
      // agreement with the one above, where `play:` with no body is refused
      // too.
      for (final stage in ['internal', 'beta', 'production']) {
        // The filled stage has to be a different one: writing the stage under
        // test twice is a duplicate mapping key, which the YAML parser refuses
        // before this guard is reached.
        final filled = stage == 'production' ? 'internal' : 'production';
        expect(
          () => _parse('''
destinations:
  play:
    $filled: {kind: run, command: x}
    $stage:
'''),
          _refused('declares `$stage` with nothing in it'),
          reason: stage,
        );
      }
      // And the key being gone is still the documented default.
      expect(
        _parse('''
destinations:
  play:
    production: {kind: run, command: x}
''').byName('play')!.stepAt(Stage.beta).kind,
        StepKind.none,
      );
    });
  });

  group('Stage.byName', () {
    // Null rather than a throw is what lets a caller tell "not a stage" from
    // "a stage I cannot serve" and say which. Pinned here because the caller
    // is a later commit: untested, it is the live counterpart of the dead
    // guards the mutation run removed.
    test('answers for every stage and null for anything else', () {
      for (final stage in Stage.values) {
        expect(Stage.byName(stage.name), stage, reason: stage.name);
      }
      for (final name in ['internl', 'INTERNAL', 'ready', 'status', '']) {
        expect(Stage.byName(name), isNull, reason: name);
      }
    });
  });
}
