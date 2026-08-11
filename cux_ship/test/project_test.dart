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

ProjectContext read({String? appDir}) =>
    ProjectContext.read(repoRoot: _root.path, appDir: appDir);

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

  group('--app-dir', () {
    /// A monorepo: the Flutter app under `app/`, the release inputs at the top.
    void monorepo() {
      write('app/pubspec.yaml', 'name: an_app\nversion: 2.0.1+7\n');
      write(
        'app/android/app/build.gradle.kts',
        'applicationId = "design.codeux.nested"\n',
      );
      write(
        'app/ios/Runner.xcodeproj/project.pbxproj',
        'PRODUCT_BUNDLE_IDENTIFIER = design.codeux.nested;\n',
      );
      write('CHANGELOG.md', '## 2.0.1\n\n- Something\n');
      write('store/play/details/default_language.txt', 'en-US');
      write('store/appstore/info/primary_category.txt', 'HEALTH_AND_FITNESS');
    }

    test('the app owns pubspec, android and ios', () {
      monorepo();
      final project = read(appDir: 'app');
      expect(project.versionName, '2.0.1');
      expect(project.buildNumber, '7');
      expect(project.androidPackage, 'design.codeux.nested');
      expect(project.iosBundleId, 'design.codeux.nested');
    });

    test('the repository still owns the changelog and the store tree', () {
      // The half that is easy to get wrong by moving both roots together. A
      // release describes what the repository shipped, and most of what a user
      // notices usually changed in some package other than the app.
      monorepo();
      final project = read(appDir: 'app');
      expect(project.changelog, '${_root.path}/CHANGELOG.md');
      expect(project.appStoreMetadata, '${_root.path}/store/appstore');
      expect(project.playMetadata, '${_root.path}/store/play');
    });

    test('without it, nothing under app/ is found', () {
      // The state this flag exists to escape, asserted so that the flag doing
      // nothing would be a failure rather than a subtle regression.
      monorepo();
      final project = read();
      expect(project.versionName, isNull);
      expect(project.androidPackage, isNull);
      expect(project.iosBundleId, isNull);
      expect(project.changelog, isNotNull);
    });

    test('reports the app directory both ways', () {
      monorepo();
      final project = read(appDir: 'app');
      expect(project.root, _root.path);
      expect(project.appDir, '${_root.path}/app');
      // Repository-relative, which is the form every git argument takes.
      expect(project.appDirRelative, 'app');
    });

    test('absent means the app is the repository', () {
      write('pubspec.yaml', 'name: an_app\nversion: 1.2.3\n');
      for (final same in [null, '', '.', './']) {
        final project = read(appDir: same);
        expect(project.appDirRelative, '', reason: 'for "$same"');
        expect(project.appDir, project.root, reason: 'for "$same"');
        expect(project.versionName, '1.2.3', reason: 'for "$same"');
      }
    });

    test('an absolute path inside the repository is accepted', () {
      monorepo();
      expect(read(appDir: '${_root.path}/app').appDirRelative, 'app');
    });

    test('trailing slashes and . segments normalize away', () {
      monorepo();
      for (final spelling in ['app/', './app', 'app/./', 'store/../app']) {
        expect(
          read(appDir: spelling).appDirRelative,
          'app',
          reason: 'for "$spelling"',
        );
      }
    });

    test('a directory that does not exist is refused, not inferred past', () {
      // The failure this must never have. A silent fallback turns every
      // inferred value back into a required flag, and the first symptom is a
      // command asking for a --package it has always worked out for itself.
      monorepo();
      expect(
        () => read(appDir: 'ap'),
        throwsA(
          isA<ProjectException>().having(
            (e) => e.message,
            'message',
            contains('no such directory: ap'),
          ),
        ),
      );
    });

    test('a directory outside the repository is refused', () {
      // git takes repository-relative paths, so there would be nothing sensible
      // to hand `git commit`.
      monorepo();
      final outside = Directory.systemTemp.createTempSync('cux_ship_outside');
      addTearDown(() => outside.deleteSync(recursive: true));
      expect(
        () => read(appDir: outside.path),
        throwsA(
          isA<ProjectException>().having(
            (e) => e.message,
            'message',
            contains('outside the repository'),
          ),
        ),
      );
    });
  });
}
