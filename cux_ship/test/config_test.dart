// SPDX-License-Identifier: Apache-2.0
//
// This file is read before every command and nothing prompts about it, so
// anything it gets wrong is wrong silently and everywhere. Most of what is
// asserted here is therefore a refusal: the cases where it must stop rather
// than carry on with a setting that looks applied and is not.
import 'dart:io';

import 'package:cux_ship/src/config.dart';
import 'package:cux_ship/src/project.dart';
import 'package:test/test.dart';

late Directory _root;

void write(String relative, String contents) {
  final file = File('${_root.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

void config(String contents) => write(cuxShipConfigFile, contents);

ProjectConfig read() => ProjectConfig.read(_root.path);

Matcher throwsSaying(String fragment) => throwsA(
  isA<ProjectException>().having(
    (e) => e.message,
    'message',
    contains(fragment),
  ),
);

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cux_ship_config_test');
  });

  tearDown(() {
    _root.deleteSync(recursive: true);
  });

  group('reading', () {
    test('no file is not an error', () {
      expect(read().appDir, isNull);
    });

    test('reads app-dir', () {
      config('app-dir: app\n');
      expect(read().appDir, 'app');
    });

    test('an empty file is a legitimate thing to keep', () {
      // Every key commented out is still a file somebody meant to have.
      config('# nothing set yet\n');
      expect(read().appDir, isNull);
    });

    test('signing defaults to automatic, and names no profiles', () {
      // The default has to be the one needing no configuration: a project that
      // says nothing about signing is the common case.
      config('app-dir: app\n');
      expect(read().signing, AppleSigning.automatic);
      expect(read().profiles, isEmpty);
    });

    test('manual signing carries the profiles it will use', () {
      config('apple:\n  signing: manual\n  profiles:\n    - ios_appstore\n');
      expect(read().signing, AppleSigning.manual);
      expect(read().profiles, ['ios_appstore']);
    });
  });

  group('apple signing', () {
    test('manual with no profiles is refused, not defaulted', () {
      // Nothing to sign against. Xcode would say so well into an archive.
      config('apple:\n  signing: manual\n');
      expect(read, throwsSaying('no profiles are named'));
    });

    test('profiles under automatic signing are refused as contradictory', () {
      // Which mode is in force must not be inferred from a list being
      // non-empty — that is how a project signs with something it did not
      // mean to.
      config('apple:\n  profiles:\n    - ios_appstore\n');
      expect(read, throwsSaying('apple.signing is automatic'));
    });

    test('an unknown key under apple names the known ones', () {
      config('apple:\n  signng: manual\n');
      expect(read, throwsSaying('unknown key: signng'));
      expect(read, throwsSaying('known keys: profiles, signing'));
    });

    test('a signing mode that is neither is refused', () {
      config('apple:\n  signing: sometimes\n');
      expect(read, throwsSaying('must be automatic or manual'));
    });

    test('profiles must be a list of names', () {
      config('apple:\n  signing: manual\n  profiles: ios_appstore\n');
      expect(read, throwsSaying('apple.profiles must be a list'));
    });
  });

  group('refusing', () {
    test('an unknown key stops the command and names the known ones', () {
      // The failure this file would otherwise have: a misspelt key skipped in
      // silence is a setting that appears to be applied and is not.
      config('app_dir: app\n');
      expect(read, throwsSaying('unknown key: app_dir'));
      expect(read, throwsSaying('known keys: app-dir'));
    });

    test('several unknown keys are all reported at once', () {
      config('appdir: app\nnonsense: 1\n');
      expect(read, throwsSaying('unknown keys: appdir, nonsense'));
    });

    test('a key of the wrong type is refused', () {
      config('app-dir: 3\n');
      expect(read, throwsSaying('app-dir must be a string'));
    });

    test('a document that is not a mapping is refused', () {
      config('- app\n- dir\n');
      expect(read, throwsSaying('must be a mapping'));
    });

    test('malformed YAML is reported as such', () {
      config('app-dir: [unclosed\n');
      expect(read, throwsSaying('not valid YAML'));
    });
  });

  group('precedence', () {
    setUp(() {
      Directory('${_root.path}/app').createSync();
      Directory('${_root.path}/other').createSync();
      write('app/pubspec.yaml', 'name: a\nversion: 1.0.0\n');
      write('other/pubspec.yaml', 'name: b\nversion: 2.0.0\n');
    });

    test('the file applies when nothing else says otherwise', () {
      config('app-dir: app\n');
      final project = ProjectContext.read(repoRoot: _root.path);
      expect(project.appDirRelative, 'app');
      expect(project.versionName, '1.0.0');
    });

    test('an explicit app dir wins over the file', () {
      // The flag and CUX_SHIP_APP_DIR both arrive here as `appDir`, so this is
      // the whole of the override behavior.
      config('app-dir: app\n');
      final project = ProjectContext.read(
        repoRoot: _root.path,
        appDir: 'other',
      );
      expect(project.appDirRelative, 'other');
      expect(project.versionName, '2.0.0');
    });

    test('a bad app-dir in the file is refused like a bad flag', () {
      config('app-dir: nope\n');
      expect(
        () => ProjectContext.read(repoRoot: _root.path),
        throwsSaying('no such directory: nope'),
      );
    });
  });
}
