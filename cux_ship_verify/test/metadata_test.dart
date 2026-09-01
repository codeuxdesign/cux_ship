// SPDX-License-Identifier: Apache-2.0

// Everything here runs with no credentials and no network, which is the
// property that makes `asc_upload --metadata --dry-run` usable as an offline
// lint. Each case below is a rejection Apple would otherwise deliver *after*
// the screenshots had gone up one at a time.
import 'dart:io';
import 'dart:typed_data';

import 'package:cux_ship_verify/metadata.dart';
import 'package:test/test.dart';

/// A PNG header good enough for [readImageInfo]: signature, a complete IHDR,
/// then the chunks the caller asked for and IEND.
///
/// Deliberately not a real image — nothing here decodes pixels, and a fixture
/// that had to be a valid image would have to be a binary file in the repo.
Uint8List png({
  required int width,
  required int height,
  int colourType = 2, // truecolour, no alpha
  int depth = 8, // bits per channel; 16 makes this a 48-bit PNG
  bool trns = false,
}) {
  final bytes = <int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
    ...be32(13), ...'IHDR'.codeUnits,
    ...be32(width), ...be32(height),
    depth, colourType, 0, 0, 0,
    ...be32(0), // CRC, unchecked
  ];
  if (trns) {
    bytes.addAll([...be32(2), ...'tRNS'.codeUnits, 0, 0, ...be32(0)]);
  }
  bytes.addAll([...be32(0), ...'IEND'.codeUnits, ...be32(0)]);
  return Uint8List.fromList(bytes);
}

List<int> be32(int value) => [
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
];

/// A minimal JPEG: SOI, then an SOF0 carrying the dimensions.
Uint8List jpeg({required int width, required int height, int depth = 8}) =>
    Uint8List.fromList([
      0xFF, 0xD8, // SOI
      0xFF, 0xC0, // SOF0
      0x00, 0x11, // segment length
      depth, // precision
      (height >> 8) & 0xFF, height & 0xFF,
      (width >> 8) & 0xFF, width & 0xFF,
      0x03, // components
      ...List.filled(9, 0),
    ]);

late Directory _root;

