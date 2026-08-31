// SPDX-License-Identifier: Apache-2.0
//
// Deciding what needs writing is what lets a publish stop demanding an
// editable record it was never going to touch. It is also the single most
// silent thing in this package: a comparison that is wrong in one field skips
// a write and reports success. fastlane shipped exactly that — #21657
// compared the wrong attribute name, so privacy-URL changes were decided to
// be no-ops and never uploaded, and nothing anywhere said so.
//
// Hence a test per field, and a test per *reason* a field can be decided
// equal: because it matched, or because nothing could be read.
import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:cux_ship_verify/metadata.dart';
import 'package:test/test.dart';

/// An `appInfos` record as the collection read returns it, with the
/// `?include=primaryCategory,secondaryCategory` linkage the comparison needs.
Map<String, dynamic> _appInfo({
  Object? primary = _absent,
  Object? secondary = _absent,
}) => {
  'type': 'appInfos',
  'id': 'info-1',
  'attributes': {'appStoreState': 'PREPARE_FOR_SUBMISSION'},
  'relationships': {
    if (!identical(primary, _absent)) ...{
      'primaryCategory': {
        'data': primary == null
            ? null
            : {'type': 'appCategories', 'id': primary},
      },
    },
    if (!identical(secondary, _absent)) ...{
      'secondaryCategory': {
        'data': secondary == null
            ? null
            : {'type': 'appCategories', 'id': secondary},
      },
    },
  },
};

/// A relationship as the read *without* the include returns it: links only,
/// no `data` key at all.
Map<String, dynamic> _appInfoWithoutInclude() => {
  'type': 'appInfos',
  'id': 'info-1',
  'attributes': {'appStoreState': 'PREPARE_FOR_SUBMISSION'},
  'relationships': {
    'primaryCategory': {
      'links': {'self': 'https://example.invalid/primaryCategory'},
    },
  },
};

const _absent = Object();

Map<String, dynamic> _declaration(Map<String, Object?> attributes) => {
  'type': 'ageRatingDeclarations',
  'id': 'decl-1',
  'attributes': attributes,
};

Map<String, dynamic> _localization(
  String locale,
  Map<String, String> attributes,
) => {
  'type': 'appInfoLocalizations',
  'id': 'loc-$locale',
  'attributes': {'locale': locale, ...attributes},
};

AppStoreMetadata _metadata({
  Map<String, String> categories = const {},
  Map<String, Object?>? ageRating,
  String? contentRights,
  Map<String, Map<String, String>> appInfoText = const {},
}) {
  final metadata = AppStoreMetadata()
    ..contentRights = contentRights
    ..ageRating = ageRating;
  metadata.categories.addAll(categories);
  for (final entry in appInfoText.entries) {
    metadata.locales.add(
      LocaleMetadata(entry.key)..appInfo.addAll(entry.value),
    );
  }
  return metadata;
}

AppLevelChanges _changes({
  required AppStoreMetadata metadata,
  String? currentContentRights,
  Map<String, dynamic>? appInfo,
  Map<String, dynamic>? ageRatingDeclaration,
  List<Map<String, dynamic>>? appInfoLocalizations,
}) => appLevelChanges(
  metadata: metadata,
  currentContentRights: currentContentRights,
  appInfo: appInfo,
  ageRatingDeclaration: ageRatingDeclaration,
  appInfoLocalizations: appInfoLocalizations,
);

