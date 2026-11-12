// What `--store` resolves to, and what it refuses to resolve.
//
// **The refusals are the subject.** A selection that quietly acts on nothing is
// the shape `docs/design/authpass-on-the-train.md` §3 refuses by name: an
// operator who typed `--store amazon beta` believes a beta reached Amazon, and
// an exit code of 0 tells them it did. The donor already refuses `--prepare`
// for Play rather than ignoring it, and this is that rule over a table.
import 'package:cux_train/cux_train.dart';
import 'package:test/test.dart';

/// A table shaped like the consumer's: two Apple records, a family with a
/// member that is staged only at production, and two console-only rows.
final _table = DestinationTable.parse('''
destinations:
  play:
    internal: {kind: ship, command: "play upload"}
    beta: {kind: ship, command: "play promote --to beta"}
    production: {kind: ship, command: "play promote"}
  appstore:ios:
    internal: {kind: ship, command: "appstore upload"}
    beta: {kind: ship, command: "appstore beta-release"}
    production: {kind: ship, command: "appstore promote"}
  appstore:macos:
    internal: {kind: ship, command: "appstore upload"}
    production: {kind: ship, command: "appstore promote"}
  amazon:
    internal: {kind: run, command: "upload-artifact.sh"}
    production: {kind: manual, console: "https://developer.amazon.com"}
  flathub: {}
''', source: '.cux-train.yaml');

Matcher _refused(String fragment) => throwsA(
  isA<StoreSelectionException>().having(
    (e) => e.message,
    'message',
    contains(fragment),
  ),
);

StoreSelection _resolve(List<String> names, Stage stage) =>
    resolveStores(table: _table, names: names, stage: stage);

