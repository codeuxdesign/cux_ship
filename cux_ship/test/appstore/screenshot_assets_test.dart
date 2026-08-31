// SPDX-License-Identifier: Apache-2.0
//
// Two defects, one cause. `--metadata` deleted the whole screenshot set and
// re-uploaded every file on every run — recorded as known and "harmless" —
// and then submitted the version immediately. Four assets in flight at the
// moment of submission is what produced `appStoreVersions … is not in valid
// state`: a message about the version, for a problem with its screenshots.
// Measured: the identical request, replayed forty minutes later with no
// upload, was ACCEPTED.
//
// Underneath it, the commit response was discarded and `uploaded <name>`
// printed unconditionally, so a screenshot Apple refused during ingestion was
// reported as uploaded and was then simply absent from the listing. That one
// is silent and permanent where the race is loud and recoverable.
import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:test/test.dart';

Map<String, dynamic> _screenshot({
  Object? fileName = _absent,
  Object? checksum = _absent,
  String? state,
  List<Map<String, dynamic>>? errors,
}) => {
  'type': 'appScreenshots',
  'id': 'shot-1',
  'attributes': {
    if (!identical(fileName, _absent)) ...{'fileName': fileName},
    if (!identical(checksum, _absent)) ...{'sourceFileChecksum': checksum},
    if (state != null || errors != null) ...{
      'assetDeliveryState': {
        if (state != null) ...{'state': state},
        if (errors != null) ...{'errors': errors},
      },
    },
  },
};

const _absent = Object();

PublishedScreenshot _published(String? name, String? sum) =>
    (fileName: name, checksum: sum);

LocalScreenshot _local(String name, String sum) =>
    (fileName: name, checksum: sum);

