// SPDX-License-Identifier: Apache-2.0
//
// A category PATCH names only the relationships the metadata tree declares, so
// it always omits the rest — the other category, and the four subcategory
// slots this package has never managed. Everything says omission leaves them
// alone: JSON:API specifies it, spaceship carries a separate explicit-null
// path for *clearing* one that would be redundant if omitting cleared, and
// fastlane omits the same four across a very large number of apps without it
// being a known bug.
//
// That is a good argument and it is still inference. The read-back turns it
// into a reading. These tests are about the two things that would make the
// reading worthless: comparing the wrong relationships, and treating "Apple
// did not report it" as an answer.
import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:test/test.dart';

/// An `appInfos` record carrying [relationships], each spelled the way the API
/// spells one that *was* included.
Map<String, dynamic> _appInfo(Map<String, String?> relationships) => {
  'type': 'appInfos',
  'id': 'info-1',
  'relationships': {
    for (final entry in relationships.entries) ...{
      entry.key: {
        'data': entry.value == null
            ? null
            : {'type': 'appCategories', 'id': entry.value},
      },
    },
  },
};

void main() {
  group('reading the relationships back', () {
    test('an id is reported as that id', () {
      expect(
        readCategoryRelationships(
          _appInfo({'primaryCategory': 'PHOTO_AND_VIDEO'}),
        ),
        {'primaryCategory': 'PHOTO_AND_VIDEO'},
      );
    });

    test('an explicitly unset relationship is reported as unset', () {
      // `data: null` is an answer: Apple is saying there is no category here.
      expect(readCategoryRelationships(_appInfo({'secondaryCategory': null})), {
        'secondaryCategory': null,
      });
    });

    test('a relationship with no data key is absent, not null', () {
      // The third state, and the one that matters: "not reported" is neither
      // a value nor an absence of value, and collapsing it into null would
      // manufacture a difference out of a sparse response.
      final reported = readCategoryRelationships({
        'type': 'appInfos',
        'id': 'info-1',
        'relationships': {
          'primaryCategory': {
            'links': {'self': 'https://example.invalid/primaryCategory'},
          },
        },
      });
      expect(reported.containsKey('primaryCategory'), isFalse);
    });

    test('a record with no relationships at all reports nothing', () {
      expect(
        readCategoryRelationships({'type': 'appInfos', 'id': 'x'}),
        isEmpty,
      );
    });

    test('all six slots are read, not just the two this tool writes', () {
      // The subcategories are the exposure. cux_ship never writes them, so if
      // omitting a relationship cleared it, they are where it would show —
      // and a check that only looked at the two managed ones would miss it.
      final reported = readCategoryRelationships(
        _appInfo({
          'primaryCategory': 'PHOTO_AND_VIDEO',
          'primarySubcategoryOne': 'PHOTO_AND_VIDEO_A',
          'primarySubcategoryTwo': 'PHOTO_AND_VIDEO_B',
          'secondaryCategory': 'SPORTS',
          'secondarySubcategoryOne': 'SPORTS_A',
          'secondarySubcategoryTwo': 'SPORTS_B',
        }),
      );
      expect(reported.keys, containsAll(categoryRelationshipNames));
    });
  });

  group('deciding whether anything moved', () {
    test('nothing moved is the expected outcome, and reports nothing', () {
      const held = {
        'primaryCategory': 'PHOTO_AND_VIDEO',
        'secondaryCategory': 'SPORTS',
        'primarySubcategoryOne': 'PHOTO_AND_VIDEO_A',
      };
      expect(
        unrequestedCategoryChanges(
          before: held,
          after: held,
          declared: {'primaryCategory'},
        ),
        isEmpty,
      );
    });

    test('a subcategory cleared by an unrelated write is caught', () {
      // The whole reason this exists: a PATCH naming primaryCategory that
      // silently emptied a slot it never mentioned.
      expect(
        unrequestedCategoryChanges(
          before: const {
            'primaryCategory': 'PHOTO_AND_VIDEO',
            'primarySubcategoryOne': 'PHOTO_AND_VIDEO_A',
          },
          after: const {
            'primaryCategory': 'PHOTO_AND_VIDEO',
            'primarySubcategoryOne': null,
          },
          declared: {'primaryCategory'},
        ),
        ['primarySubcategoryOne'],
      );
    });

    test('the undeclared *other* category is watched too', () {
      expect(
        unrequestedCategoryChanges(
          before: const {
            'primaryCategory': 'PHOTO_AND_VIDEO',
            'secondaryCategory': 'SPORTS',
          },
          after: const {
            'primaryCategory': 'NAVIGATION',
            'secondaryCategory': null,
          },
          declared: {'primaryCategory'},
        ),
        ['secondaryCategory'],
      );
    });

    test('a declared relationship changing is the point, not a warning', () {
      // It changed because the tree asked it to. Reporting that would train
      // whoever reads it to ignore the message that matters.
      expect(
        unrequestedCategoryChanges(
          before: const {'primaryCategory': 'PHOTO_AND_VIDEO'},
          after: const {'primaryCategory': 'NAVIGATION'},
          declared: {'primaryCategory'},
        ),
        isEmpty,
      );
    });

    test('a relationship absent from either reading is not compared', () {
      // Absence is not evidence of a change, the same way it is not evidence
      // of a match. A sparse response must not manufacture a warning.
      expect(
        unrequestedCategoryChanges(
          before: const {'secondaryCategory': 'SPORTS'},
          after: const {},
          declared: {'primaryCategory'},
        ),
        isEmpty,
      );
      expect(
        unrequestedCategoryChanges(
          before: const {},
          after: const {'secondaryCategory': 'SPORTS'},
          declared: {'primaryCategory'},
        ),
        isEmpty,
      );
    });

    test('several moving at once are all named', () {
      expect(
        unrequestedCategoryChanges(
          before: const {
            'primaryCategory': 'PHOTO_AND_VIDEO',
            'primarySubcategoryOne': 'A',
            'primarySubcategoryTwo': 'B',
            'secondaryCategory': 'SPORTS',
          },
          after: const {
            'primaryCategory': 'PHOTO_AND_VIDEO',
            'primarySubcategoryOne': null,
            'primarySubcategoryTwo': null,
            'secondaryCategory': null,
          },
          declared: {'primaryCategory'},
        ),
        ['primarySubcategoryOne', 'primarySubcategoryTwo', 'secondaryCategory'],
      );
    });

    test('a value appearing where there was none counts as moved', () {
      // Unlikely, but "changed" is the question, not "was cleared" — a
      // check that only looked for clearing would miss Apple writing
      // something of its own.
      expect(
        unrequestedCategoryChanges(
          before: const {'secondarySubcategoryOne': null},
          after: const {'secondarySubcategoryOne': 'SPORTS_A'},
          declared: {'primaryCategory'},
        ),
        ['secondarySubcategoryOne'],
      );
    });
  });
}