void main() {
  group('what a name selects', () {
    test('an exact destination', () {
      final selection = _resolve(['play'], Stage.production);

      expect(selection.acting.map((d) => d.name), ['play']);
      expect(selection.skipped, isEmpty);
      expect(selection.coversEveryDestination, isFalse);
    });

    test('a family selects its members', () {
      final selection = _resolve(['appstore'], Stage.production);

      expect(selection.acting.map((d) => d.name), [
        'appstore:ios',
        'appstore:macos',
      ]);
    });

    test('no name selects every destination', () {
      final selection = _resolve([], Stage.production);

      expect(selection.coversEveryDestination, isTrue);
      // flathub is `none` everywhere, so it is skipped rather than acted on —
      // and it still counts toward covering the table, because the finish rule
      // has to be satisfiable with it declared.
      expect(selection.acting.map((d) => d.name), [
        'play',
        'appstore:ios',
        'appstore:macos',
        'amazon',
      ]);
      expect(selection.skipped.map((d) => d.name), ['flathub']);
    });

    test('a family and one of its members does not act twice', () {
      final selection = _resolve(['appstore', 'appstore:ios'], Stage.internal);

      expect(selection.acting.map((d) => d.name), [
        'appstore:ios',
        'appstore:macos',
      ]);
    });

    test('a repeated name is a typo, not a quantity', () {
      final selection = _resolve(['play', 'play'], Stage.production);

      expect(selection.acting.map((d) => d.name), ['play']);
    });

    test('order is the table’s, not the invocation’s', () {
      // So that two operators who typed the same intent differently read the
      // same report.
      final selection = _resolve(['amazon', 'play'], Stage.internal);

      expect(selection.acting.map((d) => d.name), ['play', 'amazon']);
    });
  });

  group('a stage a destination does not have', () {
    test('is refused by name, and says which stages it does have', () {
      expect(
        () => _resolve(['amazon'], Stage.beta),
        _refused('`amazon` has no `beta` stage'),
      );
      expect(
        () => _resolve(['amazon'], Stage.beta),
        _refused('`internal` and `production`'),
      );
    });

    test('is not refused when one member of the family is staged', () {
      expect(
        () => _resolve(['appstore'], Stage.beta),
        // `appstore:macos` has no beta; `appstore:ios` does, so the family is
        // partial rather than empty and this must NOT refuse.
        returnsNormally,
      );
    });

    test('is refused for a whole family with no member staged', () {
      // One name, several skipped destinations: the sentence's subject is the
      // family that was typed and its verb has to be singular, while the list
      // it names is the members.
      final allUnstaged = DestinationTable.parse('''
destinations:
  appstore:ios:
    production: {kind: ship, command: "appstore promote"}
  appstore:macos:
    production: {kind: ship, command: "appstore promote"}
''', source: '.cux-train.yaml');

      expect(
        () => resolveStores(
          table: allUnstaged,
          names: ['appstore'],
          stage: Stage.beta,
        ),
        _refused(
          '`appstore` has no `beta` stage: `appstore:ios`, `appstore:macos` '
          'declare nothing at that stage.',
        ),
      );
    });

    test(
      'an unnarrowed run over a stage nobody declares reads as a sentence',
      () {
        // The path with no names to put in the subject. The draft said "no
        // destination have no `beta` stage", which is ungrammatical and says the
        // opposite of what it means — and nothing reached it, because every
        // other case here narrows with a name.
        final noBeta = DestinationTable.parse('''
destinations:
  play:
    production: {kind: ship, command: "play promote"}
  amazon:
    production: {kind: manual, console: "https://developer.amazon.com"}
''', source: '.cux-train.yaml');

        expect(
          () => resolveStores(table: noBeta, names: [], stage: Stage.beta),
          _refused(
            'no destination has a `beta` stage: `play`, `amazon` declare '
            'nothing at that stage.',
          ),
        );
      },
    );

    test(
      'a partial family acts on the staged members and reports the rest',
      () {
        final selection = _resolve(['appstore'], Stage.beta);

        expect(selection.acting.map((d) => d.name), ['appstore:ios']);
        expect(selection.skipped.map((d) => d.name), [
          'appstore:macos',
        ], reason: 'a narrowed run must not read as broader than it was');
      },
    );

    test('a destination with no stage at all says so plainly', () {
      expect(
        () => _resolve(['flathub'], Stage.production),
        _refused('no stage at all'),
      );
    });

    test('several names that are all unstaged name all of them', () {
      expect(
        () => _resolve(['amazon', 'flathub'], Stage.beta),
        _refused('`amazon`, `flathub`'),
      );
    });
  });

  group('a name that is not a destination', () {
    test('is refused, with the declared names', () {
      expect(
        () => _resolve(['amazn'], Stage.production),
        _refused('`amazn` is not a destination'),
      );
      expect(
        () => _resolve(['amazn'], Stage.production),
        _refused('`appstore`'),
      );
    });

    test('a bad member of a real family lists that family instead', () {
      // The long list of every declared name is noise when the operator has
      // clearly aimed at one family.
      expect(
        () => _resolve(['appstore:tvos'], Stage.production),
        _refused('`appstore` has `appstore:ios`, `appstore:macos`'),
      );
    });

    test('a platform name is not a destination either', () {
      // The donor refuses these too. With six Android destinations in the real
      // table, guessing which one `android` meant is the thing to avoid.
      expect(
        () => _resolve(['android'], Stage.production),
        _refused('`android` is not a destination'),
      );
    });
  });

  group('coversEveryDestination', () {
    test('is true when every destination is named explicitly', () {
      final selection = _resolve([
        'play',
        'appstore',
        'amazon',
        'flathub',
      ], Stage.production);

      expect(selection.coversEveryDestination, isTrue);
    });

    test('is false when one is missing', () {
      final selection = _resolve([
        'play',
        'appstore',
        'amazon',
      ], Stage.production);

      expect(selection.coversEveryDestination, isFalse);
    });

    test('is not fooled by a repeated name', () {
      // The guard this protects: `--store play play play play play` on a
      // five-row table must not count as five destinations and spend the
      // version tag.
      final selection = _resolve([
        'play',
        'play',
        'play',
        'play',
        'play',
      ], Stage.production);

      expect(selection.acting.map((d) => d.name), ['play']);
      expect(selection.coversEveryDestination, isFalse);
    });
  });
}
