// What `ready` answers, and what it refuses to answer.
//
// **The table here is AuthPass's narrowed to the rows that change an answer**:
// a console that can refuse, a second console that cannot be read either way,
// a destination ordered after the version tag, and one nobody acts on at
// production at all. Every case below turns on one of those four shapes.
import 'package:cux_train/cux_train.dart';
import 'package:test/test.dart';

final _table = DestinationTable.parse('''
destinations:
  play:
    production: {kind: ship, command: "cux_ship play promote"}
  huawei:
    production: {kind: manual, console: "https://developer.huawei.com"}
  web:
    internal: {kind: run, command: "deploy.sh"}
    production: none
  fdroid:
    after-finish: true
    production: {kind: run, command: "_tools/fdroid-tag.sh"}
''', source: '.cux-train.yaml');

Readiness _readiness(
  List<String> refs, {
  DestinationTable? table,
  int build = 2196,
  String version = '1.9.13',
}) => Readiness.of(
  table: table ?? _table,
  ledger: PromotionLedger.forBuild(
    refs,
    build: build,
    version: version,
    source: 'refs/tags',
  ),
  version: version,
  candidate: build,
);

/// [report] with its line breaks folded away.
///
/// **Prose in the report is wrapped, so a claim about what it says has to be
/// made over the words and not over the lines.** `pre-release hook` is the one
/// that caught it: the phrase is correct, printed, and split in two by the
/// margin. The layout has its own case below, which is where a line break
/// should fail a test.
String _flat(String report) => report.replaceAll(RegExp(r'\s+'), ' ');

