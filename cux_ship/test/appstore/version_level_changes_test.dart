// SPDX-License-Identifier: Apache-2.0
//
// The app-level half compares before writing, and so do screenshots. The
// version-level text did not: a run whose tree had not changed still rewrote
// the copyright, the review notes and five localized strings with identical
// values. It was found by a consuming project running `--listing-only
// --dry-run` after upgrading and reading its own output.
//
// Harmless per request, which is why it lasted — and seven more chances to
// exit non-zero having already written something, which is the failure shape
// the rest of this package is built around. The principle did not stop at the
// set boundary on purpose; it stopped where the bugs did.
import 'dart:io';

import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:cux_ship_verify/metadata.dart';
import 'package:test/test.dart';

Map<String, dynamic> _version({String? copyright}) => {
  'type': 'appStoreVersions',
  'id': 'v1',
  'attributes': {'versionString': '1.1.0', 'copyright': ?copyright},
};

Map<String, dynamic> _localization(
  String locale,
  Map<String, String> attributes,
) => {
  'type': 'appStoreVersionLocalizations',
  'id': 'loc-$locale',
  'attributes': {'locale': locale, ...attributes},
};

Map<String, dynamic> _reviewDetail(Map<String, String> attributes) => {
  'type': 'appStoreReviewDetails',
  'id': 'rd-1',
  'attributes': attributes,
};

const _contact = ReviewContact(
  firstName: 'Ada',
  lastName: 'Lovelace',
  email: 'ada@example.invalid',
  phone: '+100000000',
);

Map<String, String> _contactAttributes() => _contact.attributes;

AppStoreMetadata _metadata({
  String? copyright,
  String? reviewNotes,
  Map<String, Map<String, String>> text = const {},
}) {
  final metadata = AppStoreMetadata()
    ..copyright = copyright
    ..reviewNotes = reviewNotes;
  for (final entry in text.entries) {
    metadata.locales.add(
      LocaleMetadata(entry.key)..version.addAll(entry.value),
    );
  }
  return metadata;
}

VersionLevelChanges _changes({
  required AppStoreMetadata metadata,
  Map<String, dynamic>? version,
  List<Map<String, dynamic>> localizations = const [],
  Map<String, dynamic>? reviewDetail,
  ReviewContact? contact,
}) => versionLevelChanges(
  metadata: metadata,
  version: version ?? _version(),
  localizations: localizations,
  reviewDetail: reviewDetail,
  contact: contact,
);

