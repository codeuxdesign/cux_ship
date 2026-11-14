// What a run asks of the record: what is left, and whether finish may happen.
//
// **The table shape here is AuthPass's, narrowed to the rows that exercise a
// rule**: a destination nobody acts at (`web`), one ordered after the version
// tag (`fdroid`), a family whose members are recorded separately, and a
// console that can refuse.
import 'package:cux_train/cux_train.dart';
import 'package:test/test.dart';

final _table = DestinationTable.parse('''
destinations:
  play:
    production: {kind: ship, command: "play promote"}
  appstore:ios:
    production: {kind: ship, command: "appstore promote"}
  appstore:macos:
    production: {kind: ship, command: "appstore promote"}
  huawei:
    production: {kind: manual, console: "https://developer.huawei.com"}
  web:
    production: none
  fdroid:
    after-finish: true
    production: {kind: run, command: "_tools/release/fdroid-tag.sh"}
''', source: '.cux-train.yaml');

PromotionLedger _ledger(List<String> refs, {int build = 2196}) =>
    PromotionLedger.forBuild(refs, build: build, source: 'refs/tags');

List<String> _waitingOn(PromotionLedger ledger) => finishRule(
  table: _table,
  ledger: ledger,
).waitingOn.map((d) => d.name).toList();

void main() {
  group('reading the ledger', () {
    test('keeps only the build it was asked for', () {
      // The namespace holds every release ever made, so "is huawei recorded?"
      // is meaningless without naming the build. §2 names the candidate rather
      // than inferring it, and this is that discipline one layer down.
      final ledger = _ledger([
        'promoted/huawei/production/v1.9.12+2007',
        'promoted/huawei/production/v1.9.13+2196',
      ]);

      expect(ledger.records, hasLength(1));
      expect(ledger.records.single.version, '1.9.13');
      expect(ledger.isHandedOver('huawei', Stage.production), isTrue);
    });

    test('a stray ref is an error, not a skip', () {
      // The caller globbed the namespaces, so everything it passes is already
      // claimed to be a record. Skipping one would under-count exactly what
      // the finish rule counts.
      expect(
        () => _ledger(['promoted/huawei/production/v1.9.13+2196', 'nonsense']),
        throwsA(isA<PromotionRecordException>()),
      );
    });

    test('tells one stage from another', () {
      final ledger = _ledger(['promoted/play/beta/v1.9.13+2196']);

      expect(ledger.isHandedOver('play', Stage.beta), isTrue);
      expect(ledger.isHandedOver('play', Stage.production), isFalse);
    });

    test('tells one member of a family from another', () {
      final ledger = _ledger(['promoted/appstore/ios/production/v1.9.13+2196']);

      expect(ledger.isHandedOver('appstore:ios', Stage.production), isTrue);
      expect(ledger.isHandedOver('appstore:macos', Stage.production), isFalse);
    });
  });

  group('a refusal', () {
    test('is not handed over, so the destination comes up again', () {
      // The whole point of `f` over `s`: a console that rejected the binary
      // must not read as one nobody has looked at, but it is still not done.
      final ledger = _ledger(['refused/huawei/production/v1.9.13+2196']);

      expect(ledger.isHandedOver('huawei', Stage.production), isFalse);
      expect(
        ledger.recordFor('huawei', Stage.production)!.outcome,
        PromotionOutcome.attemptedAndRefused,
      );
    });

    test('wins over a hand-over for the same cell, whichever order', () {
      // Both can exist and ref names carry no time. Returning the worse of
      // the two stops the run at the destination and shows a human both refs,
      // rather than walking past a cell in a state nobody intended.
      for (final refs in [
        [
          'promoted/huawei/production/v1.9.13+2196',
          'refused/huawei/production/v1.9.13+2196',
        ],
        [
          'refused/huawei/production/v1.9.13+2196',
          'promoted/huawei/production/v1.9.13+2196',
        ],
      ]) {
        final ledger = _ledger(refs);

        expect(
          ledger.recordFor('huawei', Stage.production)!.outcome,
          PromotionOutcome.attemptedAndRefused,
          reason: refs.first,
        );
        expect(ledger.isHandedOver('huawei', Stage.production), isFalse);
      }
    });
  });

  group('what is left to do', () {
    test('is everything on a run that has recorded nothing', () {
      final acting = resolveStores(
        table: _table,
        names: [],
        stage: Stage.production,
      ).acting;

      expect(
        _ledger([]).outstanding(acting, Stage.production).map((d) => d.name),
        ['play', 'appstore:ios', 'appstore:macos', 'huawei', 'fdroid'],
      );
    });

    test('skips what is recorded and keeps the table order', () {
      // §3: a re-run picks up at the first destination that is not recorded.
      final acting = resolveStores(
        table: _table,
        names: [],
        stage: Stage.production,
      ).acting;
      final ledger = _ledger([
        'promoted/play/production/v1.9.13+2196',
        'promoted/appstore/ios/production/v1.9.13+2196',
      ]);

      expect(ledger.outstanding(acting, Stage.production).map((d) => d.name), [
        'appstore:macos',
        'huawei',
        'fdroid',
      ]);
    });
  });

  group('the finish rule', () {
    test('waits on every destination that has a production step', () {
      expect(_waitingOn(_ledger([])), [
        'play',
        'appstore:ios',
        'appstore:macos',
        'huawei',
      ]);
    });

    test('is satisfied vacuously by a destination nobody acts at', () {
      // `web` is `none`: nothing writes a record, so waiting for one would
      // hold the version tag forever.
      expect(_waitingOn(_ledger([])), isNot(contains('web')));
    });

    test('does not wait on a destination ordered after finish', () {
      // `fdroid` pushes `fdroid-vX.Y.Z`, which cannot precede the `vX.Y.Z` it
      // annotates — it is the one destination finish does not wait on, and it
      // is still outstanding work for the run.
      expect(_waitingOn(_ledger([])), isNot(contains('fdroid')));
    });

    test('is satisfied once the rest are recorded, however narrowly', () {
      // The donor keyed this on whether `--store` named everything, which a
      // `production` spanning days can never satisfy: the operator finishing
      // the last console with `--store huawei production` would never be
      // allowed to spend the tag.
      final ledger = _ledger([
        'promoted/play/production/v1.9.13+2196',
        'promoted/appstore/ios/production/v1.9.13+2196',
        'promoted/appstore/macos/production/v1.9.13+2196',
        'promoted/huawei/production/v1.9.13+2196',
      ]);

      expect(finishRule(table: _table, ledger: ledger).isSatisfied, isTrue);
    });

    test('is not satisfied by a refusal', () {
      final ledger = _ledger([
        'promoted/play/production/v1.9.13+2196',
        'promoted/appstore/ios/production/v1.9.13+2196',
        'promoted/appstore/macos/production/v1.9.13+2196',
        'refused/huawei/production/v1.9.13+2196',
      ]);

      expect(finishRule(table: _table, ledger: ledger).isSatisfied, isFalse);
      expect(_waitingOn(ledger), ['huawei']);
    });

    test('counts the build it was given, not the newest record', () {
      final ledger = _ledger([
        'promoted/play/production/v1.9.12+2007',
        'promoted/appstore/ios/production/v1.9.12+2007',
        'promoted/appstore/macos/production/v1.9.12+2007',
        'promoted/huawei/production/v1.9.12+2007',
      ]);

      expect(finishRule(table: _table, ledger: ledger).isSatisfied, isFalse);
    });
  });

  group('`after-finish` in the table', () {
    test('is refused where nobody acts at production', () {
      // The likeliest way to write it is to mark the right destination and
      // then delete its step; the key would then quietly do nothing.
      expect(
        () => DestinationTable.parse('''
destinations:
  fdroid:
    after-finish: true
    production: none
''', source: '.cux-train.yaml'),
        throwsA(
          isA<DestinationTableException>().having(
            (e) => e.message,
            'message',
            contains('nobody acts at `production`'),
          ),
        ),
      );
    });

    test('must be a boolean', () {
      expect(
        () => DestinationTable.parse('''
destinations:
  fdroid:
    after-finish: "yes"
    production: {kind: run, command: x}
''', source: '.cux-train.yaml'),
        throwsA(
          isA<DestinationTableException>().having(
            (e) => e.message,
            'message',
            contains('`after-finish` must be true or false'),
          ),
        ),
      );
    });

    test('defaults to false', () {
      expect(_table.byName('play')!.afterFinish, isFalse);
      expect(_table.byName('fdroid')!.afterFinish, isTrue);
    });

    test('may be written as false where nobody acts at production', () {
      // The refusal is for a key that claims something and does nothing. An
      // explicit `false` claims nothing, so it is the default spelt out.
      final table = DestinationTable.parse('''
destinations:
  web:
    after-finish: false
    production: none
  play:
    production: {kind: ship, command: "play promote"}
''', source: '.cux-train.yaml');

      expect(table.byName('web')!.afterFinish, isFalse);
    });
  });
}