void main() {
  group('the verdict', () {
    test('nothing recorded is the normal day, not a problem', () {
      // The first run of a release reaches `ready` with an empty namespace,
      // and "nothing recorded" is the whole of the work `production` is about
      // to do.
      final readiness = _readiness([]);

      expect(readiness.warnings, isEmpty);
      expect(readiness.outstanding.map((it) => it.name), [
        'play',
        'huawei',
        'fdroid',
      ]);
    });

    test('everything recorded still leaves the version tag', () {
      // **An empty outstanding list is not a no.** `production` has one step
      // left — the version tag — and an answer of "not ready" would send an
      // operator away from the only thing left to do.
      final readiness = _readiness([
        'promoted/play/production/v1.9.13+2196',
        'promoted/huawei/production/v1.9.13+2196',
        'promoted/fdroid/production/v1.9.13+2196',
      ]);

      expect(readiness.warnings, isEmpty);
      expect(readiness.outstanding, isEmpty);
      expect(readiness.finish.isSatisfied, isTrue);
      expect(
        _flat(readiness.render()),
        contains('all that is left is the version tag'),
      );
      // The verdict has said it; a heading over no rows would say "it would
      // act on 0 of 3" and end in a colon.
      expect(_flat(readiness.render()), isNot(contains('it would act on')));
    });

    test('a refusal warns, and is never a reason to hold production', () {
      // **The case this file exists for, and the first version of it asserted
      // the opposite.** §6.1 records a refusal *so that* the next
      // `production` run stops at that destination again — `f` exists because
      // `s` alone makes "the console rejected the binary" look like "nobody
      // has looked yet". A verb that refused to proceed on one would be
      // standing between the operator and the retry.
      final readiness = _readiness(['refused/huawei/production/v1.9.13+2196']);

      expect(readiness.warnings, hasLength(1));
      expect(readiness.warnings.single.destination, 'huawei');
      expect(
        readiness.warnings.single.detail,
        contains('refused/huawei/production/v1.9.13+2196'),
      );
      // Still work to do, and the work list still names it: `production` is
      // how the refusal is retried.
      expect(readiness.outstanding.map((it) => it.name), contains('huawei'));
      expect(_flat(readiness.render()), contains('production could run.'));
    });

    test('a refusal the console later accepted still only warns', () {
      // **What made the first version permanent as well as backwards.**
      // Nothing clears a refusal and `recordFor` lets one win over a later
      // hand-over, so a `ready` that failed here failed for the life of the
      // build — with `ready && production`, one `f` on Monday stopped that
      // release for good, the five untouched consoles included.
      final readiness = _readiness([
        'refused/huawei/production/v1.9.13+2196',
        'promoted/huawei/production/v1.9.13+2196',
      ]);

      expect(readiness.warnings, hasLength(1));
      expect(_flat(readiness.render()), contains('production could run'));
    });

    test('counts a refusal as work still outstanding, not as work done', () {
      // `isHandedOver` is false for a refusal, which is what makes the
      // destination come up again on the next run.
      final readiness = _readiness(['refused/huawei/production/v1.9.13+2196']);

      expect(readiness.outstanding.map((it) => it.name), contains('huawei'));
      expect(readiness.finish.waitingOn.map((it) => it.name), [
        'play',
        'huawei',
      ]);
    });

    test('a refusal at another stage does not warn about production', () {
      // Reading the namespace rather than the stage would carry every
      // historical rejection into a report about a stage it says nothing
      // about.
      final readiness = _readiness(['refused/huawei/internal/v1.9.13+2196']);

      expect(readiness.warnings, isEmpty);
    });

    test('a refusal at another build is not this run\'s', () {
      // The ledger drops it before this file sees it; the case is here
      // because the alternative — a build filter that reached for the
      // namespace instead — would look identical until a second release.
      final readiness = _readiness(['refused/huawei/production/v1.9.12+2007']);

      expect(readiness.warnings, isEmpty);
    });
  });

  group('what it refuses to answer', () {
    test('a table with no production step at all', () {
      // Reused from `resolveStores` rather than restated. A table whose every
      // production cell is `none` satisfies the finish rule vacuously, so a
      // run against it would spend the version tag having checked nothing.
      expect(
        () => _readiness(
          [],
          table: DestinationTable.parse('''
destinations:
  web:
    production: none
''', source: '.cux-train.yaml'),
        ),
        throwsA(isA<StoreSelectionException>()),
      );
    });

    test('a release it was not given', () {
      expect(
        () => _readiness([], version: '  '),
        throwsA(isA<ReadinessException>()),
      );
    });

    test('a build the counter never allocated', () {
      expect(
        () => _readiness([], build: 0),
        throwsA(isA<ReadinessException>()),
      );
    });

    test('a record for a destination the table does not declare', () {
      // The table says where this release goes, the records say where it has
      // been, and one naming a place the other does not know is the two
      // disagreeing about the release. Dropped quietly, the destination would
      // simply not appear — and a rejection that is left out of the answer is
      // the failure the record exists to prevent.
      expect(
        () => _readiness(['refused/nosuch/production/v1.9.13+2196']),
        throwsA(
          isA<ReadinessException>().having(
            (it) => it.message,
            'message',
            allOf(contains('nosuch'), contains('huawei')),
          ),
        ),
      );
    });
  });

  group('the report', () {
    test('names the release and the build before anything else', () {
      expect(_readiness([]).render(), startsWith('1.9.13 — build 2196'));
    });

    test('says who acts at each outstanding destination', () {
      // What an operator wants from `ready` is how much of this is theirs to
      // do by hand, which is the kind and not the name.
      final report = _readiness([]).render();

      expect(report, contains('huawei  manual  https://developer.huawei.com'));
      expect(report, contains('play    ship    cux_ship play promote'));
    });

    test('explains why finish waits on fewer than production acts on', () {
      // `fdroid` is acted on and excluded from the finish rule, so two counts
      // on adjacent lines disagree. Unexplained, that reads as a lost row.
      final report = _readiness([]).render();

      expect(_flat(report), contains('it would act on 3'));
      expect(_flat(report), contains('the version tag waits on 2'));
      expect(_flat(report), contains('fdroid is not counted'));
    });

    test('says what it did not check, even when the answer is yes', () {
      // §3's `ready` is four bullets and this is one of them. An operator who
      // reads "production could run" as the whole check is the failure this
      // verb exists to prevent.
      final report = _readiness([]).render();

      expect(_flat(report), contains('production could run.'));
      expect(_flat(report), contains('not checked here'));
      expect(_flat(report), contains('pre-release gate'));
    });

    test('names no consumer of its own in what it did not check', () {
      // **The draft of that block printed "the local macOS build" and "the
      // F-Droid changelog"** — two rows of one consumer's table, printed at
      // every other consumer. The whole argument for the destination table is
      // that this tool holds no list of stores.
      final report = _flat(_readiness([]).render());

      for (final instance in ['macOS', 'F-Droid', 'fdroid changelog']) {
        expect(report, isNot(contains(instance)), reason: instance);
      }
    });

    test('shows the work under a warning, because the work is the retry', () {
      final report = _readiness([
        'refused/huawei/production/v1.9.13+2196',
      ]).render();

      expect(_flat(report), contains('one thing to take with you:'));
      expect(_flat(report), contains('it would act on 3'));
      expect(report, contains('huawei  manual'));
    });

    test('does not say finish waits on a refusal it never waited on', () {
      // `fdroid` is after-finish, so the finish rule does not count it. A
      // warning that said the rule "goes on waiting" would be contradicted by
      // the "fdroid is not counted" two lines further down.
      final afterFinish = _readiness([
        'refused/fdroid/production/v1.9.13+2196',
      ]);
      final counted = _readiness(['refused/huawei/production/v1.9.13+2196']);

      expect(
        _flat(afterFinish.warnings.single.detail),
        isNot(contains('finish rule')),
      );
      expect(_flat(afterFinish.render()), contains('fdroid is not counted'));
      expect(
        _flat(counted.warnings.single.detail),
        contains('the finish rule goes on waiting.'),
      );
    });

    test('wraps every shape of answer so a narrow terminal keeps it', () {
      // All three verdicts, because each prints prose the others do not: the
      // blocker's paragraph, and the sentence for a release with nothing left
      // but the tag.
      final reports = [
        _readiness([]),
        _readiness(['refused/huawei/production/v1.9.13+2196']),
        _readiness([
          'promoted/play/production/v1.9.13+2196',
          'promoted/huawei/production/v1.9.13+2196',
          'promoted/fdroid/production/v1.9.13+2196',
        ]),
      ];

      for (final report in reports) {
        for (final line in report.render().split('\n')) {
          expect(line.length, lessThanOrEqualTo(78), reason: line);
        }
      }
    });
  });
}
