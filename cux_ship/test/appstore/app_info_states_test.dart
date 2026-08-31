// SPDX-License-Identifier: Apache-2.0
//
// `editableVersionStates` gated three call sites across two Apple resources,
// and the two resources do not have the same rule. A version in
// WAITING_FOR_REVIEW is with Apple and a push against it is rightly refused;
// the `appInfos` record beside it accepts a PATCH — measured against a live
// account, and what fastlane's `fetch_edit_app_info` has selected for years.
//
// One constant for both meant `promote --platform macos` failed with 409
// while the *iOS* side sat in review, and failed at the first thing the
// promotion does, so no version was created, no build attached and no
// submission made.
import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:test/test.dart';

Map<String, dynamic> _info(String id, String? state) => {
  'type': 'appInfos',
  'id': id,
  'attributes': {'appStoreState': ?state},
};

void main() {
  group('the two sets are not the same set', () {
    test('a version in review is still not editable', () {
      // The refusal at `ensureVersion` is correct and stays: "It is with
      // Apple. Cancel the submission in App Store Connect to edit it again."
      expect(editableVersionStates, isNot(contains('WAITING_FOR_REVIEW')));
    });

    test('an app info in review is', () {
      expect(editableAppInfoStates, contains('WAITING_FOR_REVIEW'));
    });

    test('and they differ by exactly that one state', () {
      expect(editableAppInfoStates.difference(editableVersionStates), {
        'WAITING_FOR_REVIEW',
      });
      expect(editableVersionStates.difference(editableAppInfoStates), isEmpty);
    });

    test('nothing editable is also considered published', () {
      expect(
        editableAppInfoStates.intersection(publishedAppInfoStates),
        isEmpty,
      );
    });
  });

  group('selecting a record', () {
    test('the mid-review record is the one a promote writes to', () {
      // The measured repro: iOS mid-review, macOS live, one app.
      final infos = [
        _info('live', 'READY_FOR_SALE'),
        _info('review', 'WAITING_FOR_REVIEW'),
      ];
      expect(selectAppInfo(infos, AppInfoUse.write), same(infos[1]));
    });

    test('an editable record outranks everything else', () {
      final infos = [
        _info('live', 'READY_FOR_SALE'),
        _info('other', 'IN_REVIEW'),
        _info('editable', 'PREPARE_FOR_SUBMISSION'),
      ];
      for (final use in AppInfoUse.values) {
        expect(selectAppInfo(infos, use), same(infos[2]), reason: '$use');
      }
    });

    test('a state Apple did not report is not claimed as editable', () {
      // Absence is a fact about the response, not about the record — the same
      // reading `betaGroupKind` takes. An editable record beside it wins.
      final infos = [_info('unstated', null), _info('editable', 'REJECTED')];
      expect(selectAppInfo(infos, AppInfoUse.write), same(infos[1]));
    });

    test('and alone, it is not written to either', () {
      // Asserted with nothing beside it, because a decoy behind an editable
      // record only ever tests the ranking. The doc comment claims a safety
      // property; this is the test that makes it one.
      final infos = [_info('unstated', null)];
      expect(selectAppInfo(infos, AppInfoUse.write), isNull);
    });

    test('but it still outranks the published one for reading', () {
      // The one thing an unreported state is not is READY_FOR_SALE: that
      // state gets reported. Worth comparing against; not worth writing to.
      final infos = [_info('live', 'READY_FOR_SALE'), _info('unstated', null)];
      expect(selectAppInfo(infos, AppInfoUse.read), same(infos[1]));
    });

    test('a record under active review is never written to', () {
      // IN_REVIEW is in neither list, and under a "refuse what is not
      // published" rule it would have been selected — a record Apple is
      // actively reviewing, reached through a fallback rather than through
      // the state the widening was measured on. fastlane draws the line here
      // too: fetch_live_app_info takes IN_REVIEW, fetch_edit_app_info takes
      // WAITING_FOR_REVIEW.
      final infos = [_info('reviewing', 'IN_REVIEW')];
      expect(selectAppInfo(infos, AppInfoUse.write), isNull);
      // Still readable, so a run that changes nothing is not blocked by it.
      expect(selectAppInfo(infos, AppInfoUse.read), same(infos.first));
    });

    test('a state this package has never seen is never written to', () {
      // Apple has changed this enum before. An unrecognised state that
      // refuses costs a reader thirty seconds; one that writes lands a change
      // nobody examined and says nothing.
      for (final state in const [
        'PROCESSING_FOR_APP_STORE',
        'PENDING_APPLE_RELEASE',
        'ACCEPTED',
        'NOT_APPLICABLE',
        'SOME_STATE_APPLE_HAS_NOT_SHIPPED_YET',
      ]) {
        expect(
          selectAppInfo([_info('x', state)], AppInfoUse.write),
          isNull,
          reason: state,
        );
      }
    });

    test('only the enumerated states are write targets, and nothing else', () {
      // The polarity, stated directly: writability is a whitelist.
      for (final state in editableAppInfoStates) {
        expect(
          selectAppInfo([_info('x', state)], AppInfoUse.write),
          isNotNull,
          reason: state,
        );
      }
    });

    test('a published record can be read but never written', () {
      final infos = [_info('live', 'READY_FOR_SALE')];
      expect(selectAppInfo(infos, AppInfoUse.read), same(infos.first));
      expect(selectAppInfo(infos, AppInfoUse.write), isNull);
    });

    test('every published state is refused as a write target', () {
      for (final state in publishedAppInfoStates) {
        expect(
          selectAppInfo([_info('x', state)], AppInfoUse.write),
          isNull,
          reason: state,
        );
      }
    });

    test('an app with no records at all selects nothing, either way', () {
      for (final use in AppInfoUse.values) {
        expect(selectAppInfo(const [], use), isNull, reason: '$use');
      }
    });

    test('a read and a write pick the same record whenever a write can', () {
      // The property the whole design rests on: the comparison is evidence
      // about the write only if both looked at the same record. The two
      // selections differ in exactly one case, and that case throws.
      const states = [
        'PREPARE_FOR_SUBMISSION',
        'WAITING_FOR_REVIEW',
        'IN_REVIEW',
        'READY_FOR_SALE',
        'REPLACED_WITH_NEW_VERSION',
        null,
      ];
      for (final first in states) {
        for (final second in states) {
          final infos = [_info('a', first), _info('b', second)];
          final write = selectAppInfo(infos, AppInfoUse.write);
          if (write == null) {
            continue;
          }
          expect(
            selectAppInfo(infos, AppInfoUse.read),
            same(write),
            reason: '$first then $second',
          );
        }
      }
    });
  });

  group('refusing, when there is nothing to write to', () {
    test('an app with no records says so as a 404', () {
      expect(
        () => requireWritableAppInfo(const []),
        throwsA(
          isA<AscApiException>()
              .having((e) => e.status, 'status', 404)
              .having(
                (e) => e.details.join(' '),
                'details',
                contains('no appInfos record at all'),
              ),
        ),
      );
    });

    test('an all-published app refuses, and names the fields', () {
      // The refusal has to be actionable. "Something could not be published"
      // is not; "the primary category would have to be written" is.
      expect(
        () => requireWritableAppInfo(
          [_info('live', 'READY_FOR_SALE')],
          fields: ['primaryCategory', 'age rating'],
        ),
        throwsA(
          isA<AscApiException>()
              .having((e) => e.status, 'status', 409)
              .having(
                (e) => e.details.join(' '),
                'details',
                allOf(
                  contains('primaryCategory'),
                  contains('age rating'),
                  contains('READY_FOR_SALE'),
                  contains('never becomes writable'),
                ),
              ),
        ),
      );
    });

    test('this 409 does not read like the 409 Apple returns for a value', () {
      // Two errors with the same status calling for opposite actions: this
      // one is about which record may be written at all, Apple's is answered
      // by changing the metadata.
      late final AscApiException refusal;
      try {
        requireWritableAppInfo([_info('live', 'READY_FOR_SALE')]);
        fail('expected a refusal');
      } on AscApiException catch (e) {
        refusal = e;
      }
      final text = refusal.details.join(' ');
      expect(text, contains('no appInfos record is in a state'));
    });

    test('it contradicts Apple\'s own advice, which was measured wrong', () {
      // Apple's 409 says "Create the next version first". It sounds
      // authoritative and does not work: appInfos records are app-level and
      // versions are per-platform, so creating a macOS version produced no
      // new record on an app holding READY_FOR_SALE and WAITING_FOR_REVIEW.
      // Repeating that advice would cost a release cycle to disprove, so the
      // refusal says plainly that it is wrong.
      late final AscApiException refusal;
      try {
        requireWritableAppInfo([_info('live', 'READY_FOR_SALE')]);
        fail('expected a refusal');
      } on AscApiException catch (e) {
        refusal = e;
      }
      final text = refusal.details.join(' ');
      expect(text, contains('app-level'));
      expect(text, contains('per-platform'));
      expect(text, contains('measured not to'));
    });

    test('the refusal names the blocking state, whatever it is', () {
      // It must not claim the blocker is always the published page: IN_REVIEW
      // and unrecognised states land here too, and naming the state is what
      // lets the reader tell which case they are in — waiting for a review to
      // finish and creating a version are different actions.
      late final AscApiException refusal;
      try {
        requireWritableAppInfo([_info('reviewing', 'IN_REVIEW')]);
        fail('expected a refusal');
      } on AscApiException catch (e) {
        refusal = e;
      }
      final text = refusal.details.join(' ');
      expect(text, contains('IN_REVIEW'));
      expect(text, contains('when that review finishes'));
      // The states it *would* accept, so the message answers "what now".
      expect(text, contains('WAITING_FOR_REVIEW'));
    });

    test('a record in review is not refused at all', () {
      // The bug, at the point it was thrown.
      expect(
        requireWritableAppInfo([
          _info('live', 'READY_FOR_SALE'),
          _info('review', 'WAITING_FOR_REVIEW'),
        ])['id'],
        'review',
      );
    });
  });
}
