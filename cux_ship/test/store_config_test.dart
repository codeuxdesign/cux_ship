// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:cux_ship/src/config.dart';
import 'package:cux_ship/src/project.dart';
import 'package:test/test.dart';

ProjectConfig _read(String yaml) {
  final dir = Directory.systemTemp.createTempSync('cux_ship_store_config');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('${dir.path}/$cuxShipConfigFile').writeAsStringSync(yaml);
  return ProjectConfig.read(dir.path);
}

/// A pbxproj fragment carrying [families] on every build configuration, the way
/// Xcode writes it.
String _pbxproj(List<String> families) =>
    families.map((f) => '\t\t\t\tTARGETED_DEVICE_FAMILY = "$f";\n').join();

void main() {
  group('store blocks', () {
    test('an absent block is null, not empty', () {
      // The distinction is the whole signal: null means this project does not
      // publish there, empty means it does and has declared nothing.
      final config = _read('app-dir: app\n');
      expect(config.appstore, isNull);
      expect(config.play, isNull);
    });

    test('a declared block with no keys is empty, not null', () {
      final config = _read('appstore:\n  locales: []\n');
      expect(config.appstore, isNotNull);
      expect(config.appstore!.locales, isEmpty);
    });

    test('reads locales', () {
      final config = _read('play:\n  locales: [en-US, de-DE]\n');
      expect(config.play!.locales, {'en-US', 'de-DE'});
    });

    test("reads the App Store's per-platform screenshots", () {
      final config = _read('''
appstore:
  locales: [en-US]
  screenshots:
    ios: [APP_IPHONE_67]
    macos: [APP_DESKTOP]
''');
      expect(config.appstore!.screenshotsFor('ios'), {'APP_IPHONE_67'});
      expect(config.appstore!.screenshotsFor('macos'), {'APP_DESKTOP'});
    });

    test("reads Play's flat screenshot list", () {
      final config = _read('''
play:
  locales: [en-US]
  screenshots: [phoneScreenshots]
''');
      // Play has no platform axis, so the list answers for any platform asked.
      expect(config.play!.screenshotsFor(StoreConfig.anyPlatform), {
        'phoneScreenshots',
      });
    });

    test('an unknown key inside a block is refused', () {
      expect(
        () => _read('appstore:\n  locales: [en-US]\n  screenshot: []\n'),
        throwsA(
          isA<ProjectException>().having(
            (e) => e.message,
            'message',
            allOf(contains('appstore'), contains('screenshot')),
          ),
        ),
      );
    });

    test('a non-string entry is refused rather than stringified', () {
      expect(
        () => _read('play:\n  locales: [en-US, 42]\n'),
        throwsA(isA<ProjectException>()),
      );
    });

    test('locales that is not a list is refused', () {
      expect(
        () => _read('play:\n  locales: en-US\n'),
        throwsA(isA<ProjectException>()),
      );
    });
  });

  group('required screenshot types', () {
    test('a universal app needs an iPad set as well as an iPhone one', () {
      final project = ProjectContext(root: '/', targetedDeviceFamily: '1,2');
      expect(project.requiredScreenshotTypes('ios'), {
        'APP_IPHONE_67',
        'APP_IPAD_PRO_3GEN_129',
      });
    });

    test('an iPhone-only app needs no iPad set', () {
      final project = ProjectContext(root: '/', targetedDeviceFamily: '1');
      expect(project.requiredScreenshotTypes('ios'), {'APP_IPHONE_67'});
    });

    test('macOS is a constant rather than a lookup', () {
      // There is no TARGETED_DEVICE_FAMILY on macOS. Two mechanisms behind one
      // word, and saying so is what stops the macOS half being built later as
      // "no inference available".
      final project = ProjectContext(root: '/');
      expect(project.requiredScreenshotTypes('macos'), {'APP_DESKTOP'});
    });

    test('nothing derivable yields null rather than an empty requirement', () {
      // Null and {} are different answers: {} would silently require nothing,
      // which is the shape this whole change exists to remove.
      final project = ProjectContext(root: '/');
      expect(project.requiredScreenshotTypes('ios'), isNull);
    });
  });

  group('TARGETED_DEVICE_FAMILY', () {
    test('reads one value repeated across configurations', () {
      final dir = Directory.systemTemp.createTempSync('cux_ship_family');
      addTearDown(() => dir.deleteSync(recursive: true));
      Directory('${dir.path}/ios/Runner.xcodeproj').createSync(recursive: true);
      File(
        '${dir.path}/ios/Runner.xcodeproj/project.pbxproj',
      ).writeAsStringSync(_pbxproj(['1,2', '1,2', '1,2']));

      final project = ProjectContext.read(repoRoot: dir.path);
      expect(project.targetedDeviceFamily, '1,2');
      expect(project.targetedDeviceFamilyProblem, isNull);
    });

    test('refuses a project that names two different families', () {
      // The same multi-target shape that forced PRODUCT_BUNDLE_IDENTIFIER's
      // handling: an extension carries its own, and taking the first match
      // answers a question about the app with a value belonging to something
      // else.
      final dir = Directory.systemTemp.createTempSync('cux_ship_family');
      addTearDown(() => dir.deleteSync(recursive: true));
      Directory('${dir.path}/ios/Runner.xcodeproj').createSync(recursive: true);
      File(
        '${dir.path}/ios/Runner.xcodeproj/project.pbxproj',
      ).writeAsStringSync(_pbxproj(['1,2', '1']));

      final project = ProjectContext.read(repoRoot: dir.path);
      expect(project.targetedDeviceFamily, isNull);
      expect(
        project.targetedDeviceFamilyProblem,
        allOf(contains('2 device families'), contains('appstore.screenshots')),
      );
    });

    test('skips a value Xcode expands at build time', () {
      final dir = Directory.systemTemp.createTempSync('cux_ship_family');
      addTearDown(() => dir.deleteSync(recursive: true));
      Directory('${dir.path}/ios/Runner.xcodeproj').createSync(recursive: true);
      File(
        '${dir.path}/ios/Runner.xcodeproj/project.pbxproj',
      ).writeAsStringSync(
        '\t\t\t\tTARGETED_DEVICE_FAMILY = "\$(INHERITED)";\n'
        '${_pbxproj(['1,2'])}',
      );

      final project = ProjectContext.read(repoRoot: dir.path);
      expect(project.targetedDeviceFamily, '1,2');
    });
  });
}