void main() {
  group('is it already published', () {
    test('the same files in the same order need no upload', () {
      expect(
        screenshotsAlreadyPublished(
          published: [_published('01.png', 'aaa'), _published('02.png', 'bbb')],
          local: [_local('01.png', 'aaa'), _local('02.png', 'bbb')],
        ),
        isTrue,
      );
    });

    test('a changed image is caught by its checksum', () {
      // The name is unchanged, which is the ordinary case — somebody
      // re-exported a screenshot and kept the filename.
      expect(
        screenshotsAlreadyPublished(
          published: [_published('01.png', 'aaa')],
          local: [_local('01.png', 'zzz')],
        ),
        isFalse,
      );
    });

    test('a renamed image is caught by its name', () {
      expect(
        screenshotsAlreadyPublished(
          published: [_published('01.png', 'aaa')],
          local: [_local('01-rides.png', 'aaa')],
        ),
        isFalse,
      );
    });

    test('the same files in a different order are a different listing', () {
      // Screenshots are shown in upload order, so this must re-upload.
      // Comparing as sets rather than sequences would leave the old order
      // published and report success.
      expect(
        screenshotsAlreadyPublished(
          published: [_published('01.png', 'aaa'), _published('02.png', 'bbb')],
          local: [_local('02.png', 'bbb'), _local('01.png', 'aaa')],
        ),
        isFalse,
      );
    });

    test('adding or removing one is a mismatch', () {
      expect(
        screenshotsAlreadyPublished(
          published: [_published('01.png', 'aaa')],
          local: [_local('01.png', 'aaa'), _local('02.png', 'bbb')],
        ),
        isFalse,
      );
      expect(
        screenshotsAlreadyPublished(
          published: [_published('01.png', 'aaa'), _published('02.png', 'bbb')],
          local: [_local('01.png', 'aaa')],
        ),
        isFalse,
      );
    });

    test('a checksum Apple did not report is never a match', () {
      // Absent until an upload is committed, and absence is not evidence that
      // the bytes on disk are the bytes Apple holds. Treated as differing, so
      // the cost is an upload nobody needed rather than a listing nobody
      // updated.
      expect(
        screenshotsAlreadyPublished(
          published: [_published('01.png', null)],
          local: [_local('01.png', 'aaa')],
        ),
        isFalse,
      );
    });

    test('a name Apple did not report is never a match either', () {
      expect(
        screenshotsAlreadyPublished(
          published: [_published(null, 'aaa')],
          local: [_local('01.png', 'aaa')],
        ),
        isFalse,
      );
    });

    test('two empty lists are not a match', () {
      // Nothing published and nothing to publish means there is no set to
      // compare; the caller only reaches this with files in hand, and
      // answering "already published" for an empty tree would skip a
      // deliberate clear.
      expect(
        screenshotsAlreadyPublished(published: const [], local: const []),
        isFalse,
      );
    });
  });

  group('reading a published screenshot', () {
    test('both fields are read from attributes', () {
      expect(
        readPublishedScreenshot(
          _screenshot(fileName: '01.png', checksum: 'aaa'),
        ),
        (fileName: '01.png', checksum: 'aaa'),
      );
    });

    test('an attribute Apple omitted reads as null, not as empty', () {
      final read = readPublishedScreenshot(_screenshot(fileName: '01.png'));
      expect(read.fileName, '01.png');
      expect(read.checksum, isNull);
    });

    test('a resource with no attributes at all reads as two nulls', () {
      final read = readPublishedScreenshot({
        'type': 'appScreenshots',
        'id': 'x',
      });
      expect(read.fileName, isNull);
      expect(read.checksum, isNull);
    });
  });

  group('what Apple says about an asset', () {
    test('a completed asset reports COMPLETE', () {
      expect(
        screenshotDeliveryState(_screenshot(state: 'COMPLETE')),
        'COMPLETE',
      );
    });

    test('an asset still being ingested is not complete', () {
      // The race, in one value: the commit returns while this still says
      // UPLOAD_COMPLETE, and submitting then is what Apple refuses.
      expect(
        screenshotDeliveryState(_screenshot(state: 'UPLOAD_COMPLETE')),
        isNot('COMPLETE'),
      );
      expect(
        screenshotDeliveryState(_screenshot(state: 'AWAITING_UPLOAD')),
        isNot('COMPLETE'),
      );
    });

    test('no assetDeliveryState at all reads as null, not as complete', () {
      // The state that must never be mistaken for success: a response that
      // said nothing is not a response that said COMPLETE.
      expect(screenshotDeliveryState(_screenshot(fileName: '01.png')), isNull);
      expect(screenshotDeliveryState({'type': 'appScreenshots'}), isNull);
    });

    test('a rejection carries Apple\'s own reasons', () {
      // The half that was being thrown away, and the reason this is worth
      // catching at all: Apple names the problem, and nothing read it.
      expect(
        screenshotDeliveryErrors(
          _screenshot(
            state: 'FAILED',
            errors: [
              {'code': 'IMAGE_ALPHA', 'description': 'Image has alpha channel'},
            ],
          ),
        ),
        ['IMAGE_ALPHA - Image has alpha channel'],
      );
    });

    test('an error missing half its fields still says what it can', () {
      expect(
        screenshotDeliveryErrors(
          _screenshot(
            state: 'FAILED',
            errors: [
              {'description': 'Wrong dimensions'},
              {'code': 'UNKNOWN'},
            ],
          ),
        ),
        ['Wrong dimensions', 'UNKNOWN'],
      );
    });

    test(
      'a failure with no errors listed reports none rather than inventing',
      () {
        expect(screenshotDeliveryErrors(_screenshot(state: 'FAILED')), isEmpty);
      },
    );

    test('an error that is entirely empty is dropped, not printed blank', () {
      expect(
        screenshotDeliveryErrors(
          _screenshot(state: 'FAILED', errors: [<String, dynamic>{}]),
        ),
        isEmpty,
      );
    });
  });

  group('the checksum', () {
    test('is the MD5 Apple compares against, computed one way only', () {
      // The commit writes this value and the next run's comparison recomputes
      // it. If the two ever disagreed, every screenshot would re-upload for
      // ever and the skip would silently never fire.
      expect(checksumOf(const []), 'd41d8cd98f00b204e9800998ecf8427e');
      expect(checksumOf('hello'.codeUnits), '5d41402abc4b2a76b9719d911017c592');
    });
  });
}