void main() {
  group('categories', () {
    test('a category that already matches is not written', () {
      final changes = _changes(
        metadata: _metadata(
          categories: {'primaryCategory': 'HEALTH_AND_FITNESS'},
        ),
        appInfo: _appInfo(primary: 'HEALTH_AND_FITNESS'),
      );
      expect(changes.categories, isEmpty);
      expect(changes.unverifiable, isEmpty);
      expect(changes.needsAppInfo, isFalse);
    });

    test('a category that differs is written', () {
      final changes = _changes(
        metadata: _metadata(categories: {'primaryCategory': 'NAVIGATION'}),
        appInfo: _appInfo(primary: 'HEALTH_AND_FITNESS'),
      );
      expect(changes.categories, {'primaryCategory': 'NAVIGATION'});
      expect(changes.needsAppInfo, isTrue);
    });

    test('each of the two is compared against its own relationship', () {
      // The #21657 shape: read the right key, or a secondary-category change
      // is silently decided to be a no-op. Only the secondary differs here,
      // and noticing it is the whole assertion.
      final changes = _changes(
        metadata: _metadata(
          categories: {
            'primaryCategory': 'HEALTH_AND_FITNESS',
            'secondaryCategory': 'NAVIGATION',
          },
        ),
        appInfo: _appInfo(primary: 'HEALTH_AND_FITNESS', secondary: 'SPORTS'),
      );
      expect(changes.categories, isNotEmpty);
      expect(changes.categories['secondaryCategory'], 'NAVIGATION');
    });

    test('one differing category sends the whole declared set', () {
      // Compared per field, sent whole, because the tree is the unit of
      // ownership. Not because partial relationship documents are avoided —
      // a tree declaring one category has always sent exactly one.
      final changes = _changes(
        metadata: _metadata(
          categories: {
            'primaryCategory': 'HEALTH_AND_FITNESS',
            'secondaryCategory': 'NAVIGATION',
          },
        ),
        appInfo: _appInfo(primary: 'HEALTH_AND_FITNESS', secondary: 'SPORTS'),
      );
      expect(changes.categories, {
        'primaryCategory': 'HEALTH_AND_FITNESS',
        'secondaryCategory': 'NAVIGATION',
      });
    });

    test('both matching still writes nothing', () {
      // The other half: sending the set whole must not mean sending it always.
      final changes = _changes(
        metadata: _metadata(
          categories: {
            'primaryCategory': 'HEALTH_AND_FITNESS',
            'secondaryCategory': 'NAVIGATION',
          },
        ),
        appInfo: _appInfo(
          primary: 'HEALTH_AND_FITNESS',
          secondary: 'NAVIGATION',
        ),
      );
      expect(changes.categories, isEmpty);
      expect(changes.needsAppInfo, isFalse);
    });

    test('an explicitly unset category is a reading, not an absence', () {
      // Apple spells "no secondary category" as `data: null`. That is an
      // answer, and it says the write is needed.
      final changes = _changes(
        metadata: _metadata(categories: {'secondaryCategory': 'NAVIGATION'}),
        appInfo: _appInfo(secondary: null),
      );
      expect(changes.categories, {'secondaryCategory': 'NAVIGATION'});
      expect(changes.unverifiable, isEmpty);
    });

    test('an unset category that nothing wants is left alone', () {
      final changes = _changes(
        metadata: _metadata(categories: {'primaryCategory': 'NAVIGATION'}),
        appInfo: _appInfo(primary: 'NAVIGATION', secondary: null),
      );
      expect(changes.isEmpty, isTrue);
    });

    test('a relationship with no data key is written, and named', () {
      // The bare collection read returns no `data` at all — verified against
      // a live account. It cannot be evidence of a match, so it is treated as
      // differing and the field is named.
      final changes = _changes(
        metadata: _metadata(categories: {'primaryCategory': 'NAVIGATION'}),
        appInfo: _appInfoWithoutInclude(),
      );
      expect(changes.categories, {'primaryCategory': 'NAVIGATION'});
      expect(changes.unverifiable, ['primaryCategory']);
      expect(changes.appInfoFields, contains('primaryCategory'));
    });

    test('no record at all means nothing can be shown to match', () {
      final changes = _changes(
        metadata: _metadata(categories: {'primaryCategory': 'NAVIGATION'}),
        appInfo: null,
      );
      expect(changes.categories, {'primaryCategory': 'NAVIGATION'});
      expect(changes.unverifiable, ['primaryCategory']);
    });
  });

  group('age rating', () {
    const answers = {'violenceCartoonOrFantasy': 'NONE', 'gambling': false};

    test('answers that all match are not written', () {
      final changes = _changes(
        metadata: _metadata(ageRating: answers),
        appInfo: _appInfo(),
        ageRatingDeclaration: _declaration({
          'violenceCartoonOrFantasy': 'NONE',
          'gambling': false,
          // Apple carries far more keys than the repository declares. They
          // are not this repository's to have an opinion about, and their
          // presence is not a difference.
          'alcoholTobaccoOrDrugUseOrReferences': 'NONE',
        }),
      );
      expect(changes.ageRating, isNull);
      expect(changes.needsAppInfo, isFalse);
    });

    test('one differing answer writes the whole declaration', () {
      // It is overwritten rather than merged, so the unit is the set.
      final changes = _changes(
        metadata: _metadata(ageRating: answers),
        appInfo: _appInfo(),
        ageRatingDeclaration: _declaration({
          'violenceCartoonOrFantasy': 'NONE',
          'gambling': true,
        }),
      );
      expect(changes.ageRating?.declarationId, 'decl-1');
      expect(changes.ageRating?.values, answers);
    });

    test('a key Apple does not carry counts as differing', () {
      final changes = _changes(
        metadata: _metadata(ageRating: answers),
        appInfo: _appInfo(),
        ageRatingDeclaration: _declaration({
          'violenceCartoonOrFantasy': 'NONE',
        }),
      );
      expect(changes.ageRating, isNotNull);
    });

    test('the id written to is the id compared against', () {
      // One field rather than two that must agree: an id with no answers and
      // answers with no id are both meaningless.
      final changes = _changes(
        metadata: _metadata(ageRating: answers),
        appInfo: _appInfo(),
        ageRatingDeclaration: {
          'type': 'ageRatingDeclarations',
          'id': 'decl-other',
          'attributes': <String, Object?>{'gambling': true},
        },
      );
      expect(changes.ageRating?.declarationId, 'decl-other');
    });

    test('a declaration with no attributes is written, and named', () {
      final changes = _changes(
        metadata: _metadata(ageRating: answers),
        appInfo: _appInfo(),
        ageRatingDeclaration: {'type': 'ageRatingDeclarations', 'id': 'decl-1'},
      );
      expect(changes.ageRating, isNotNull);
      expect(changes.unverifiable, [ageRatingField]);
    });

    test('no declaration to write to is recorded, not dropped', () {
      // Nothing can be written, but the run must not quietly publish
      // everything else and leave a version Apple will refuse to review.
      final changes = _changes(
        metadata: _metadata(ageRating: answers),
        appInfo: _appInfo(),
        ageRatingDeclaration: null,
      );
      expect(changes.ageRating, isNull);
      expect(changes.unverifiable, [ageRatingField]);
      expect(changes.needsAppInfo, isTrue);
    });

    test('a null answer Apple never reported is not a match', () {
      // The three-state collapse that hides in the one comparison where both
      // sides can legitimately be null. `age-rating.json` is arbitrary JSON,
      // so a declared answer may be null — and a `!=` alone would then read
      // an attribute Apple omitted as `null == null`, call it unchanged, and
      // skip the write on the strength of a reading that never happened.
      final changes = _changes(
        metadata: _metadata(ageRating: const {'gambling': null}),
        appInfo: _appInfo(),
        ageRatingDeclaration: _declaration({'violenceCartoon': 'NONE'}),
      );
      expect(changes.ageRating, isNotNull);
    });

    test('a null answer Apple did report as null does match', () {
      // The other half: `data` present and null is an answer, and answers
      // that agree are not a write.
      final changes = _changes(
        metadata: _metadata(ageRating: const {'gambling': null}),
        appInfo: _appInfo(),
        ageRatingDeclaration: _declaration({'gambling': null}),
      );
      expect(changes.ageRating, isNull);
    });

    test('a repository with no age rating asks for nothing', () {
      final changes = _changes(
        metadata: _metadata(),
        appInfo: _appInfo(),
        ageRatingDeclaration: null,
      );
      expect(changes.ageRating, isNull);
      expect(changes.unverifiable, isEmpty);
    });
  });

  group('localizations', () {
    test('a locale that already matches is not written', () {
      final changes = _changes(
        metadata: _metadata(
          appInfoText: {
            'en-US': {'name': 'Hold The Wheel', 'subtitle': 'Drive'},
          },
        ),
        appInfo: _appInfo(),
        appInfoLocalizations: [
          _localization('en-US', {
            'name': 'Hold The Wheel',
            'subtitle': 'Drive',
          }),
        ],
      );
      expect(changes.localizations, isEmpty);
      expect(changes.needsAppInfo, isFalse);
    });

    test('only the attributes that differ are written', () {
      final changes = _changes(
        metadata: _metadata(
          appInfoText: {
            'en-US': {'name': 'Hold The Wheel', 'subtitle': 'Drive better'},
          },
        ),
        appInfo: _appInfo(),
        appInfoLocalizations: [
          _localization('en-US', {
            'name': 'Hold The Wheel',
            'subtitle': 'Drive',
          }),
        ],
      );
      expect(changes.localizations, {
        'en-US': {'subtitle': 'Drive better'},
      });
    });

    test('a changed privacy policy URL is noticed', () {
      // fastlane's #21657 verbatim: the field whose comparison was wrong, so
      // the change was silently never uploaded.
      final changes = _changes(
        metadata: _metadata(
          appInfoText: {
            'en-US': {'privacyPolicyUrl': 'https://example.invalid/new'},
          },
        ),
        appInfo: _appInfo(),
        appInfoLocalizations: [
          _localization('en-US', {
            'privacyPolicyUrl': 'https://example.invalid/old',
          }),
        ],
      );
      expect(changes.localizations, {
        'en-US': {'privacyPolicyUrl': 'https://example.invalid/new'},
      });
    });

    test('each locale is compared against its own record', () {
      final changes = _changes(
        metadata: _metadata(
          appInfoText: {
            'en-US': {'name': 'Hold The Wheel'},
            'de-DE': {'name': 'Halt Das Lenkrad'},
          },
        ),
        appInfo: _appInfo(),
        appInfoLocalizations: [
          _localization('de-DE', {'name': 'Etwas Anderes'}),
          _localization('en-US', {'name': 'Hold The Wheel'}),
        ],
      );
      expect(changes.localizations, {
        'de-DE': {'name': 'Halt Das Lenkrad'},
      });
    });

    test('a locale with no record yet is created, and is not unverifiable', () {
      // Absence was read here, not assumed.
      final changes = _changes(
        metadata: _metadata(
          appInfoText: {
            'fr-FR': {'name': 'Tiens Le Volant'},
          },
        ),
        appInfo: _appInfo(),
        appInfoLocalizations: const [],
      );
      expect(changes.localizations, {
        'fr-FR': {'name': 'Tiens Le Volant'},
      });
      expect(changes.unverifiable, isEmpty);
    });

    test('localizations that could not be read are written, and named', () {
      final changes = _changes(
        metadata: _metadata(
          appInfoText: {
            'en-US': {'name': 'Hold The Wheel', 'subtitle': 'Drive'},
          },
        ),
        appInfo: null,
        appInfoLocalizations: null,
      );
      expect(changes.localizations, {
        'en-US': {'name': 'Hold The Wheel', 'subtitle': 'Drive'},
      });
      expect(changes.unverifiable, ['en-US name, subtitle']);
    });

    test(
      'a locale carrying only version fields asks for no app-level write',
      () {
        final metadata = AppStoreMetadata();
        metadata.locales.add(
          LocaleMetadata('en-US')..version['description'] = 'A driving app.',
        );
        final changes = _changes(
          metadata: metadata,
          appInfo: _appInfo(),
          appInfoLocalizations: const [],
        );
        expect(changes.localizations, isEmpty);
        expect(changes.needsAppInfo, isFalse);
      },
    );
  });

  group('content rights', () {
    test('a matching declaration is not written', () {
      final changes = _changes(
        metadata: _metadata(contentRights: 'DOES_NOT_USE_THIRD_PARTY_CONTENT'),
        currentContentRights: 'DOES_NOT_USE_THIRD_PARTY_CONTENT',
        appInfo: _appInfo(),
      );
      expect(changes.contentRights, isNull);
      expect(changes.isEmpty, isTrue);
    });

    test('a differing declaration is written', () {
      final changes = _changes(
        metadata: _metadata(contentRights: 'USES_THIRD_PARTY_CONTENT'),
        currentContentRights: 'DOES_NOT_USE_THIRD_PARTY_CONTENT',
        appInfo: _appInfo(),
      );
      expect(changes.contentRights, 'USES_THIRD_PARTY_CONTENT');
    });

    test('an unanswered declaration is written', () {
      // Apple returns null until somebody answers, and a null one makes the
      // version unreviewable with an error that says only "this resource
      // cannot be reviewed".
      final changes = _changes(
        metadata: _metadata(contentRights: 'USES_THIRD_PARTY_CONTENT'),
        currentContentRights: null,
        appInfo: _appInfo(),
      );
      expect(changes.contentRights, 'USES_THIRD_PARTY_CONTENT');
    });

    test('a repository that does not manage it writes nothing', () {
      final changes = _changes(
        metadata: _metadata(),
        currentContentRights: 'USES_THIRD_PARTY_CONTENT',
        appInfo: _appInfo(),
      );
      expect(changes.contentRights, isNull);
    });

    test('it never demands an appInfos record', () {
      // The load-bearing half: it is an attribute of the *app*, so a run
      // whose only change is content rights must not fail for want of a
      // record it was never going to touch — not even when there are no
      // records at all.
      final changes = _changes(
        metadata: _metadata(contentRights: 'USES_THIRD_PARTY_CONTENT'),
        currentContentRights: null,
        appInfo: null,
        appInfoLocalizations: null,
      );
      expect(changes.contentRights, 'USES_THIRD_PARTY_CONTENT');
      expect(changes.needsAppInfo, isFalse);
      expect(changes.isEmpty, isFalse);
    });

    test('an unreadable current value never lands in unverifiable', () {
      // Because `unverifiable` forces the acquisition, and this field must
      // not be able to force it.
      final changes = _changes(
        metadata: _metadata(contentRights: 'USES_THIRD_PARTY_CONTENT'),
        currentContentRights: null,
        appInfo: _appInfo(),
      );
      expect(changes.unverifiable, isEmpty);
    });
  });

  group('the whole diff', () {
    test('a listing that already matches writes nothing at all', () {
      final changes = _changes(
        metadata: _metadata(
          categories: {'primaryCategory': 'NAVIGATION'},
          ageRating: const {'gambling': false},
          contentRights: 'DOES_NOT_USE_THIRD_PARTY_CONTENT',
          appInfoText: {
            'en-US': {'name': 'Hold The Wheel'},
          },
        ),
        currentContentRights: 'DOES_NOT_USE_THIRD_PARTY_CONTENT',
        appInfo: _appInfo(primary: 'NAVIGATION'),
        ageRatingDeclaration: _declaration({'gambling': false}),
        appInfoLocalizations: [
          _localization('en-US', {'name': 'Hold The Wheel'}),
        ],
      );
      expect(changes.isEmpty, isTrue);
      expect(changes.appInfoFields, isEmpty);
    });

    test('everything that would be written is named once', () {
      final changes = _changes(
        metadata: _metadata(
          categories: {'primaryCategory': 'NAVIGATION'},
          ageRating: const {'gambling': false},
          appInfoText: {
            'en-US': {'name': 'Hold The Wheel'},
          },
        ),
        appInfo: _appInfoWithoutInclude(),
        ageRatingDeclaration: _declaration({'gambling': true}),
        appInfoLocalizations: const [],
      );
      // primaryCategory appears in both `categories` and `unverifiable`, and
      // a refusal should name it once.
      expect(changes.appInfoFields, [
        'primaryCategory',
        ageRatingField,
        'en-US name',
      ]);
    });
  });
}
