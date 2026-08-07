// SPDX-License-Identifier: Apache-2.0
//
// These run against fixtures, which is the right thing *here* — this package's
// job is the checking, and the checking is what wants exercising. The real
// files stay in the consumer, whose own suite calls these functions against
// them. The two halves are only worth anything together.
import 'dart:io';
import 'dart:typed_data';

import 'package:cux_ship_verify/cux_ship_verify.dart';
import 'package:test/test.dart';

/// A PNG header good enough for the metadata loader: signature, a complete
/// IHDR, then IEND. Deliberately not a real image — nothing decodes pixels.
Uint8List png({
  required int width,
  required int height,
  int colourType = 2, // truecolour, no alpha
}) {
  final bytes = <int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
    ...be32(13), ...'IHDR'.codeUnits,
    ...be32(width), ...be32(height),
    8, colourType, 0, 0, 0,
    ...be32(0), // CRC, unchecked
    ...be32(0), ...'IEND'.codeUnits, ...be32(0),
  ];
  return Uint8List.fromList(bytes);
}

List<int> be32(int value) => [
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
];

late Directory _root;

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

void writeValidTree() {
  write('info/primary_category.txt', 'HEALTH_AND_FITNESS');
  write('listings/en-US/name.txt', 'An App');
  write('listings/en-US/subtitle.txt', 'It does a thing');
  write('listings/en-US/description.txt', 'A longer account of the thing.');
  write('listings/en-US/keywords.txt', 'one,two');
  writeBytes(
    'listings/en-US/screenshots/APP_IPHONE_67/01.png',
    png(width: 1290, height: 2796),
  );
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cux_ship_verify_test');
  });

  tearDown(() {
    _root.deleteSync(recursive: true);
  });

  group('checkChangelog', () {
    test('a changelog within every limit has nothing to report', () {
      const markdown = '## 1.1.0\n\n- Something small\n\n## 1.0.0\n\n- First\n';
      expect(checkChangelog(markdown), isEmpty);
    });

    test('an over-long section names the version, platform and both counts', () {
      final markdown = '## 1.0.0\n\n- ${'x' * 600}\n';
      final problems = checkChangelog(markdown);

      // Only Play's 500 is exceeded; the App Store's 4000 is not, and reporting
      // it would be noise.
      expect(problems, hasLength(1));
      expect(problems.single.where, contains('1.0.0'));
      expect(problems.single.where, contains('android'));
      expect(problems.single.message, contains('500'));
      expect(problems.single.message, contains('602'));
    });

    test('every over-long version is reported, not just the first', () {
      // The reason these come back as a list: told one at a time, the second
      // is found only after the first is fixed and pushed.
      final markdown =
          '## 2.0.0\n\n- ${'x' * 600}\n\n## 1.0.0\n\n- ${'y' * 600}\n';
      final versions = checkChangelog(
        markdown,
      ).map((p) => p.where).where((w) => w.contains('android'));
      expect(versions, hasLength(2));
    });

    test('a platform-filtered section is measured after filtering', () {
      // The android entry is short; the ios one would be over on its own. Only
      // ios should be reported, which is only true if filtering happens first.
      final markdown = '## 1.0.0\n\n- [android] Short\n- [ios] ${'x' * 4100}\n';
      final problems = checkChangelog(markdown);
      expect(problems, hasLength(1));
      expect(problems.single.where, contains('ios'));
    });

    test('a changelog with no version headings is itself a problem', () {
      // Silently checking nothing is the exact failure this guards against.
      const prose = '# Changelog\n\nSome notes about nothing in particular.\n';
      final problems = checkChangelog(prose);
      expect(problems, hasLength(1));
      expect(problems.single.message, contains('no version headings'));
    });

    test('a heading that is prose is not taken for a version', () {
      const markdown = '## Unreleased\n\n- Nothing\n\n## 1.0.0\n\n- First\n';
      expect(changelogVersions(markdown), ['1.0.0']);
    });

    test('a bracketed, dated heading is a version', () {
      const markdown = '## [1.4.0] - 2026-08-05\n\n- Something\n';
      expect(changelogVersions(markdown), ['1.4.0']);
    });

    test('the limits are overridable', () {
      const markdown = '## 1.0.0\n\n- Twelve chars\n';
      expect(checkChangelog(markdown, limits: {'android': 5}), hasLength(1));
      expect(checkChangelog(markdown, limits: {'android': 500}), isEmpty);
    });
  });

  group('checkChangelogFile', () {
    test('reads and checks the file', () {
      write('CHANGELOG.md', '## 1.0.0\n\n- First\n');
      expect(checkChangelogFile('${_root.path}/CHANGELOG.md'), isEmpty);
    });

    test('a missing file is reported rather than thrown', () {
      // A consumer calling this from a test wants a named failure, not a
      // FileSystemException from inside a group body.
      final problems = checkChangelogFile('${_root.path}/nope.md');
      expect(problems, hasLength(1));
      expect(problems.single.message, contains('no such file'));
    });
  });

  group('checkAppStoreTree', () {
    test('a well-formed tree has nothing to report', () {
      writeValidTree();
      expect(checkAppStoreTree(_root.path), isEmpty);
    });

    test('what the loader refuses becomes a problem, not an exception', () {
      // The alpha channel is the check most likely to fire in practice.
      writeValidTree();
      writeBytes(
        'listings/en-US/screenshots/APP_IPHONE_67/01.png',
        png(width: 1290, height: 2796, colourType: 6),
      );
      final problems = checkAppStoreTree(_root.path);
      expect(problems, hasLength(1));
      expect(problems.single.message, contains('alpha channel'));
    });

    test('a missing directory is reported', () {
      final problems = checkAppStoreTree('${_root.path}/nope');
      expect(problems, hasLength(1));
      expect(problems.single.message, contains('no such metadata directory'));
    });

    test('a required screenshot type that is absent is named', () {
      // A universal app must carry an iPad set as well as an iPhone one, and
      // Apple refuses the submission rather than the upload.
      writeValidTree();
      final problems = checkAppStoreTree(
        _root.path,
        requireScreenshotTypes: {'APP_IPHONE_67', 'APP_IPAD_PRO_3GEN_129'},
      );
      expect(problems, hasLength(1));
      expect(problems.single.message, contains('APP_IPAD_PRO_3GEN_129'));
      expect(problems.single.where, contains('en-US'));
    });

    test('a required screenshot type that is present is accepted', () {
      writeValidTree();
      expect(
        checkAppStoreTree(
          _root.path,
          requireScreenshotTypes: {'APP_IPHONE_67'},
        ),
        isEmpty,
      );
    });

    test('a missing required locale is named', () {
      writeValidTree();
      final problems = checkAppStoreTree(
        _root.path,
        requireLocales: {'en-US', 'de-DE'},
      );
      expect(problems, hasLength(1));
      expect(problems.single.message, contains('de-DE'));
    });

    test('screenshot requirements apply only to the required locales', () {
      // A second locale part-way through translation should not fail the
      // build for want of its own screenshots.
      writeValidTree();
      write('listings/de-DE/name.txt', 'Eine App');
      write('listings/de-DE/description.txt', 'Eine längere Beschreibung.');
      expect(
        checkAppStoreTree(
          _root.path,
          requireScreenshotTypes: {'APP_IPHONE_67'},
          requireLocales: {'en-US'},
        ),
        isEmpty,
      );
    });
  });
}