/// Writes `store/appstore/listings/en-US/<name>` under the temp tree.
void write(String relative, String contents) {
  final file = File('${_root.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

void writeBytes(String relative, List<int> contents) {
  final file = File('${_root.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(contents);
}

/// A tree that loads cleanly, so each test can break exactly one thing.
void writeValidTree() {
  write('info/primary_category.txt', 'HEALTH_AND_FITNESS');
  write('listings/en-US/name.txt', 'Hold the Wheel: Cycling Sim');
  write('listings/en-US/subtitle.txt', 'What mass and drafting cost');
  write('listings/en-US/description.txt', 'A simulation, not a game.');
  write('listings/en-US/keywords.txt', 'cycling,physics,drafting');
  write(
    'listings/en-US/privacy_policy_url.txt',
    'https://holdthewheel.app/privacy.html',
  );
  writeBytes(
    'listings/en-US/screenshots/APP_IPHONE_67/01-ride.png',
    png(width: 1290, height: 2796),
  );
}

AppStoreMetadata load() => loadMetadata(_root.path);

Matcher throwsMetadata(Object matcher) => throwsA(
  isA<MetadataException>().having((e) => e.message, 'message', matcher),
);

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('asc_metadata_test');
  });

  tearDown(() {
    _root.deleteSync(recursive: true);
  });

  group('a well-formed tree', () {
    test('loads every field into the resource it belongs to', () {
      writeValidTree();
      final metadata = load();

      expect(metadata.categories['primaryCategory'], 'HEALTH_AND_FITNESS');
      expect(metadata.locales, hasLength(1));

      final locale = metadata.locales.single;
      expect(locale.locale, 'en-US');
      // The appInfo/version split is the whole reason these are separate maps:
      // they go to different endpoints with different lifetimes.
      expect(locale.appInfo.keys, containsAll(['name', 'subtitle']));
      expect(locale.appInfo['privacyPolicyUrl'], contains('privacy.html'));
      expect(locale.version.keys, containsAll(['description', 'keywords']));
      expect(locale.version.containsKey('name'), isFalse);
      expect(locale.screenshots['APP_IPHONE_67'], hasLength(1));
    });

    test('subtitle.txt on its own is not a listing', () {
      // A tree carrying a subtitle and no name is half-written rather than
      // deliberately partial, and Apple will not accept it either.
      write('listings/en-US/subtitle.txt', 'Something');
      expect(load, throwsMetadata(contains('no name.txt')));
    });

    test('an absent file is left alone rather than blanked', () {
      // "Present means owned" — the tree carries no promotional_text.txt, so
      // nothing about promotional text is sent at all.
      writeValidTree();
      expect(
        load().locales.single.version.containsKey('promotionalText'),
        isFalse,
      );
    });
  });

  group('text limits', () {
    test('a 31-character name is refused', () {
      writeValidTree();
      write('listings/en-US/name.txt', 'x' * 31);
      expect(load, throwsMetadata(contains('31 characters')));
    });

    test('a 4001-character description is refused', () {
      writeValidTree();
      write('listings/en-US/description.txt', 'x' * 4001);
      expect(load, throwsMetadata(allOf(contains('4001'), contains('4000'))));
    });

    test('emoji count as the store counts them', () {
      // Apple counts UTF-16 code units, so a non-BMP emoji is two. Counting
      // runes instead would let a section through that the store then rejects.
      writeValidTree();
      write('listings/en-US/name.txt', '🚴' * 16); // 32 code units
      expect(load, throwsMetadata(contains('32 characters')));
    });

    test('an empty file is an error, not an empty value', () {
      writeValidTree();
      write('listings/en-US/name.txt', '   ');
      expect(load, throwsMetadata(contains('delete the file')));
    });
  });

  group('urls', () {
    test('http is refused before Apple flags it in review', () {
      writeValidTree();
      write('listings/en-US/support_url.txt', 'http://example.com');
      expect(load, throwsMetadata(contains('https')));
    });

    test('a non-URL is refused', () {
      writeValidTree();
      write('listings/en-US/support_url.txt', 'holdthewheel.app');
      expect(load, throwsMetadata(contains('https')));
    });

    test('support and marketing URLs belong to the version', () {
      writeValidTree();
      write('listings/en-US/support_url.txt', 'https://example.com/help');
      expect(
        load().locales.single.version['supportUrl'],
        'https://example.com/help',
      );
    });
  });

  group('categories', () {
    test('a lower-case category id is refused', () {
      // Apple ignores an unrecognised id rather than rejecting it, so a
      // lower-case one would silently leave the category unset.
      writeValidTree();
      write('info/primary_category.txt', 'health_and_fitness');
      expect(load, throwsMetadata(contains('upper case')));
    });
  });

  group('screenshots', () {
    test('an unknown display type names the ones that are known', () {
      writeValidTree();
      writeBytes(
        'listings/en-US/screenshots/APP_IPHONE_99/01.png',
        png(width: 1290, height: 2796),
      );
      expect(
        load,
        throwsMetadata(
          allOf(contains('APP_IPHONE_99'), contains('APP_IPHONE_67')),
        ),
      );
    });

    test('a wrong size names the sizes that would work', () {
      writeValidTree();
      writeBytes(
        'listings/en-US/screenshots/APP_IPHONE_67/01-ride.png',
        png(width: 1170, height: 2532),
      );
      expect(
        load,
        throwsMetadata(allOf(contains('1170x2532'), contains('1290x2796'))),
      );
    });

    test('landscape is the transpose of an accepted size', () {
      writeValidTree();
      writeBytes(
        'listings/en-US/screenshots/APP_IPHONE_67/01-ride.png',
        png(width: 2796, height: 1290),
      );
      expect(load, returnsNormally);
    });

    test('an alpha channel is refused', () {
      // The check most likely to fire in practice: a simulator screenshot
      // carries RGBA even when every pixel is opaque.
      writeValidTree();
      writeBytes(
        'listings/en-US/screenshots/APP_IPHONE_67/01-ride.png',
        png(width: 1290, height: 2796, colourType: 6),
      );
      expect(load, throwsMetadata(contains('alpha channel')));
    });

    test('a tRNS chunk counts as transparency too', () {
      writeValidTree();
      writeBytes(
        'listings/en-US/screenshots/APP_IPHONE_67/01-ride.png',
        png(width: 1290, height: 2796, trns: true),
      );
      expect(load, throwsMetadata(contains('alpha channel')));
    });

    test('16 bits per channel is refused', () {
      // A 48-bit PNG, which every dimension and alpha check here accepts and
      // Apple refuses at ingestion. It is not hypothetical: a macOS
      // `--no-chrome` capture writes depth 16, and `screenshots flatten`
      // preserves it — so the remedy for one failure produced a set the store
      // would not take.
      writeValidTree();
      writeBytes(
        'listings/en-US/screenshots/APP_IPHONE_67/01-ride.png',
        png(width: 1290, height: 2796, depth: 16),
      );
      expect(load, throwsMetadata(contains('16 bits per channel')));
    });

    test('more than ten is refused', () {
      writeValidTree();
      // Ten more alongside the one writeValidTree left, so eleven in total.
      for (var i = 2; i <= 11; i++) {
        writeBytes(
          'listings/en-US/screenshots/APP_IPHONE_67/'
          '${i.toString().padLeft(2, '0')}-extra.png',
          png(width: 1290, height: 2796),
        );
      }
      expect(load, throwsMetadata(contains('11 image')));
    });

    test('publish order follows filename order', () {
      // Apple shows screenshots in upload order, so the sort here is what a
      // user sees. Written out of order on purpose.
      writeValidTree();
      for (final name in ['04-d', '02-b', '03-c']) {
        writeBytes(
          'listings/en-US/screenshots/APP_IPHONE_67/$name.png',
          png(width: 1290, height: 2796),
        );
      }
      final files = load().locales.single.screenshots['APP_IPHONE_67']!;
      expect(files.map((f) => f.uri.pathSegments.last), [
        '01-ride.png',
        '02-b.png',
        '03-c.png',
        '04-d.png',
      ]);
    });

    test('a JPEG is accepted and has no alpha', () {
      writeValidTree();
      File(
        '${_root.path}/listings/en-US/screenshots/APP_IPHONE_67/01-ride.png',
      ).deleteSync();
      writeBytes(
        'listings/en-US/screenshots/APP_IPHONE_67/01-ride.jpg',
        jpeg(width: 1290, height: 2796),
      );
      expect(load, returnsNormally);
    });

    test('a file that is neither PNG nor JPEG is refused', () {
      writeValidTree();
      writeBytes('listings/en-US/screenshots/APP_IPHONE_67/02-broken.png', [
        1,
        2,
        3,
        4,
      ]);
      expect(load, throwsMetadata(contains('not a readable PNG or JPEG')));
    });
  });

  group('review-notes.md', () {
    test('stops at the marker, so an internal checklist stays internal', () {
      writeValidTree();
      write('review-notes.md', '''
# Notes for review

Start with the sample at <https://example.com/sample.zip>.

$reviewNotesMarker

- [ ] ask somebody whether this reads well
''');
      final notes = load().reviewNotes!;
      expect(notes, contains('Start with the sample'));
      // The half that would embarrass us. A reviewer reading our to-do list is
      // the failure the marker exists to make structural rather than remembered.
      expect(notes, isNot(contains('ask somebody')));
      expect(notes, isNot(contains(reviewNotesMarker)));
    });

    test('is plain text, because Apple renders none of the markdown', () {
      writeValidTree();
      write('review-notes.md', '''
# Heading

**Bold** and a link at <https://example.com/x.zip>.
''');
      final notes = load().reviewNotes!;
      expect(notes, startsWith('Heading'));
      expect(notes, contains('Bold and a link at https://example.com/x.zip.'));
      expect(notes, isNot(contains('**')));
      expect(notes, isNot(contains('<https')));
    });

    test('a file with no marker is all reviewer-facing', () {
      writeValidTree();
      write('review-notes.md', 'Everything here is for Apple.');
      expect(load().reviewNotes, 'Everything here is for Apple.');
    });

    test('over the limit fails here rather than after an upload', () {
      writeValidTree();
      write('review-notes.md', 'x' * (reviewNotesLimit + 1));
      expect(load, throwsMetadata(contains('review-notes.md')));
      expect(load, throwsMetadata(contains('$reviewNotesLimit')));
    });

    test('only the reviewer-facing half counts toward the limit', () {
      writeValidTree();
      write(
        'review-notes.md',
        '${'x' * 100}\n$reviewNotesMarker\n${'y' * reviewNotesLimit}',
      );
      expect(load().reviewNotes, hasLength(100));
    });

    test('a file that is entirely internal is refused, not silently empty', () {
      writeValidTree();
      write('review-notes.md', '$reviewNotesMarker\nall of it is internal');
      expect(load, throwsMetadata(contains('nothing above')));
    });

    test('absent is fine — not every project needs one', () {
      writeValidTree();
      expect(load().reviewNotes, isNull);
    });
  });

  group('age-rating.json', () {
    test('loads as attributes', () {
      writeValidTree();
      write('age-rating.json', '{"violenceCartoonOrFantasy": "NONE"}');
      expect(load().ageRating, {'violenceCartoonOrFantasy': 'NONE'});
    });

    test('invalid JSON says so', () {
      writeValidTree();
      write('age-rating.json', '{not json');
      expect(load, throwsMetadata(contains('not valid JSON')));
    });

    test('an empty object is refused rather than published', () {
      writeValidTree();
      write('age-rating.json', '{}');
      expect(load, throwsMetadata(contains('empty object')));
    });
  });

  group('the tree as a whole', () {
    test('a missing directory says which one', () {
      expect(
        () => loadMetadata('${_root.path}/nope'),
        throwsMetadata(contains('no such metadata directory')),
      );
    });

    test('an empty tree is refused rather than committing nothing', () {
      expect(load, throwsMetadata(contains('nothing to publish')));
    });
  });

  // A committed store/appstore tree used to be checked here, by the same code
  // that would check it at upload time — everything Apple validates late, and
  // above all the alpha channel every screen capture carries, caught when the
  // file is committed instead of after it has been uploaded one image at a
  // time. That guard has not been dropped; it moved.
  //
  // It read '../../store/appstore', which only resolved while this package sat
  // inside the app that owned that tree. Now that the package is its own
  // repository, the check lives in cux_ship_verify as checkAppStoreTree() and
  // the consumer calls it against its own tree from its own suite. Same code,
  // same real files — the reasoning that put it here in the first place is
  // exactly why it could not stay: a guard is worth nothing if it only ever
  // sees fixtures.

  group('readImageInfo', () {
    test('reads PNG dimensions and colour type', () {
      final info = readImageInfo(png(width: 640, height: 480))!;
      expect(info.width, 640);
      expect(info.height, 480);
      expect(info.hasAlpha, isFalse);
    });

    test('greyscale-with-alpha counts as alpha', () {
      expect(
        readImageInfo(png(width: 1, height: 1, colourType: 4))!.hasAlpha,
        isTrue,
      );
    });

    test('reads the PNG bit depth', () {
      // The IHDR byte before the colour type, and the one nothing read until
      // a 48-bit capture passed every check both stores have.
      expect(readImageInfo(png(width: 1, height: 1))!.bitDepth, 8);
      expect(readImageInfo(png(width: 1, height: 1, depth: 16))!.bitDepth, 16);
    });

    test('reads JPEG dimensions', () {
      final info = readImageInfo(jpeg(width: 800, height: 600))!;
      expect(info.width, 800);
      expect(info.height, 600);
    });

    test('reads the JPEG sample precision as the bit depth', () {
      // Same field, different name in the two formats. Read from the frame
      // header, one byte before the height the dimensions come from — so a
      // wrong offset here would show up as wrong dimensions too.
      expect(readImageInfo(jpeg(width: 8, height: 8))!.bitDepth, 8);
      expect(readImageInfo(jpeg(width: 8, height: 8, depth: 12))!.bitDepth, 12);
    });

    test('returns null for anything else', () {
      expect(readImageInfo([0, 1, 2, 3]), isNull);
    });
  });
}
