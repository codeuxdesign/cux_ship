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
      // Absent is not a *problem*, and the difference matters: the caller's own
      // "none could be read" is the right thing to say here, and a sentence
      // would displace it.
      expect(read().iosBundleIdProblem, isNull);
    });

    test('an app extension does not win by being first', () {
      // AuthPass, exactly: the AutoFill appex target appears before the app's,
      // so the first match was the extension. Its uploads were correct only
      // because the release script passes --bundle-id — luck, not design.
      write(
        'ios/Runner.xcodeproj/project.pbxproj',
        'PRODUCT_BUNDLE_IDENTIFIER = design.codeux.authpass.ios.autofill;\n'
            'PRODUCT_BUNDLE_IDENTIFIER = design.codeux.authpass.ios;\n',
      );
      expect(read().iosBundleId, isNull);
      expect(
        read().iosBundleIdProblem,
        allOf(
          contains('2 bundle identifiers'),
          contains('design.codeux.authpass.ios.autofill'),
          contains('--bundle-id'),
        ),
      );
    });

    test('an interpolated identifier is refused, not passed on as text', () {
      // How It Went, exactly. Xcode expands this at build time; read as text it
      // names an app that does not exist and Apple answers 404 — which sends
      // you to look at the app record rather than at the project.
      write(
        'ios/Runner.xcodeproj/project.pbxproj',
        r'PRODUCT_BUNDLE_IDENTIFIER = design.codeux.howitwent$(SUFFIX);'
            '\n',
      );
      expect(read().iosBundleId, isNull);
      expect(
        read().iosBundleIdProblem,
        allOf(
          contains(r'$(SUFFIX)'),
          contains('expands at build time'),
          contains('--bundle-id'),
        ),
      );
    });

    test('one identifier repeated across configurations is not a conflict', () {
      // The ordinary shape: one identifier named once per build configuration.
      // Refusing this would refuse almost every project.
      write(
        'ios/Runner.xcodeproj/project.pbxproj',
        'PRODUCT_BUNDLE_IDENTIFIER = design.codeux.holdthewheel;\n'
            'PRODUCT_BUNDLE_IDENTIFIER = design.codeux.holdthewheel;\n'
            'PRODUCT_BUNDLE_IDENTIFIER = "design.codeux.holdthewheel";\n',
      );
      expect(read().iosBundleId, 'design.codeux.holdthewheel');
      expect(read().iosBundleIdProblem, isNull);
    });
  });

  group('DEVELOPMENT_TEAM', () {
    test('is read, ignoring the empty assignment Xcode writes', () {
      write(
        'ios/Runner.xcodeproj/project.pbxproj',
        'DEVELOPMENT_TEAM = "";\nDEVELOPMENT_TEAM = 64ZPC769JY;\n',
      );
      expect(read().developmentTeam, '64ZPC769JY');
      expect(read().developmentTeamProblem, isNull);
    });

    test('repeated across targets is one team, not a conflict', () {
      // AuthPass has six of these, all identical.
      write(
        'ios/Runner.xcodeproj/project.pbxproj',
        'DEVELOPMENT_TEAM = 64ZPC769JY;\n' * 6,
      );
      expect(read().developmentTeam, '64ZPC769JY');
      expect(read().developmentTeamProblem, isNull);
    });

    test('two teams are refused rather than guessed', () {
      // Manual signing can carry a different team per configuration. The wrong
      // one exports somebody else's identity and fails much later, as a profile
      // mismatch that never mentions the team.
      write(
        'ios/Runner.xcodeproj/project.pbxproj',
        'DEVELOPMENT_TEAM = 64ZPC769JY;\nDEVELOPMENT_TEAM = ABCDE12345;\n',
      );
      expect(read().developmentTeam, isNull);
      expect(
        read().developmentTeamProblem,
        allOf(
          contains('2 development teams'),
          contains('64ZPC769JY'),
          contains('ABCDE12345'),
          contains('--team'),
        ),
      );
    });

    test('macOS answers only when iOS said nothing at all', () {
      write(
        'macos/Runner.xcodeproj/project.pbxproj',
        'DEVELOPMENT_TEAM = 64ZPC769JY;\n',
      );
      expect(read().developmentTeam, '64ZPC769JY');
    });

    test('an ambiguous iOS project is not answered by the macOS one', () {
      // The substitution this change exists to stop: falling through to another
      // file makes the ambiguity disappear silently.
      write(
        'ios/Runner.xcodeproj/project.pbxproj',
        'DEVELOPMENT_TEAM = 64ZPC769JY;\nDEVELOPMENT_TEAM = ABCDE12345;\n',
      );
      write(
        'macos/Runner.xcodeproj/project.pbxproj',
        'DEVELOPMENT_TEAM = ZZZZZ99999;\n',
      );
      expect(read().developmentTeam, isNull);
      expect(read().developmentTeamProblem, contains('2 development teams'));
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

  group('App Store trees', () {
    /// A repository whose listings differ per platform, which is what
    /// `store/appstore/<platform>` means.
    void split() {
      write('store/appstore/README.md', 'The two trees below.\n');
      write('store/appstore/ios/info/primary_category.txt', 'SPORTS');
      write('store/appstore/macos/info/primary_category.txt', 'SPORTS');
    }

    test('a flat layout is one tree, and the caller says which platform', () {
      write('store/appstore/info/primary_category.txt', 'SPORTS');

      expect(read().appStoreTrees(), {
        'ios': endsWith('store/appstore'),
      }, reason: 'ios is the default a path cannot carry');
      expect(read().appStoreTrees(platform: 'macos'), {
        'macos': endsWith('store/appstore'),
      });
    });

    test('a split layout offers every tree it holds', () {
      split();

      expect(read().appStoreTrees(), {
        'ios': endsWith('store/appstore/ios'),
        'macos': endsWith('store/appstore/macos'),
      });
    });

    test('a split layout never offers the parent', () {
      // The defect this exists to close, stated as the thing that must not
      // happen. `store/appstore` holds a README and two subdirectories — no
      // info/, no listings/, no age-rating.json — so a validator pointed at it
      // reports a *problem* on a healthy repository. A check that cries wolf
      // on a correct repository is how people learn to skip the check.
      split();

      expect(
        read().appStoreTrees().values,
        everyElement(isNot(endsWith('store/appstore'))),
      );
    });

    test('narrowing a split layout picks that platform, not the first', () {
      split();

      expect(read().appStoreTrees(platform: 'macos'), {
        'macos': endsWith('store/appstore/macos'),
      });
    });

    test('a platform with no tree offers nothing rather than a wrong one', () {
      write('store/appstore/ios/info/primary_category.txt', 'SPORTS');

      expect(
        read().appStoreTrees(platform: 'macos'),
        isEmpty,
        reason:
            'falling back to the ios tree would check iPhone screenshots '
            'against macOS rules, which is worse than checking nothing',
      );
    });

    test('no store tree at all offers nothing', () {
      expect(read().appStoreTrees(), isEmpty);
      expect(read().appStoreTrees(platform: 'ios'), isEmpty);
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
