// SPDX-License-Identifier: Apache-2.0

// Everything here runs with no credentials and no network, which is the
// property that makes `asc_upload --metadata --dry-run` usable as an offline
// lint. Each case below is a rejection Apple would otherwise deliver *after*
// the screenshots had gone up one at a time.
import 'dart:io';
import 'dart:typed_data';

import 'package:cux_ship_verify/metadata.dart';
import 'package:test/test.dart';

import 'video_fixture.dart';

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

/// A minimal JPEG: SOI, then a start-of-frame carrying the dimensions.
///
/// [marker] is the SOFn, and it is a parameter because sample precision is not
/// free of it: SOF0 is baseline and 8-bit by definition, and 12 bits is legal
/// only under an extended sequential or progressive frame — SOF1 or SOF2 in
/// the Huffman-coded case. A 12-bit SOF0 fixture would be a file no encoder can
/// produce, so the cases that need depth 12 pass 0xC1 with it.
Uint8List jpeg({
  required int width,
  required int height,
  int depth = 8,
  int marker = 0xC0,
}) => Uint8List.fromList([
  0xFF, 0xD8, // SOI
  0xFF, marker, // SOFn
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

    test('a 12-bit JPEG is accepted, because the depth rule is PNG-only', () {
      // Every justification under the depth check is PNG's: Play states a
      // depth for PNG and none for JPEG, the set Apple was observed refusing
      // was a PNG, and `screenshots flatten` cannot open a JPEG at all — it
      // would throw, and through the CLI it would skip the file and exit 0,
      // leaving this refusal standing. Refusing here would be a rule with no
      // observed failure and no working remedy.
      //
      // SOF1, because 12 bits is illegal under the baseline SOF0.
      writeValidTree();
      File(
        '${_root.path}/listings/en-US/screenshots/APP_IPHONE_67/01-ride.png',
      ).deleteSync();
      writeBytes(
        'listings/en-US/screenshots/APP_IPHONE_67/01-ride.jpg',
        jpeg(width: 1290, height: 2796, depth: 12, marker: 0xC1),
      );
      expect(load, returnsNormally);
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

  // Everything in this group is a rejection Apple delivers *after* the video
  // has been uploaded, from an ingestion queue it documents as taking up to
  // twenty-four hours — during which the version cannot be submitted. That
  // asymmetry is why a preview is worth checking harder than a screenshot: a
  // refused screenshot costs a re-upload, a refused preview costs a day.
  group('previews', () {
    void writePreview(
      String path, {
      int width = 886,
      int height = 1920,
      double frameRate = 30,
      double seconds = 20,
      String codec = 'avc1',
    }) => writeBytes(
      path,
      mp4(
        width: width,
        height: height,
        frameRate: frameRate,
        seconds: seconds,
        codec: codec,
      ),
    );

    test('a preview and its poster frame load together', () {
      writeValidTree();
      writePreview('listings/en-US/previews/IPHONE_67/01-tour.mp4');
      write(
        'listings/en-US/previews/IPHONE_67/01-tour.mp4$previewTimeCodeSuffix',
        '00:00:02:06',
      );

      final previews = load().locales.single.previews['IPHONE_67']!;
      expect(previews, hasLength(1));
      expect(previews.single.frameTimeCode, '00:00:02:06');
    });

    test('a preview with no sidecar carries a null, not a default', () {
      // The null is the whole point: the uploader says "defaulting to
      // 00:00:05:00" for this and names the chosen frame for the other, and a
      // model that filled it in here would make those indistinguishable at the
      // one place the difference is worth saying out loud.
      writeValidTree();
      writePreview('listings/en-US/previews/IPHONE_67/01-tour.mp4');
      expect(
        load().locales.single.previews['IPHONE_67']!.single.frameTimeCode,
        isNull,
      );
    });

    test('a screenshot slot name is refused with the difference named', () {
      // `APP_IPHONE_67` is the *screenshot* enum. Apple keeps two separate
      // enumerations and the preview one has no prefix, so this is the typo
      // somebody makes once and cannot see.
      writeValidTree();
      writePreview('listings/en-US/previews/APP_IPHONE_67/01-tour.mp4');
      expect(
        load,
        throwsMetadata(
          allOf(
            contains('not a PreviewType'),
            contains('IPHONE_67, not APP_IPHONE_67'),
          ),
        ),
      );
    });

    test('a device-resolution capture is refused with the real size', () {
      // 1290x2796 is a real iPhone screen and a valid *screenshot* size, and
      // it is not a preview size — Apple's preview sizes are not device
      // resolutions at all. Capturing at the device's own size is the
      // ordinary way to get this wrong, so the error says the number.
      writeValidTree();
      writePreview(
        'listings/en-US/previews/IPHONE_67/01-tour.mp4',
        width: 1290,
        height: 2796,
      );
      expect(
        load,
        throwsMetadata(allOf(contains('1290x2796'), contains('886x1920'))),
      );
    });

    test(
      'a Mac preview in portrait is refused, where an iPhone one is not',
      () {
        // The transpose is legal for a phone and not for a Mac, which is the
        // one rule a shared spec with the screenshot loader would have lost.
        writeValidTree();
        writePreview(
          'listings/en-US/previews/DESKTOP/01-tour.mp4',
          width: 1080,
          height: 1920,
        );
        expect(load, throwsMetadata(contains('landscape only')));
      },
    );

    test('a Mac preview in landscape loads', () {
      writeValidTree();
      writePreview(
        'listings/en-US/previews/DESKTOP/01-tour.mp4',
        width: 1920,
        height: 1080,
      );
      expect(load, returnsNormally);
    });

    test('the codec, duration and frame rate each say which one is wrong', () {
      for (final broken in [
        (
          'listings/en-US/previews/IPHONE_67/01-tour.mp4',
          {'codec': 'hvc1'},
          'HEVC',
        ),
        (
          'listings/en-US/previews/IPHONE_67/01-tour.mp4',
          {'seconds': 8.0},
          '15s to 30s',
        ),
        (
          'listings/en-US/previews/IPHONE_67/01-tour.mp4',
          {'frameRate': 60.0},
          'fps',
        ),
      ]) {
        _root.deleteSync(recursive: true);
        _root = Directory.systemTemp.createTempSync('asc_metadata_test');
        writeValidTree();
        final options = broken.$2;
        writePreview(
          broken.$1,
          codec: options['codec'] as String? ?? 'avc1',
          seconds: options['seconds'] as double? ?? 20,
          frameRate: options['frameRate'] as double? ?? 30,
        );
        expect(
          load,
          throwsMetadata(contains(broken.$3)),
          reason: 'the message has to name ${broken.$3}',
        );
      }
    });

    test('a fourth preview is refused, where a fourth screenshot is not', () {
      // Ten screenshots per slot and three previews. Apple refuses the fourth
      // at reservation — after the first three have already gone up.
      writeValidTree();
      for (final name in ['01', '02', '03', '04']) {
        writePreview('listings/en-US/previews/IPHONE_67/$name.mp4');
      }
      expect(load, throwsMetadata(contains('1 to 3')));
    });

    test('previews sort into the order Apple will show them', () {
      writeValidTree();
      for (final name in ['03-finish', '01-start', '02-climb']) {
        writePreview('listings/en-US/previews/IPHONE_67/$name.mp4');
      }
      final previews = load().locales.single.previews['IPHONE_67']!;
      expect(previews.map((p) => p.file.uri.pathSegments.last), [
        '01-start.mp4',
        '02-climb.mp4',
        '03-finish.mp4',
      ]);
    });

    test('a malformed timecode says what the shape is', () {
      writeValidTree();
      writePreview('listings/en-US/previews/IPHONE_67/01-tour.mp4');
      write(
        'listings/en-US/previews/IPHONE_67/01-tour.mp4$previewTimeCodeSuffix',
        '2.2',
      );
      expect(load, throwsMetadata(contains('HH:MM:SS:FF')));
    });

    test('a frame number past the end of a second is refused', () {
      // **The field the format is named for was the one not checked.** Minutes
      // and seconds were range-checked and FF was not, so 00:00:02:99 passed
      // every offline check on a 30 fps video — and because it resolves to
      // 5.3s it is comfortably inside the file, so the past-the-end check did
      // not fire either. Apple takes it and rejects the frame a day later,
      // which is precisely the cost this file exists to avoid.
      writeValidTree();
      writePreview('listings/en-US/previews/IPHONE_67/01-tour.mp4');
      write(
        'listings/en-US/previews/IPHONE_67/01-tour.mp4$previewTimeCodeSuffix',
        '00:00:02:99',
      );
      expect(load, throwsMetadata(contains('frame within one second')));
    });

    test('the last frame of a second is accepted', () {
      // 30 fps is frames 0..29, and refusing 29 would be this check inventing
      // a rule — the same failure direction as refusing a valid size.
      writeValidTree();
      writePreview('listings/en-US/previews/IPHONE_67/01-tour.mp4');
      write(
        'listings/en-US/previews/IPHONE_67/01-tour.mp4$previewTimeCodeSuffix',
        '00:00:02:29',
      );
      expect(load, returnsNormally);
    });

    test('a poster frame past the end of the video is refused', () {
      // Apple takes the string and the poster silently falls back, so this
      // surfaces as a product page posing on the wrong frame — after
      // approval, when it can no longer be changed without a new submission.
      writeValidTree();
      writePreview(
        'listings/en-US/previews/IPHONE_67/01-tour.mp4',
        seconds: 20,
      );
      write(
        'listings/en-US/previews/IPHONE_67/01-tour.mp4$previewTimeCodeSuffix',
        '00:00:25:00',
      );
      expect(load, throwsMetadata(contains('past the end')));
    });

    test('an orphaned poster frame is refused rather than ignored', () {
      // Somebody renamed the video. The sidecar is not an unused file: it is
      // a deliberate choice of frame now applying to nothing, and the preview
      // it was meant for would go up posed at Apple's five-second default
      // with nothing said.
      writeValidTree();
      writePreview('listings/en-US/previews/IPHONE_67/01-tour.mp4');
      write(
        'listings/en-US/previews/IPHONE_67/01-old.mp4$previewTimeCodeSuffix',
        '00:00:02:06',
      );
      expect(load, throwsMetadata(contains('names no video here')));
    });

    test('an empty sidecar names the default it would silently accept', () {
      writeValidTree();
      writePreview('listings/en-US/previews/IPHONE_67/01-tour.mp4');
      write(
        'listings/en-US/previews/IPHONE_67/01-tour.mp4$previewTimeCodeSuffix',
        '   ',
      );
      expect(load, throwsMetadata(contains(defaultPreviewFrameTimeCode)));
    });

    test('something that is not a video is refused', () {
      writeValidTree();
      writeBytes('listings/en-US/previews/IPHONE_67/01-tour.mp4', [1, 2, 3, 4]);
      expect(load, throwsMetadata(contains('not a readable MP4 or QuickTime')));
    });

    test('a tree of previews alone is still a locale worth publishing', () {
      // [LocaleMetadata.isEmpty] decides whether a directory becomes a locale
      // at all, and a preview-only locale that reported itself empty would be
      // dropped before anything looked at it.
      writePreview('listings/en-US/previews/IPHONE_67/01-tour.mp4');
      expect(load().locales, hasLength(1));
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
      expect(
        readImageInfo(
          jpeg(width: 8, height: 8, depth: 12, marker: 0xC1),
        )!.bitDepth,
        12,
      );
    });

    test('reports which container it read', () {
      // The depth rule applies to one of these and not the other, so the two
      // have to be tellable apart after parsing.
      expect(readImageInfo(png(width: 1, height: 1))!.format, ImageFormat.png);
      expect(
        readImageInfo(jpeg(width: 8, height: 8))!.format,
        ImageFormat.jpeg,
      );
    });

    test('returns null for anything else', () {
      expect(readImageInfo([0, 1, 2, 3]), isNull);
    });

    test('the depth rule is PNG-only under either store\'s rules', () {
      // Pinned on the function rather than through one tree, because the
      // loader case above exercises Apple's rules only and the Play tree and
      // uploader share this call. A PNG-only gate that held for one
      // `StoreImageRules` and not the other would pass that case.
      final deepJpeg = readImageInfo(
        jpeg(width: 8, height: 8, depth: 12, marker: 0xC1),
      )!;
      final deepPng = readImageInfo(png(width: 1, height: 1, depth: 16))!;
      for (final rules in [appStoreImageRules, playImageRules]) {
        expect(imageEncodingProblem(deepJpeg, rules), isNull);
        expect(
          imageEncodingProblem(deepPng, rules),
          contains('16 bits per channel'),
          reason: 'the control: the same depth in a PNG is still refused',
        );
      }
    });
  });
}
