// SPDX-License-Identifier: Apache-2.0
//
// `promote` could not say how a release should start. Asked how macOS 1.1.3
// should go out once approved, the maintainer chose automatic; the version
// Apple holds is MANUAL. Nothing was rejected and nothing was reported —
// there was no flag, so a decision that had been made had nowhere to go and
// the hardcoded default stood. It only did not matter because manual is the
// safer end of the mistake: the reverse would have published a release
// unattended.
//
// Two properties carry the fix, and both are here rather than buried behind a
// credential: an absent flag must change nothing, and a value that cannot be
// expressed must be refused rather than approximated.
import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:test/test.dart';

void main() {
  group('which values may be asked for', () {
    test('the two Apple takes without a date are accepted', () {
      expect(releaseTypeRefusal('MANUAL'), isNull);
      expect(releaseTypeRefusal('AFTER_APPROVAL'), isNull);
    });

    test('SCHEDULED is refused, and the refusal says what is missing', () {
      // Apple accepts it; this tool cannot send it, because it is meaningless
      // without an earliestReleaseDate and there is no flag to give it one.
      // The parser's `allowed:` would have said only "not an allowed value",
      // which is why the check is here instead.
      final refusal = releaseTypeRefusal('SCHEDULED');
      expect(refusal, isNotNull);
      expect(refusal, contains('earliestReleaseDate'));
      expect(refusal, contains('App Store Connect'));
    });

    test('an unknown value names the ones that work', () {
      final refusal = releaseTypeRefusal('AUTOMATIC');
      expect(refusal, contains('AUTOMATIC'));
      expect(refusal, contains('MANUAL'));
      expect(refusal, contains('AFTER_APPROVAL'));
    });

    test('the requestable set excludes SCHEDULED', () {
      expect(requestableReleaseTypes, isNot(contains(scheduledReleaseType)));
    });
  });

  group('what to do about a version that already exists', () {
    test('no flag changes nothing, whatever Apple holds', () {
      // The load-bearing one. A tool that normalised an unset flag to its own
      // preferred default would be worse than the silence this replaces: a
      // release switched to automatic because nobody passed a flag is the
      // failure running in the other direction.
      for (final current in const [
        'MANUAL',
        'AFTER_APPROVAL',
        'SCHEDULED',
        null,
      ]) {
        expect(
          releaseTypeChange(requested: null, current: current),
          ReleaseTypeChange.leaveAlone,
          reason: 'current: $current',
        );
      }
    });

    test('a value Apple already holds is not written again', () {
      expect(
        releaseTypeChange(requested: 'MANUAL', current: 'MANUAL'),
        ReleaseTypeChange.alreadySet,
      );
    });

    test('a value that differs is written', () {
      expect(
        releaseTypeChange(requested: 'AFTER_APPROVAL', current: 'MANUAL'),
        ReleaseTypeChange.write,
      );
    });

    test('a release type Apple did not report is written, not assumed', () {
      // Absence is a fact about the response, not about the version — the
      // same reading this package takes of an unreported category or an
      // unreported appStoreState. Treating it as a match would skip the write
      // on the strength of a reading that never happened.
      expect(
        releaseTypeChange(requested: 'MANUAL', current: null),
        ReleaseTypeChange.write,
      );
    });

    test('a scheduled version is refused rather than rescheduled', () {
      // Changing away from SCHEDULED decides what becomes of the date beside
      // it, and there is no flag that can say. Refusing beats guessing that
      // Apple discards a stale date — and beats leaving one silently attached
      // to a release that is no longer scheduled.
      for (final requested in requestableReleaseTypes) {
        expect(
          releaseTypeChange(
            requested: requested,
            current: scheduledReleaseType,
          ),
          ReleaseTypeChange.refuseScheduled,
          reason: requested,
        );
      }
    });

    test('a scheduled version with no flag is left alone, not refused', () {
      // The refusal is about changing it. A run that says nothing about the
      // release type has no quarrel with a schedule somebody set deliberately.
      expect(
        releaseTypeChange(requested: null, current: scheduledReleaseType),
        ReleaseTypeChange.leaveAlone,
      );
    });
  });
}
