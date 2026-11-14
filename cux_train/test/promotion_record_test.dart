// The ref grammar: what a record looks like, and what is refused as one.
//
// **The subject is the round trip and the refusals.** A record is read back
// days later by a different run, so a ref this file writes and cannot read, or
// reads as something other than what was written, is the failure the record
// exists to prevent — §2's *not being able to tell*, with the tool itself as
// the one that cannot tell.
import 'package:cux_train/cux_train.dart';
import 'package:test/test.dart';

PromotionRecord _parse(String ref) =>
    PromotionRecord.parse(ref, source: 'refs/tags');

Matcher _refused(String fragment) => throwsA(
  isA<PromotionRecordException>().having(
    (e) => e.message,
    'message',
    contains(fragment),
  ),
);

void main() {
  group('the ref a record writes', () {
    test('is the donor shape for a bare name', () {
      const record = PromotionRecord(
        destination: 'huawei',
        stage: Stage.production,
        version: '1.9.13',
        build: 2196,
        outcome: PromotionOutcome.handedOver,
      );

      // §6.1's own example, which is also the donor's existing tag shape.
      expect(record.ref, 'promoted/huawei/production/v1.9.13+2196');
    });

    test(
      'puts a `family:member` name on a path, because a ref cannot hold a colon',
      () {
        // `git check-ref-format` refuses a colon, and six of AuthPass's
        // nineteen destinations have one. A slash says what the colon said.
        const record = PromotionRecord(
          destination: 'appstore:ios',
          stage: Stage.production,
          version: '1.9.13',
          build: 2196,
          outcome: PromotionOutcome.handedOver,
        );

        expect(record.ref, 'promoted/appstore/ios/production/v1.9.13+2196');
        expect(record.ref, isNot(contains(':')));
      },
    );

    test('files a refusal under its own namespace', () {
      // Not a flag inside the ref: anything that globs `promoted/` and does
      // not parse what it finds would count a refusal as a promotion.
      const record = PromotionRecord(
        destination: 'huawei',
        stage: Stage.production,
        version: '1.9.13',
        build: 2196,
        outcome: PromotionOutcome.attemptedAndRefused,
      );

      expect(record.ref, 'refused/huawei/production/v1.9.13+2196');
      expect(PromotionOutcome.namespaces, ['promoted', 'refused']);
    });

    test('reads back everything it wrote, for every shape', () {
      for (final destination in ['play', 'appstore:ios', 'direct:macos']) {
        for (final stage in Stage.values) {
          for (final outcome in PromotionOutcome.values) {
            final written = PromotionRecord(
              destination: destination,
              stage: stage,
              version: '1.9.13',
              build: 2196,
              outcome: outcome,
            );
            final read = _parse(written.ref);

            expect(read.destination, destination, reason: written.ref);
            expect(read.stage, stage, reason: written.ref);
            expect(read.version, '1.9.13', reason: written.ref);
            expect(read.build, 2196, reason: written.ref);
            expect(read.outcome, outcome, reason: written.ref);
          }
        }
      }
    });
  });

  group('refusals', () {
    test('a ref with too few parts to be a record', () {
      for (final ref in ['promoted', 'promoted/huawei', 'promoted/huawei/x']) {
        expect(() => _parse(ref), _refused('is not a promotion record'));
      }
    });

    test('a namespace this grammar does not write', () {
      // `uploaded/` is `cux_ship`'s and means something else — it is one tag
      // per commit, first store wins, so it proves somebody uploaded and not
      // who. Reading it as a promotion would be the wrong answer, not a
      // missing one.
      expect(
        () => _parse('uploaded/huawei/production/v1.9.13+2196'),
        _refused('is not a record namespace'),
      );
    });

    test('a stage that is not a stage', () {
      expect(
        () => _parse('promoted/huawei/prodution/v1.9.13+2196'),
        _refused('records a stage called `prodution`'),
      );
    });

    test('a version part that names no build', () {
      // The build identifies the artifact; a record without one cannot say
      // which bytes the console was handed.
      expect(
        () => _parse('promoted/huawei/production/v1.9.13'),
        _refused('names no build'),
      );
    });

    test('a version part that is not a version part', () {
      expect(
        () => _parse('promoted/huawei/production/1.9.13+2196'),
        _refused('does not begin with `v`'),
      );
      expect(
        () => _parse('promoted/huawei/production/v+2196'),
        _refused('names no version'),
      );
      for (final build in ['nine', '', '0', '-3']) {
        expect(
          () => _parse('promoted/huawei/production/v1.9.13+$build'),
          _refused('not a positive whole number'),
          reason: build,
        );
      }
    });

    test('a build this grammar would not have written that way', () {
      // `int.tryParse` reads all three, and none is a ref that comes back as
      // itself: `0x10` is sixteen, `02196` is rewritten as `+2196`, and the
      // padded one loses its spaces. Two ref names reading as one record is
      // how a ledger counts a build nobody recorded. The last is all digits
      // and too long to be a number at all.
      for (final build in ['0x10', '02196', ' 5 ', '99999999999999999999']) {
        expect(
          () => _parse('promoted/huawei/production/v1.9.13+$build'),
          _refused('not a positive whole number'),
          reason: build,
        );
      }
    });

    test('a destination that is not one name or `family/member`', () {
      // Reading from the right takes whatever is left as the destination, so
      // without a bound three components come back as `a:b:c` — a name the
      // table refuses to declare — and an empty one as no name at all.
      for (final ref in [
        'promoted/a/b/c/production/v1.9.13+2196',
        'promoted//production/v1.9.13+2196',
        'promoted/a//production/v1.9.13+2196',
        'promoted//ios/production/v1.9.13+2196',
      ]) {
        expect(
          () => _parse(ref),
          _refused('is not a destination name'),
          reason: ref,
        );
      }
    });

    test('names where the ref came from, not a guess', () {
      expect(
        () => PromotionRecord.parse('promoted/x', source: 'origin'),
        _refused('origin:'),
      );
    });
  });

  group('a version is opaque', () {
    test('a `+` inside the version does not confuse the build', () {
      // Read from the last `+`, so a version that carries one of its own
      // still yields the build. Nothing here orders or interprets a version.
      final record = _parse('promoted/play/production/v1.9.13+rc1+2196');

      expect(record.version, '1.9.13+rc1');
      expect(record.build, 2196);
    });
  });
}
