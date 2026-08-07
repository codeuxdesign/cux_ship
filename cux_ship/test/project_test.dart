// SPDX-License-Identifier: Apache-2.0
//
// Inference decides what gets published when no flag says otherwise, so a wrong
// guess here is a wrong app or a wrong version reaching a store. The
// confirmation prompt is the backstop, but only for somebody who reads it —
// and `--yes` skips it entirely.
import 'dart:io';

import 'package:cux_ship/src/project.dart';
import 'package:test/test.dart';

late Directory _root;

void write(String relative, String contents) {
  final file = File('${_root.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

ProjectContext read() => ProjectContext.read(_root.path);

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cux_ship_project_test');
  });

  tearDown(() {
    _root.deleteSync(recursive: true);
  });

  group('pubspec.yaml', () {
    test('splits version into marketing version and build number', () {
      write('pubspec.yaml', 'name: an_app\nversion: 1.2.3+41\n');
      expect(read().versionName, '1.2.3');
      expect(read().buildNumber, '41');
    });

    test('a version with no build number still yields the version', () {
      write('pubspec.yaml', 'name: an_app\nversion: 1.2.3\n');
      expect(read().versionName, '1.2.3');
      expect(read().buildNumber, isNull);
    });

    test('a version elsewhere in the file is not mistaken for the version', () {
      // `version:` appears under dependencies in plenty of pubspecs. Only a
      // top-level one is the app's, which is what the line anchor buys.
      write(
        'pubspec.yaml',
        'name: an_app\n'
            'version: 1.2.3+41\n'
            'dependencies:\n'
            '  something:\n'
            '    version: 9.9.9\n',
      );
      expect(read().versionName, '1.2.3');
    });

    test('no pubspec at all is not an error', () {
      expect(read().versionName, isNull);
    });
  });

  group('android', () {
    test('reads applicationId from build.gradle.kts', () {
      write(
        'android/app/build.gradle.kts',
        'android {\n'
            '    defaultConfig {\n'
            '        applicationId = "design.codeux.holdthewheel"\n'
            '    }\n'
            '}\n',
      );
      expect(read().androidPackage, 'design.codeux.holdthewheel');
    });

    test('reads the Groovy form too', () {
      // The older build.gradle spells it without the `=`.
      write(
        'android/app/build.gradle',
        'defaultConfig {\n'
            '    applicationId "design.codeux.holdthewheel"\n'
            '}\n',
      );
      expect(read().androidPackage, 'design.codeux.holdthewheel');
    });
  });

  group('ios', () {
    test('reads PRODUCT_BUNDLE_IDENTIFIER', () {
      write(
        'ios/Runner.xcodeproj/project.pbxproj',
        'PRODUCT_BUNDLE_IDENTIFIER = design.codeux.holdthewheel;\n',
      );
      expect(read().iosBundleId, 'design.codeux.holdthewheel');
    });

    test('the RunnerTests target does not win', () {
      // It appears first in a real pbxproj often enough that taking the first
      // match blindly would ship the test target's identifier.
      write(
        'ios/Runner.xcodeproj/project.pbxproj',
        'PRODUCT_BUNDLE_IDENTIFIER = design.codeux.holdthewheel.RunnerTests;\n'
            'PRODUCT_BUNDLE_IDENTIFIER = design.codeux.holdthewheel;\n',
      );
      expect(read().iosBundleId, 'design.codeux.holdthewheel');
    });

    test('quotes are stripped', () {
      write(
        'ios/Runner.xcodeproj/project.pbxproj',
        'PRODUCT_BUNDLE_IDENTIFIER = "design.codeux.holdthewheel";\n',
      );
      expect(read().iosBundleId, 'design.codeux.holdthewheel');
    });

    test('macos is read separately and can differ', () {
      write(
        'ios/Runner.xcodeproj/project.pbxproj',
        'PRODUCT_BUNDLE_IDENTIFIER = design.codeux.ios;\n',
      );
      write(
        'macos/Runner.xcodeproj/project.pbxproj',
        'PRODUCT_BUNDLE_IDENTIFIER = design.codeux.mac;\n',
      );
      expect(read().bundleIdFor('ios'), 'design.codeux.ios');
      expect(read().bundleIdFor('macos'), 'design.codeux.mac');
    });

    test('an absent iOS project yields null rather than throwing', () {
      expect(read().iosBundleId, isNull);
      expect(read().bundleIdFor('ios'), isNull);
    });
  });

  group('conventional paths', () {
    test('are offered only when they exist', () {
      expect(read().changelog, isNull);
      expect(read().appStoreMetadata, isNull);
      expect(read().playMetadata, isNull);
      expect(read().dataSafety, isNull);

      write('CHANGELOG.md', '## 1.0.0\n\n- First\n');
      write('store/appstore/info/primary_category.txt', 'HEALTH_AND_FITNESS');
      write('store/play/details/default_language.txt', 'en-US');
      write('store/play/data-safety.csv', 'a,b\n');

      final project = read();
      expect(project.changelog, endsWith('CHANGELOG.md'));
      expect(project.appStoreMetadata, endsWith('store/appstore'));
      expect(project.playMetadata, endsWith('store/play'));
      expect(project.dataSafety, endsWith('data-safety.csv'));
    });
  });
}