void main() {
  group('does the tree declare version text', () {
    // The line that says "already matches" was gated on `copyright != null`,
    // which is true of the tree it was written against and false of a tree
    // carrying a description and no copyright — which would then print
    // nothing and read as though the comparison had not run. The same
    // undercount `listingNeedsVersion` shipped with, one release apart.
    test('copyright alone counts', () {
      expect(declaresVersionText(_metadata(copyright: '© 2026')), isTrue);
    });

    test('review notes alone count', () {
      expect(declaresVersionText(_metadata(reviewNotes: 'Log in.')), isTrue);
    });

    test('listing text alone counts', () {
      expect(
        declaresVersionText(
          _metadata(
            text: {
              'en-US': {'description': 'Ride better.'},
            },
          ),
        ),
        isTrue,
      );
    });

    test('a tree with none of them does not', () {
      final metadata = AppStoreMetadata();
      metadata.locales.add(LocaleMetadata('en-US')..appInfo['name'] = 'Ride');
      expect(declaresVersionText(metadata), isFalse);
    });
  });

  group('copyright', () {
    test('an unchanged copyright is not rewritten', () {
      expect(
        _changes(
          metadata: _metadata(copyright: '© 2026 Codeux'),
          version: _version(copyright: '© 2026 Codeux'),
        ).copyright,
        isNull,
      );
    });

    test('a changed copyright is written', () {
      expect(
        _changes(
          metadata: _metadata(copyright: '© 2027 Codeux'),
          version: _version(copyright: '© 2026 Codeux'),
        ).copyright,
        '© 2027 Codeux',
      );
    });

    test('a copyright Apple did not report is written, not assumed', () {
      expect(
        _changes(
          metadata: _metadata(copyright: '© 2026 Codeux'),
          version: _version(),
        ).copyright,
        '© 2026 Codeux',
      );
    });

    test('a tree that does not manage it writes nothing', () {
      expect(
        _changes(
          metadata: _metadata(),
          version: _version(copyright: 'x'),
        ).copyright,
        isNull,
      );
    });
  });

  group('listing text', () {
    test('identical text is not rewritten', () {
      // The case the consuming project hit: nothing changed since the last
      // publish, and five fields went up again anyway.
      final changes = _changes(
        metadata: _metadata(
          text: {
            'en-US': {
              'description': 'Ride better.',
              'keywords': 'cycling,ride',
              'supportUrl': 'https://example.invalid/support',
            },
          },
        ),
        localizations: [
          _localization('en-US', {
            'description': 'Ride better.',
            'keywords': 'cycling,ride',
            'supportUrl': 'https://example.invalid/support',
          }),
        ],
      );
      expect(changes.localizations, isEmpty);
      expect(changes.isEmpty, isTrue);
    });

    test('only the fields that differ are written', () {
      final changes = _changes(
        metadata: _metadata(
          text: {
            'en-US': {'description': 'Ride better.', 'keywords': 'new,words'},
          },
        ),
        localizations: [
          _localization('en-US', {
            'description': 'Ride better.',
            'keywords': 'cycling,ride',
          }),
        ],
      );
      expect(changes.localizations, {
        'en-US': {'keywords': 'new,words'},
      });
    });

    test('each locale is compared against its own record', () {
      final changes = _changes(
        metadata: _metadata(
          text: {
            'en-US': {'description': 'Ride better.'},
            'de-DE': {'description': 'Fahr besser.'},
          },
        ),
        localizations: [
          _localization('de-DE', {'description': 'Etwas anderes.'}),
          _localization('en-US', {'description': 'Ride better.'}),
        ],
      );
      expect(changes.localizations.keys, ['de-DE']);
    });

    test('a locale with no record yet is created, and is not unverifiable', () {
      final changes = _changes(
        metadata: _metadata(
          text: {
            'fr-FR': {'description': 'Roulez mieux.'},
          },
        ),
        localizations: const [],
      );
      expect(changes.localizations, {
        'fr-FR': {'description': 'Roulez mieux.'},
      });
    });

    test('a locale carrying only app-level text asks for no version write', () {
      final metadata = AppStoreMetadata();
      metadata.locales.add(LocaleMetadata('en-US')..appInfo['name'] = 'Ride');
      expect(_changes(metadata: metadata).localizations, isEmpty);
    });
  });

  group('review details', () {
    test('unchanged notes and contact are not rewritten', () {
      expect(
        _changes(
          metadata: _metadata(reviewNotes: 'Log in as demo.'),
          reviewDetail: _reviewDetail({
            'notes': 'Log in as demo.',
            ..._contactAttributes(),
          }),
          contact: _contact,
        ).reviewDetails,
        isNull,
      );
    });

    test('changed notes are written', () {
      expect(
        _changes(
          metadata: _metadata(reviewNotes: 'Log in as demo2.'),
          reviewDetail: _reviewDetail({
            'notes': 'Log in as demo.',
            ..._contactAttributes(),
          }),
          contact: _contact,
        ).reviewDetails?.notes,
        'Log in as demo2.',
      );
    });

    test('a changed contact is written even when the notes match', () {
      // The contact goes with every write, so it is part of what unchanged
      // means. Comparing the notes alone would skip a run whose only change
      // was the reviewer's phone number.
      expect(
        _changes(
          metadata: _metadata(reviewNotes: 'Log in as demo.'),
          reviewDetail: _reviewDetail({
            'notes': 'Log in as demo.',
            ..._contactAttributes(),
            'contactPhone': '+199999999',
          }),
          contact: _contact,
        ).reviewDetails,
        isNotNull,
      );
    });

    test('no record yet means it is created', () {
      expect(
        _changes(
          metadata: _metadata(reviewNotes: 'Log in as demo.'),
          reviewDetail: null,
          contact: _contact,
        ).reviewDetails,
        isNotNull,
      );
    });

    test('an attribute Apple did not report is not a match', () {
      // The three-state reading: absent is neither the value nor a mismatch
      // to be assumed away. Here Apple reports no contact at all.
      expect(
        _changes(
          metadata: _metadata(reviewNotes: 'Log in as demo.'),
          reviewDetail: _reviewDetail({'notes': 'Log in as demo.'}),
          contact: _contact,
        ).reviewDetails,
        isNotNull,
      );
    });

    test('the value compared is the value sent, not the file on disk', () {
      // **The hazard, closed by the loader and pinned here.**
      // `review-notes.md` carries a repository-facing half below a marker
      // that never reaches Apple, so the file is far longer than the field:
      // measured downstream at 5838 characters on disk against 2867 stored.
      //
      // A comparison that diffed the file against `appStoreReviewDetail.notes`
      // would differ on every run for ever, on any tree using the marker —
      // and it would fail in the *safe* direction, so it would never look
      // like a bug, only like a feature that quietly never fires.
      //
      // It cannot happen, because `loadMetadata` puts the processed text in
      // `metadata.reviewNotes` and the same value is handed to the writer. A
      // fixture without a marker would pass either way, which is why this one
      // has one.
      final dir = Directory.systemTemp.createTempSync('cux_review_notes');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}${Platform.pathSeparator}review-notes.md')
        ..writeAsStringSync(
          'Log in as demo.\n\n'
          '$reviewNotesMarker\n\n'
          '# Maintaining these notes\n\nNot for Apple.\n',
        );

      final facing = readReviewNotes(file);
      expect(facing, 'Log in as demo.');
      expect(facing.length, lessThan(file.readAsStringSync().length));

      // Apple holds what was sent — the processed half — so nothing differs.
      expect(
        _changes(
          metadata: _metadata(reviewNotes: facing),
          reviewDetail: _reviewDetail({
            'notes': facing,
            ..._contactAttributes(),
          }),
          contact: _contact,
        ).reviewDetails,
        isNull,
      );
    });

    test('a tree with no review notes asks for nothing', () {
      expect(
        _changes(metadata: _metadata(), reviewDetail: null).reviewDetails,
        isNull,
      );
    });
  });

  test('a version whose text already matches writes nothing at all', () {
    final changes = _changes(
      metadata: _metadata(
        copyright: '© 2026 Codeux',
        reviewNotes: 'Log in as demo.',
        text: {
          'en-US': {'description': 'Ride better.'},
        },
      ),
      version: _version(copyright: '© 2026 Codeux'),
      localizations: [
        _localization('en-US', {'description': 'Ride better.'}),
      ],
      reviewDetail: _reviewDetail({
        'notes': 'Log in as demo.',
        ..._contactAttributes(),
      }),
      contact: _contact,
    );
    expect(changes.isEmpty, isTrue);
  });
}
