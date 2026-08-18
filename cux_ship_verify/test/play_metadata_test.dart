// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:cux_ship_verify/cux_ship_verify.dart';
import 'package:test/test.dart';

/// A minimal valid PNG of the given size, built by hand.
///
/// `readImageInfo` reads the IHDR and nothing else, so a real encoder is not
/// needed — and pulling one in would cost this package the zero dependencies
/// that are the reason it can live in a consumer's dev_dependencies.
List<int> _png(int width, int height) {
  void be32(List<int> out, int value) => out.addAll([
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ]);
  final bytes = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  be32(bytes, 13);
  bytes.addAll('IHDR'.codeUnits);
  be32(bytes, width);
  be32(bytes, height);
  bytes.addAll([8, 2, 0, 0, 0]); // 8-bit RGB, no alpha
  be32(bytes, 0);
  return bytes;
}

/// Builds a Play tree and returns its path.
Directory _tree({
  required Map<String, Map<String, String>> locales,
  Map<String, Map<String, List<({int w, int h})>>> images = const {},
  String? defaultLanguage,
}) {
  final dir = Directory.systemTemp.createTempSync('cux_ship_play');
  addTearDown(() => dir.deleteSync(recursive: true));

  if (defaultLanguage != null) {
    Directory('${dir.path}/details').createSync(recursive: true);
    File(
      '${dir.path}/details/default_language.txt',
    ).writeAsStringSync('$defaultLanguage\n');
  }

  for (final entry in locales.entries) {
    final base = '${dir.path}/listings/${entry.key}';
    Directory(base).createSync(recursive: true);
    for (final field in entry.value.entries) {
      File('$base/${field.key}.txt').writeAsStringSync('${field.value}\n');
    }
    for (final type
        in images[entry.key]?.entries ??
            const <MapEntry<String, List<({int w, int h})>>>[]) {
      final d = Directory('$base/images/${type.key}')
        ..createSync(recursive: true);
      for (var i = 0; i < type.value.length; i++) {
        File(
          '${d.path}/0$i.png',
        ).writeAsBytesSync(_png(type.value[i].w, type.value[i].h));
      }
    }
  }
  return dir;
}

/// The text every valid locale needs.
const _text = {
  'title': 'Hold the Wheel',
  'short_description': 'A cycling physics simulation.',
  'full_description': 'What it costs to hold a wheel, and why.',
};

const _icon = (w: 512, h: 512);
const _feature = (w: 1024, h: 500);
const _phone = (w: 1080, h: 2424); // 2.244:1 — a real, published shape.

Map<String, List<({int w, int h})>> get _fullImages => {
  'icon': [_icon],
  'featureGraphic': [_feature],
  'phoneScreenshots': [_phone, _phone],
};

