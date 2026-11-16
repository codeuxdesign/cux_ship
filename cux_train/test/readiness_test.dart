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
    test('is yes when nothing is recorded, because that is the normal day', () {
      // The first run of a release reaches `ready` with an empty namespace,
      // and "nothing recorded" is not a problem — it is the whole of the work
      // `production` is about to do.
      final readiness = _readiness([]);

      expect(readiness.couldRun, isTrue);
      expect(readiness.blockers, isEmpty);
      expect(readiness.outstanding.map((it) => it.name), [
        'play',
        'huawei',
        'fdroid',
      ]);
    });

    test('is still yes when every destination is already recorded', () {
      // **An empty outstanding list is not a no.** `production` has one step
      // left — the version tag — and a verdict of "not ready" would send an
      // operator away from the only thing left to do.
      final readiness = _readiness([
        'promoted/play/production/v1.9.13+2196',
        'promoted/huawei/production/v1.9.13+2196',
        'promoted/fdroid/production/v1.9.13+2196',
      ]);

      expect(readiness.couldRun, isTrue);
      expect(readiness.outstanding, isEmpty);
      expect(readiness.finish.isSatisfied, isTrue);
      expect(
        _flat(readiness.render()),
        contains('all that is left is the version tag'),
      );
    });

    test('is no when a destination refused this build', () {
      // The case the verb exists for: `production` is resumable, so it walks
      // back into a refusal rather than stopping at it, and nothing else in
      // the tool tells an operator that before they start.
      final readiness = _readiness(['refused/huawei/production/v1.9.13+2196']);

      expect(readiness.couldRun, isFalse);
      expect(readiness.blockers, hasLength(1));
      expect(readiness.blockers.single.destination, 'huawei');
      expect(
        readiness.blockers.single.detail,
        contains('refused/huawei/production/v1.9.13+2196'),
      );
    });

    test('counts a refusal as work still outstanding, not as work done', () {
      // `isHandedOver` is false for a refusal, which is what makes the
      // destination come up again — and what makes the two lists overlap, so
      // the renderer prints one of them and not both.
      final readiness = _readiness(['refused/huawei/production/v1.9.13+2196']);

      expect(readiness.outstanding.map((it) => it.name), contains('huawei'));
      expect(readiness.finish.waitingOn.map((it) => it.name), [
        'play',
        'huawei',
      ]);
    });

    test('a refusal at another stage is not a production blocker', () {
      // A destination that refused at `internal` has nothing to say about
      // whether `production` can run, and reading the namespace rather than
      // the stage would make every historical rejection permanent.
      final readiness = _readiness(['refused/huawei/internal/v1.9.13+2196']);

      expect(readiness.couldRun, isTrue);
    });

    test('a refusal at another build is not this run\'s', () {
      // The ledger drops it before this file sees it; the case is here
      // because the alternative — a build filter that reached for the
      // namespace instead — would look identical until a second release.
      final readiness = _readiness(['refused/huawei/production/v1.9.12+2007']);

      expect(readiness.couldRun, isTrue);
      expect(readiness.blockers, isEmpty);
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
      expect(_flat(report), contains('pre-release hook'));
    });

    test('leaves the work out when it is blocked, to say one thing', () {
      final report = _readiness([
        'refused/huawei/production/v1.9.13+2196',
      ]).render();

      expect(_flat(report), contains('production cannot run: 1 blocker.'));
      expect(_flat(report), isNot(contains('it would act on')));
    });

    test('wraps a blocker so a narrow terminal keeps the shape', () {
      final report = _readiness([
        'refused/huawei/production/v1.9.13+2196',
      ]).render();

      for (final line in report.split('\n')) {
        expect(line.length, lessThanOrEqualTo(78), reason: line);
      }
    });
  });
}
