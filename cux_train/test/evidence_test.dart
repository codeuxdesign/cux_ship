// Which mark a cell gets, and on what grounds.
//
// **Every case here is a pair of inputs that must not collapse into one
// mark.** §6.2's whole argument is that "submitted to Huawei" and "Play
// production holds 2196" are different facts, so the cases are organised by
// the pairs that a four-mark grid would have rendered identically.
import 'package:cux_train/cux_train.dart';
import 'package:test/test.dart';

final _table = DestinationTable.parse('''
destinations:
  play:
    read: "play tracks"
    production: {kind: ship, command: "play promote"}
  huawei:
    production: {kind: manual, console: "https://developer.huawei.com"}
  snap:
    public-at-internal: true
    read: "snap info"
    internal: {kind: run, command: "snap-edge.sh"}
    production: {kind: manual, console: "https://snapcraft.io"}
  web:
    internal: {kind: run, command: "web.sh"}
    production: none
''', source: '.cux-train.yaml');

const _candidate = 2196;

PromotionLedger _ledger(List<String> refs) =>
    PromotionLedger.forBuild(refs, build: _candidate, source: 'refs/tags');

Evidence _evidence(
  String destination, {
  Stage stage = Stage.production,
  List<String> refs = const [],
  Observation? observation,
}) => evidenceFor(
  destination: _table.byName(destination)!,
  stage: stage,
  candidate: _candidate,
  ledger: _ledger(refs),
  observation: observation,
);

void main() {
  group('the two a boolean would have merged', () {
    test('a read is `observed`; a record alone is only `attested`', () {
      // "Where only attestation exists, the grid says so in the cell and
      // never promotes it to holds."
      final read = _evidence('play', observation: const Holds(_candidate));
      final recorded = _evidence(
        'huawei',
        refs: ['promoted/huawei/production/v1.9.13+2196'],
      );

      expect(read.mark, EvidenceMark.observed);
      expect(recorded.mark, EvidenceMark.attested);
      expect(recorded.build, _candidate);
    });

    test('nothing known is `pending`; a refusal is `failed`', () {
      // §6.1's reason for `f` over `s`: a console that rejected the binary
      // must not look like one nobody has looked at.
      final untouched = _evidence('huawei');
      final refused = _evidence(
        'huawei',
        refs: ['refused/huawei/production/v1.9.13+2196'],
      );

      expect(untouched.mark, EvidenceMark.pending);
      expect(untouched.build, isNull, reason: 'nothing to name');
      expect(refused.mark, EvidenceMark.failed);
      expect(refused.note, contains('refused'));
    });

    test('a failed step is `failed`; an unreadable endpoint is not', () {
      // A read that cannot answer says nothing about whether the build
      // landed, so it falls back to the record rather than claiming failure.
      final jobFailed = _evidence(
        'play',
        observation: const StepFailed('the android job failed'),
      );
      final cannotRead = _evidence(
        'play',
        observation: const Unreadable('504 from the Play API'),
      );

      expect(jobFailed.mark, EvidenceMark.failed);
      expect(jobFailed.note, 'the android job failed');
      expect(cannotRead.mark, EvidenceMark.pending);
      expect(cannotRead.note, '504 from the Play API');
    });

    test('an unreadable endpoint keeps whatever the record said', () {
      final attested = _evidence(
        'play',
        refs: ['promoted/play/production/v1.9.13+2196'],
        observation: const Unreadable('504 from the Play API'),
      );

      expect(attested.mark, EvidenceMark.attested);
      expect(attested.note, '504 from the Play API');
    });
  });

  group('disagreement', () {
    test('a record and a read that name different builds', () {
      // §6.2's example, and the most valuable line the tool can print: snap
      // stable would be recorded at 2196 while the API answers 1940.
      final cell = _evidence(
        'snap',
        refs: ['promoted/snap/production/v1.9.13+2196'],
        observation: const Holds(1940),
      );

      expect(cell.mark, EvidenceMark.disagreed);
      expect(cell.build, 1940, reason: 'the cell names what was read');
      expect(cell.note, 'recorded at 2196, holds 1940');
    });

    test('a read of an older build with nothing claiming otherwise', () {
      // Nothing is being contradicted — the destination simply holds an
      // older build, which the cell names rather than normalising away.
      final cell = _evidence('snap', observation: const Holds(1940));

      expect(cell.mark, EvidenceMark.observed);
      expect(cell.build, 1940);
    });

    test('a refusal on record that the destination contradicts', () {
      // Worth saying rather than quietly preferring the read: somebody
      // recorded a rejection and the store has the build anyway.
      final cell = _evidence(
        'huawei',
        refs: ['refused/huawei/production/v1.9.13+2196'],
        observation: const Holds(_candidate),
      );

      expect(cell.mark, EvidenceMark.disagreed);
      expect(cell.note, contains('refused'));
    });
  });

  group('n/a', () {
    test('is what a stage nobody acts at gets, never pending', () {
      // A grid with twenty-four cells saying "pending" has buried the four
      // that matter.
      final cell = _evidence('web');

      expect(cell.mark, EvidenceMark.notApplicable);
      expect(cell.build, isNull);
    });

    test('wins even where a record somehow exists', () {
      // The table is the authority on whether there is anything to do. A
      // stray record cannot invent a step.
      final cell = _evidence(
        'web',
        refs: ['promoted/web/production/v1.9.13+2196'],
      );

      expect(cell.mark, EvidenceMark.notApplicable);
    });

    test('covers the beta column, which is most of a real table', () {
      for (final name in ['play', 'huawei', 'snap', 'web']) {
        expect(
          _evidence(name, stage: Stage.beta).mark,
          EvidenceMark.notApplicable,
          reason: name,
        );
      }
    });
  });

  group('`public at internal`', () {
    test('rides along with the mark rather than replacing it', () {
      // It is a property of the destination's stages, not of this cell's
      // evidence, so it must not change what the mark says.
      final cell = _evidence(
        'snap',
        stage: Stage.internal,
        observation: const Holds(_candidate),
      );

      expect(cell.mark, EvidenceMark.observed);
      expect(cell.publicAtInternal, isTrue);
    });

    test('is carried on every mark, including n/a and pending', () {
      expect(_evidence('snap').publicAtInternal, isTrue);
      expect(
        _evidence('snap', stage: Stage.beta).publicAtInternal,
        isTrue,
        reason: 'the annotation is about the destination, not the cell',
      );
      expect(_evidence('play').publicAtInternal, isFalse);
    });

    test('is refused where nobody acts at internal', () {
      expect(
        () => DestinationTable.parse('''
destinations:
  fosshub:
    public-at-internal: true
    production: {kind: run, command: x}
''', source: '.cux-train.yaml'),
        throwsA(
          isA<DestinationTableException>().having(
            (e) => e.message,
            'message',
            contains('nobody acts at `internal`'),
          ),
        ),
      );
    });

    test('must be a boolean', () {
      expect(
        () => DestinationTable.parse('''
destinations:
  snap:
    public-at-internal: "yes"
    internal: {kind: run, command: x}
''', source: '.cux-train.yaml'),
        throwsA(
          isA<DestinationTableException>().having(
            (e) => e.message,
            'message',
            contains('`public-at-internal` must be true or false'),
          ),
        ),
      );
    });
  });
}