void main() {
  group('a complete single-locale tree', () {
    test('passes', () {
      final dir = _tree(
        locales: {'en-US': _text},
        images: {'en-US': _fullImages},
        defaultLanguage: 'en-US',
      );
      expect(
        checkPlayTree(
          dir.path,
          requireLocales: {'en-US'},
          requireScreenshotTypes: {'phoneScreenshots'},
        ),
        isEmpty,
      );
    });

    test('a 20:9 phone screenshot is accepted', () {
      // Regression, and the reason no aspect-ratio rule exists. Play's
      // published "longest side at most twice the shortest" would refuse this,
      // and listings carrying exactly this shape are live today.
      final dir = _tree(
        locales: {'en-US': _text},
        images: {
          'en-US': {
            'icon': [_icon],
            'featureGraphic': [_feature],
            'phoneScreenshots': [(w: 1080, h: 2424), (w: 1080, h: 2424)],
          },
        },
      );
      expect(checkPlayTree(dir.path), isEmpty);
    });
  });

  group('localized graphics fall back to the default language', () {
    test('a text-only second locale is accepted', () {
      // The shape that matters: `de-DE/` with translated text and no images of
      // its own inherits en-US's, and Play serves it. Demanding an icon per
      // locale would fail a tree the store accepts.
      final dir = _tree(
        locales: {'en-US': _text, 'de-DE': _text},
        images: {'en-US': _fullImages},
        defaultLanguage: 'en-US',
      );
      expect(
        checkPlayTree(
          dir.path,
          requireLocales: {'en-US', 'de-DE'},
          requireScreenshotTypes: {'phoneScreenshots'},
        ),
        isEmpty,
      );
    });

    test('the default language itself must carry them', () {
      final dir = _tree(
        locales: {'en-US': _text, 'de-DE': _text},
        images: {'de-DE': _fullImages},
        defaultLanguage: 'en-US',
      );
      expect(
        checkPlayTree(dir.path).map((p) => p.message),
        contains(contains('no icon/ image')),
      );
    });

    test('a locale may override some types and inherit the rest', () {
      // The shape between the two obvious ones: `de-DE/` has its own
      // screenshots and no graphics, so it overrides one and inherits two.
      // Nothing may demand the inherited ones of it.
      final dir = _tree(
        locales: {'en-US': _text, 'de-DE': _text},
        images: {
          'en-US': _fullImages,
          'de-DE': {
            'phoneScreenshots': [_phone, _phone],
          },
        },
        defaultLanguage: 'en-US',
      );
      expect(
        checkPlayTree(
          dir.path,
          requireLocales: {'en-US', 'de-DE'},
          requireScreenshotTypes: {'phoneScreenshots'},
        ),
        isEmpty,
      );
    });

    test('an image a non-default locale does override is still checked', () {
      // The mirror-image risk of the fix above: skipping the *requirement* for
      // an inheriting locale must not skip the rules for what it actually
      // carries. A wrongly sized override publishes; it is not inherited away.
      final dir = _tree(
        locales: {'en-US': _text, 'de-DE': _text},
        images: {
          'en-US': _fullImages,
          'de-DE': {
            'icon': [(w: 256, h: 256)],
          },
        },
        defaultLanguage: 'en-US',
      );
      expect(
        checkPlayTree(dir.path).map((p) => p.message),
        contains(allOf(contains('256x256'), contains('512x512'))),
      );
    });

    test('a fallback that lacks the graphics is the one blamed', () {
      final dir = _tree(
        locales: {'en-US': _text, 'de-DE': _text},
        images: {'de-DE': _fullImages},
        defaultLanguage: 'en-US',
      );
      final problems = checkPlayTree(dir.path);
      expect(problems.map((p) => p.where), everyElement(contains('en-US')));
    });

    test('two locales and no default language reports that, and only that', () {
      // The whole finding, in one assertion. An earlier revision treated
      // *every* locale as the fallback when none could be determined, on the
      // theory that checking more was the safe direction. It reported three
      // missing images against `de-DE` — a locale that was fine — alongside
      // the real defect, so acting on the output meant adding an icon to a
      // translation that never needed one and still having the problem.
      //
      // Same rule as the App Store platform selection: when the answer cannot
      // be determined, say so rather than picking and blaming the consequences
      // of the pick.
      final dir = _tree(
        locales: {'en-US': _text, 'de-DE': _text},
        images: {'en-US': _fullImages},
      );
      final problems = checkPlayTree(
        dir.path,
        requireScreenshotTypes: {'phoneScreenshots'},
      );
      expect(problems, hasLength(1));
      expect(problems.single.message, contains('which one supplies the icon'));
    });
  });

  group('Play limits', () {
    test('an over-long short description is reported with both numbers', () {
      final dir = _tree(
        locales: {
          'en-US': {..._text, 'short_description': 'x' * 81},
        },
        images: {'en-US': _fullImages},
      );
      expect(
        checkPlayTree(dir.path).map((p) => p.message),
        contains(allOf(contains('81 characters'), contains('80'))),
      );
    });

    // Each of the three below survived a mutation of its own limit — raise the
    // number and nothing failed. They are here as a set rather than one at a
    // time because the gap had a shape: in both pairs the *sibling* was
    // covered, so the file read as tested. `short_description` was pinned and
    // `title` and `full_description` were not; the screenshot floor was pinned
    // and the ceiling was not.
    test('an over-long title is reported with both numbers', () {
      final dir = _tree(
        locales: {
          'en-US': {..._text, 'title': 'x' * 31},
        },
        images: {'en-US': _fullImages},
      );
      expect(
        checkPlayTree(dir.path).map((p) => p.message),
        contains(allOf(contains('31 characters'), contains('30'))),
      );
    });

    test('an over-long full description is reported with both numbers', () {
      final dir = _tree(
        locales: {
          'en-US': {..._text, 'full_description': 'x' * 4001},
        },
        images: {'en-US': _fullImages},
      );
      expect(
        checkPlayTree(dir.path).map((p) => p.message),
        contains(allOf(contains('4001 characters'), contains('4000'))),
      );
    });

    test('more screenshots than Play accepts is refused', () {
      final dir = _tree(
        locales: {'en-US': _text},
        images: {
          'en-US': {..._fullImages, 'phoneScreenshots': List.filled(9, _phone)},
        },
      );
      expect(
        checkPlayTree(dir.path).map((p) => p.message),
        contains(allOf(contains('9 images'), contains('8'))),
      );
    });

    test('a wrongly sized icon is refused', () {
      final dir = _tree(
        locales: {'en-US': _text},
        images: {
          'en-US': {
            ..._fullImages,
            'icon': [(w: 256, h: 256)],
          },
        },
      );
      expect(
        checkPlayTree(dir.path).map((p) => p.message),
        contains(allOf(contains('256x256'), contains('512x512'))),
      );
    });

    test('a screenshot below the minimum edge is refused', () {
      final dir = _tree(
        locales: {'en-US': _text},
        images: {
          'en-US': {
            ..._fullImages,
            'phoneScreenshots': [(w: 200, h: 400), (w: 200, h: 400)],
          },
        },
      );
      expect(
        checkPlayTree(dir.path).map((p) => p.message),
        contains(contains('at least 320')),
      );
    });

    test('an unknown image directory is reported, not ignored', () {
      final dir = _tree(
        locales: {'en-US': _text},
        images: {
          'en-US': {
            ..._fullImages,
            'phoneScreenshot': [_phone],
          },
        },
      );
      expect(
        checkPlayTree(dir.path).map((p) => p.message),
        contains(contains('not a directory Play publishes')),
      );
    });
  });

  group("this package's own floor", () {
    test('applies to a declared type with one image', () {
      final dir = _tree(
        locales: {'en-US': _text},
        images: {
          'en-US': {
            ..._fullImages,
            'phoneScreenshots': [_phone],
          },
        },
      );
      expect(
        checkPlayTree(
          dir.path,
          requireScreenshotTypes: {'phoneScreenshots'},
        ).map((p) => p.message),
        contains(allOf(contains('reads as unfinished'), contains("tool's"))),
      );
    });

    test('does not apply to a type nobody declared', () {
      // Play accepts a single wear screenshot. Failing it would be this package
      // inventing a rule and enforcing it against a live store.
      final dir = _tree(
        locales: {'en-US': _text},
        images: {
          'en-US': {
            ..._fullImages,
            'wearScreenshots': [_phone],
          },
        },
      );
      expect(checkPlayTree(dir.path), isEmpty);
    });
  });

  group('locales', () {
    test('a declared locale the tree lacks is refused', () {
      final dir = _tree(
        locales: {'en-US': _text},
        images: {'en-US': _fullImages},
      );
      expect(
        checkPlayTree(
          dir.path,
          requireLocales: {'en-US', 'fr-FR'},
        ).map((p) => p.message),
        contains(contains('required locale fr-FR')),
      );
    });

    test('an undeclared locale in the tree does not fail', () {
      // Settled the same way as checkAppStoreTree. An earlier draft reported
      // it, with a comment claiming it was "reported, not failed" — untrue,
      // since ReleaseProblem carries no severity and every caller fails on one.
      final dir = _tree(
        locales: {'en-US': _text, 'de-DE': _text},
        images: {'en-US': _fullImages},
        defaultLanguage: 'en-US',
      );
      expect(checkPlayTree(dir.path, requireLocales: {'en-US'}), isEmpty);
    });

    test('a default language the tree does not carry is refused', () {
      final dir = _tree(
        locales: {'en-US': _text},
        images: {'en-US': _fullImages},
        defaultLanguage: 'fr-FR',
      );
      expect(
        checkPlayTree(dir.path).map((p) => p.message),
        contains(contains('has no listings/fr-FR/')),
      );
    });
  });

  test('a tree with no listings/ says so', () {
    final dir = Directory.systemTemp.createTempSync('cux_ship_play_empty');
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(
      checkPlayTree(dir.path).single.message,
      contains('no listings/ directory'),
    );
  });
}
