// SPDX-License-Identifier: Apache-2.0
//
// This is the one place in the tool that turns ciphertext into a private key on
// disk, so most of what matters here is what happens *afterwards* and in the
// failure cases: that the plaintext is removed however the run ends, and that a
// credential which did not arrive is loud rather than absent.
//
// sops is faked with a script that cats the file. That is not a shortcut around
// the interesting part — nothing below is about decryption, which sops does and
// is tested by sops. Everything below is about what this does with the result.
import 'dart:convert';
import 'dart:io';

import 'package:cux_ship/src/project.dart';
import 'package:cux_ship/src/secrets.dart';
import 'package:test/test.dart';

late Directory _root;

void write(String relative, String contents) {
  final file = File('${_root.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

void executable(String relative, String script) {
  write(relative, script);
  Process.runSync('chmod', ['755', '${_root.path}/$relative']);
}

/// A `sops` that decrypts nothing — `sops -d FILE` becomes `cat FILE`.
void fakeSops() => executable('.bin/sops', '#!/bin/sh\ncat "\$2"\n');

/// A `sops` that fails, the way a machine with no usable identity does.
void brokenSops() =>
    executable('.bin/sops', '#!/bin/sh\necho "no key" >&2\nexit 1\n');

void secrets(String contents) => write('secrets/release.yaml', contents);

File get _secretsFile => File('${_root.path}/secrets/release.yaml');

LoadedSecrets load() =>
    loadSecrets(repoRoot: _root.path, secretsFile: _secretsFile);

String b64(String value) => base64.encode(utf8.encode(value));

Matcher throwsSaying(Object fragment) => throwsA(
  isA<ProjectException>().having((e) => e.message, 'message', fragment),
);

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('cux_ship_secrets_test');
    fakeSops();
  });

  tearDown(() {
    _root.deleteSync(recursive: true);
  });

  group('the Android signing key', () {
    test('is materialized and pointed at', () {
      secrets(
        'android:\n'
        '  keystores:\n'
        '    upload:\n'
        '      base64: ${b64('a keystore')}\n'
        '      password: hunter2\n'
        '      key_alias: upload\n',
      );
      final loaded = load();
      final path = loaded.environment['ANDROID_KEYSTORE_PATH']!;
      expect(File(path).readAsStringSync(), 'a keystore');
      expect(loaded.environment['ANDROID_KEYSTORE_PASSWORD'], 'hunter2');
      expect(loaded.environment['ANDROID_KEY_ALIAS'], 'upload');
      // PKCS12 uses one password for both unless told otherwise.
      expect(loaded.environment['ANDROID_KEY_PASSWORD'], 'hunter2');
      loaded.dispose();
    });

    test('a named instance arrives — it does not merely validate', () {
      // The defect this pins: a credential under a name used to pass every
      // check, report nothing amiss, and set no variables at all.
      secrets(
        'android:\n'
        '  keystores:\n'
        '    amazon:\n'
        '      base64: ${b64('the amazon keystore')}\n'
        '      password: p\n'
        '      key_alias: amazon-key\n',
      );
      final loaded = load();
      expect(loaded.environment['ANDROID_KEYSTORE_PATH'], isNotNull);
      expect(
        File(loaded.environment['ANDROID_KEYSTORE_PATH']!).readAsStringSync(),
        'the amazon keystore',
      );
      expect(loaded.loaded, contains('android.keystores.amazon'));
      loaded.dispose();
    });

    test('two keystores refuse to guess, and name the choices', () {
      secrets(
        'android:\n'
        '  keystores:\n'
        '    upload: { base64: ${b64('a')}, password: p, key_alias: x }\n'
        '    amazon: { base64: ${b64('b')}, password: p, key_alias: y }\n',
      );
      expect(load, throwsSaying(contains('--keystore')));
      expect(load, throwsSaying(contains('upload')));
      expect(load, throwsSaying(contains('amazon')));
    });

    test('half configured is refused, naming what is missing', () {
      secrets(
        'android:\n'
        '  keystores:\n'
        '    upload:\n'
        '      base64: ${b64('a keystore')}\n'
        '      key_alias: upload\n',
      );
      expect(load, throwsSaying(contains('half configured')));
      expect(load, throwsSaying(contains('password')));
    });
  });

  group('the App Store Connect key', () {
    test('an individual key keeps the name Apple gave it', () {
      // The filename is the only signal of which claims Apple is sent, and it
      // is derived rather than stored — so the assertion is on the file that
      // reaches disk, not on the field round-tripping.
      secrets(
        'apple:\n'
        '  api_keys:\n'
        '    upload:\n'
        '      id: 4LJJBK4Z86KR\n'
        '      kind: individual\n'
        '      private_key_base64: ${b64('the key')}\n',
      );
      final loaded = load();
      final dir = Directory(loaded.environment['API_PRIVATE_KEYS_DIR']!);
      expect(dir.listSync().map((e) => e.uri.pathSegments.last), [
        'ApiKey_4LJJBK4Z86KR.p8',
      ]);
      expect(
        loaded.environment['APPLE_API_PRIVATE_KEY_PATH'],
        endsWith('ApiKey_4LJJBK4Z86KR.p8'),
      );
      loaded.dispose();
    });

    test('a team key is named the other way', () {
      secrets(
        'apple:\n'
        '  api_keys:\n'
        '    team:\n'
        '      id: S5PTZMY9P8\n'
        '      kind: team\n'
        '      private_key_base64: ${b64('the key')}\n',
      );
      final loaded = load();
      expect(
        Directory(
          loaded.environment['API_PRIVATE_KEYS_DIR']!,
        ).listSync().map((e) => e.uri.pathSegments.last),
        ['AuthKey_S5PTZMY9P8.p8'],
      );
      loaded.dispose();
    });

    test('a kind that is neither is refused, saying why it matters', () {
      secrets(
        'apple:\n'
        '  api_keys:\n'
        '    upload:\n'
        '      id: X\n'
        '      kind: personal\n'
        '      private_key_base64: ${b64('k')}\n',
      );
      expect(load, throwsSaying(contains('team or individual')));
    });

    test('an issuer is optional, and says nothing about the kind', () {
      secrets(
        'apple:\n'
        '  api_keys:\n'
        '    upload:\n'
        '      id: X\n'
        '      kind: individual\n'
        '      issuer_id: an-issuer\n'
        '      private_key_base64: ${b64('k')}\n',
      );
      final loaded = load();
      expect(loaded.environment['APPLE_API_ISSUER_ID'], 'an-issuer');
      expect(
        loaded.environment['APPLE_API_PRIVATE_KEY_PATH'],
        endsWith('ApiKey_X.p8'),
      );
      loaded.dispose();
    });
  });

  group('Apple certificates', () {
    test('every one is materialized — a release needs more than one', () {
      secrets(
        'apple:\n'
        '  certificates:\n'
        '    distribution: { p12_base64: ${b64('app store')}, password: a }\n'
        '    developer_id: { p12_base64: ${b64('direct')}, password: b }\n',
      );
      final loaded = load();
      expect(
        File(
          loaded.environment['APPLE_DISTRIBUTION_P12_PATH']!,
        ).readAsStringSync(),
        'app store',
      );
      expect(
        File(
          loaded.environment['APPLE_DEVELOPER_ID_P12_PATH']!,
        ).readAsStringSync(),
        'direct',
      );
      expect(loaded.environment['APPLE_DEVELOPER_ID_P12_PASSWORD'], 'b');
      loaded.dispose();
    });

    test('a misspelt certificate kind is refused, since they are a set', () {
      secrets(
        'apple:\n'
        '  certificates:\n'
        '    developr_id: { p12_base64: ${b64('x')}, password: a }\n',
      );
      expect(load, throwsSaying(contains('developr_id')));
      expect(load, throwsSaying(contains('developer_id')));
    });
  });

  group('the project\'s own', () {
    test('a token goes to the variable it declares', () {
      secrets('tokens:\n  fosshub: { env: FOSSHUB_TOKEN, value: shh }\n');
      final loaded = load();
      expect(loaded.environment['FOSSHUB_TOKEN'], 'shh');
      loaded.dispose();
    });

    test('a token cannot take a name this tool sets', () {
      // Otherwise a token silently redirects a real credential's path.
      secrets(
        'tokens:\n'
        '  sneaky: { env: ANDROID_KEYSTORE_PATH, value: /tmp/mine }\n',
      );
      expect(load, throwsSaying(contains('a name this tool sets')));
    });

    test('a variable name that is not one is refused', () {
      secrets('tokens:\n  x: { env: "not a name", value: v }\n');
      expect(load, throwsSaying(contains('usable variable name')));
    });

    test('an ssh key is written and pointed at', () {
      secrets(
        'ssh_keys:\n'
        '  github_deploy:\n'
        '    base64: ${b64('a private key')}\n'
        '    env: GITHUB_DEPLOY_KEY_PATH\n',
      );
      final loaded = load();
      final path = loaded.environment['GITHUB_DEPLOY_KEY_PATH']!;
      expect(File(path).readAsStringSync(), 'a private key');
      loaded.dispose();
    });
  });

  group('structure', () {
    test('an unknown key names its path and what is legal there', () {
      secrets('apple:\n  certifcates:\n    distribution: { p12_base64: x }\n');
      expect(load, throwsSaying(contains('apple.certifcates')));
      expect(load, throwsSaying(contains('certificates')));
    });

    test('a typo at the top is not read as a credential', () {
      secrets('androd:\n  keystores:\n    upload: { base64: x }\n');
      expect(load, throwsSaying(contains('androd')));
    });

    test('an unknown field of a known credential is refused', () {
      secrets(
        'android:\n'
        '  keystores:\n'
        '    upload:\n'
        '      base64: ${b64('a')}\n'
        '      password: p\n'
        '      key_alias: x\n'
        '      passphrase: p\n',
      );
      expect(load, throwsSaying(contains('passphrase')));
    });

    test('an instance name that would not make a filename is refused', () {
      secrets(
        'android:\n'
        '  keystores:\n'
        '    "../escape": { base64: ${b64('a')}, password: p, key_alias: x }\n',
      );
      expect(load, throwsSaying(contains('usable name')));
    });

    test('everything wrong is reported at once', () {
      secrets(
        'androd:\n'
        '  keystores: {}\n'
        'apple:\n'
        '  certifcates: {}\n',
      );
      expect(load, throwsSaying(contains('androd')));
      expect(load, throwsSaying(contains('certifcates')));
    });
  });

  group('inspecting without decrypting', () {
    test('reports credentials by path, with their fields', () {
      secrets(
        'android:\n'
        '  keystores:\n'
        '    upload:\n'
        '      base64: ENC[whatever]\n'
        '      password: ENC[whatever]\n'
        '      key_alias: ENC[whatever]\n',
      );
      final report = inspectSecretKeys(_secretsFile);
      expect(report.problems, isEmpty);
      expect(report.credentials.single.path, 'android.keystores.upload');
      expect(report.credentials.single.fields, [
        'base64',
        'key_alias',
        'password',
      ]);
      expect(report.credentials.single.missing, isEmpty);
    });

    test('sees half configuration without an identity', () {
      // A missing field is a missing *name*, so this is knowable from the
      // encrypted file — which makes this the whole pre-flight, not half of it.
      secrets(
        'android:\n'
        '  keystores:\n'
        '    upload:\n'
        '      base64: ENC[whatever]\n',
      );
      final report = inspectSecretKeys(_secretsFile);
      expect(report.credentials.single.missing, ['password', 'key_alias']);
    });

    test('skips the sops block, and only at the top', () {
      secrets(
        'android:\n'
        '  keystores:\n'
        '    upload:\n'
        '      base64: ENC[x]\n'
        '      password: ENC[x]\n'
        '      key_alias: ENC[x]\n'
        'sops:\n'
        '  age: []\n',
      );
      expect(inspectSecretKeys(_secretsFile).problems, isEmpty);
    });

    test('agrees with what secrets exec accepts, for the same file', () {
      // NOT a comparison against a shared set — that formulation cannot fail
      // for any input, which is how the previous version of this test stayed
      // green while the two disagreed. One fixture, both paths, diffed.
      const fixtures = {
        'good':
            'android:\n'
            '  keystores:\n'
            '    upload:\n'
            '      base64: YQ==\n'
            '      password: p\n'
            '      key_alias: x\n',
        'unknown section': 'androd:\n  keystores: {}\n',
        'unknown field':
            'android:\n'
            '  keystores:\n'
            '    upload: { base64: YQ==, password: p, key_alias: x, oops: 1 }\n',
        'half configured':
            'android:\n'
            '  keystores:\n'
            '    upload: { base64: YQ== }\n',
      };
      for (final entry in fixtures.entries) {
        secrets(entry.value);
        final report = inspectSecretKeys(_secretsFile);
        final inspectorHappy =
            report.problems.isEmpty &&
            report.credentials.every((c) => c.missing.isEmpty);

        var parserHappy = true;
        try {
          load().dispose();
        } on ProjectException {
          parserHappy = false;
        }

        expect(
          inspectorHappy,
          parserHappy,
          reason:
              'inspect and exec disagree about "${entry.key}" — the '
              'pre-flight is only worth running if it predicts the thing it '
              'runs before',
        );
      }
    });
  });

  group('running a command', () {
    test('the plaintext is gone when the run ends', () {
      secrets(
        'android:\n'
        '  keystores:\n'
        '    upload:\n'
        '      base64: ${b64('a keystore')}\n'
        '      password: p\n'
        '      key_alias: x\n',
      );
      final loaded = load();
      final path = loaded.environment['ANDROID_KEYSTORE_PATH']!;
      expect(File(path).existsSync(), isTrue);
      loaded.dispose();
      expect(File(path).existsSync(), isFalse);
    });

    test('what was loaded is reported by path', () {
      secrets(
        'android:\n'
        '  keystores:\n'
        '    upload:\n'
        '      base64: ${b64('a')}\n'
        '      password: p\n'
        '      key_alias: x\n'
        '  play_service_account:\n'
        '    json_base64: ${b64('{}')}\n',
      );
      final loaded = load();
      expect(loaded.loaded, [
        'android.keystores.upload',
        'android.play_service_account',
      ]);
      loaded.dispose();
    });

    test('a sops that cannot decrypt says so, and writes nothing', () {
      brokenSops();
      secrets('android:\n  keystores:\n    upload: { base64: YQ== }\n');
      expect(load, throwsA(isA<ProjectException>()));
    });
  });
}
