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

  group('the Android upload key', () {
    setUp(() {
      secrets(
        'keystore_p12_base64: ${b64('a keystore')}\n'
        'keystore_password: swordfish\n'
        'key_alias: upload\n',
      );
    });

    test('arrives as the four variables Gradle looks for', () {
      final loaded = load();
      addTearDown(loaded.dispose);
      final env = loaded.environment;

      expect(
        File(env['ANDROID_KEYSTORE_PATH']!).readAsStringSync(),
        'a keystore',
      );
      expect(env['ANDROID_KEYSTORE_PASSWORD'], 'swordfish');
      expect(env['ANDROID_KEY_ALIAS'], 'upload');
      // PKCS12 uses one password for the store and the key alike, so Gradle
      // needs no special case.
      expect(env['ANDROID_KEY_PASSWORD'], 'swordfish');
    });

    test('a separate key password is used when there is one', () {
      secrets(
        'keystore_p12_base64: ${b64('a keystore')}\n'
        'keystore_password: swordfish\n'
        'key_alias: upload\n'
        'key_password: different\n',
      );
      final loaded = load();
      addTearDown(loaded.dispose);
      expect(loaded.environment['ANDROID_KEYSTORE_PASSWORD'], 'swordfish');
      expect(loaded.environment['ANDROID_KEY_PASSWORD'], 'different');
    });

    test(
      'the keystore is written mode 600',
      () {
        // The directory is 0700 by construction, but files inside it inherit the
        // process umask, which on a runner is commonly 022.
        final loaded = load();
        addTearDown(loaded.dispose);
        final mode = Process.runSync('stat', [
          '-f',
          '%Lp',
          loaded.environment['ANDROID_KEYSTORE_PATH']!,
        ]);
        expect((mode.stdout as String).trim(), '600');
      },
      onPlatform: {'linux': const Skip('stat -f is the BSD spelling')},
    );
  });

  group('the App Store Connect key', () {
    test('the .p8 is named after the key id, in a directory altool searches', () {
      // Not decoration. `altool --apiKey` takes no path: it looks for
      // AuthKey_<id>.p8 in a fixed set of directories, and $API_PRIVATE_KEYS_DIR
      // is the only one that is not somebody's home.
      secrets(
        'api_key_id: ABC123\n'
        'api_private_key_base64: ${b64('a p8')}\n'
        'api_issuer_id: 69a6de70\n',
      );
      final loaded = load();
      addTearDown(loaded.dispose);
      final env = loaded.environment;

      expect(env['APPLE_API_KEY_ID'], 'ABC123');
      expect(env['APPLE_API_ISSUER_ID'], '69a6de70');
      expect(env['APPLE_API_PRIVATE_KEY_PATH'], endsWith('AuthKey_ABC123.p8'));
      expect(
        env['APPLE_API_PRIVATE_KEY_PATH'],
        startsWith(env['API_PRIVATE_KEYS_DIR']!),
      );
      expect(
        File(env['APPLE_API_PRIVATE_KEY_PATH']!).readAsStringSync(),
        'a p8',
      );
    });

    test('an individual key has no issuer id, and that is not an error', () {
      // An individual key inherits one user's app restrictions and has no
      // issuer id at all. It is how a CI credential is kept from reaching every
      // app in the team, so requiring the issuer would rule out the credential
      // most worth using.
      secrets(
        'api_key_id: ABC123\n'
        'api_private_key_base64: ${b64('a p8')}\n',
      );
      final loaded = load();
      addTearDown(loaded.dispose);
      expect(loaded.environment['APPLE_API_KEY_ID'], 'ABC123');
      expect(loaded.environment.containsKey('APPLE_API_ISSUER_ID'), isFalse);
    });
  });

  group('the Play service account', () {
    test('is decoded to the JSON itself, not a path', () {
      secrets('play_service_account_json_base64: ${b64('{"type":"x"}')}\n');
      final loaded = load();
      addTearDown(loaded.dispose);
      expect(
        loaded.environment['GOOGLE_PLAY_SERVICE_ACCOUNT_JSON'],
        '{"type":"x"}',
      );
    });
  });

  group('refusing', () {
    test('a half-configured group stops before anything runs', () {
      // The failure this exists to prevent: Gradle falls through to the debug
      // key and produces an artifact that only Play rejects, after a full
      // upload has been sent.
      secrets('keystore_p12_base64: ${b64('a keystore')}\n');
      expect(
        load,
        throwsSaying(
          allOf(
            contains('the Android upload key is half configured'),
            contains('keystore_password, key_alias'),
          ),
        ),
      );
    });

    test('an unrecognized key is a typo and is reported as one', () {
      // Silent otherwise: the credential never arrives, and the failure
      // surfaces at the store rather than here.
      secrets(
        'keystore_p12_base64: ${b64('k')}\n'
        'keystore_pasword: swordfish\n'
        'key_alias: upload\n',
      );
      expect(load, throwsSaying(contains('keystore_pasword')));
      expect(load, throwsSaying(contains('known keys:')));
    });

    test('a value that is not base64 says which key', () {
      secrets(
        'keystore_p12_base64: "not base64!!"\n'
        'keystore_password: swordfish\n'
        'key_alias: upload\n',
      );
      expect(
        load,
        throwsSaying(contains('keystore_p12_base64 is not valid base64')),
      );
    });

    test('an absent secrets file is named', () {
      expect(load, throwsSaying(contains('secrets/release.yaml')));
    });

    test('sops failing says where an identity is expected', () {
      brokenSops();
      secrets('key_alias: upload\n');
      expect(load, throwsSaying(contains('SOPS_AGE_KEY')));
    });

    test('no sops at all points at deps install', () {
      File('${_root.path}/.bin/sops').deleteSync();
      secrets('key_alias: upload\n');
      // Only meaningful when the host has no sops on PATH either. Marked
      // skipped rather than returned from, so a machine that does have one
      // reports "skipped" instead of a green test that asserted nothing.
      if (Process.runSync('sh', ['-c', 'command -v sops']).exitCode == 0) {
        markTestSkipped('sops is on PATH here, so the fallback finds it');
        return;
      }
      expect(load, throwsSaying(contains('deps install')));
    });

    test('nothing to run is refused rather than succeeding silently', () {
      secrets('key_alias: upload\n');
      expect(
        () => runSecretsExec(
          repoRoot: _root.path,
          secretsFile: _secretsFile,
          command: const [],
        ),
        throwsSaying(contains('nothing to run')),
      );
    });
  });

  group('running a command', () {
    setUp(() {
      secrets(
        'keystore_p12_base64: ${b64('a keystore')}\n'
        'keystore_password: swordfish\n'
        'key_alias: upload\n',
      );
    });

    test(
      'the child gets the credentials, and the repository as its cwd',
      () async {
        // stdout is inherited rather than captured, so the child reports through
        // a file — which also proves it ran with the repository root as its
        // working directory, since the path is relative.
        final code = await runSecretsExec(
          repoRoot: _root.path,
          secretsFile: _secretsFile,
          command: [
            'sh',
            '-c',
            'printf "%s\\n%s\\n" "\$ANDROID_KEY_ALIAS" "\$ANDROID_KEYSTORE_PATH" > report',
          ],
        );

        expect(code, 0);
        final report = File('${_root.path}/report').readAsLinesSync();
        expect(report.first, 'upload');
        expect(report[1], isNotEmpty);
      },
    );

    test('the decrypted keystore does not outlive the command', () async {
      // The property the whole design is for. The child reports where its
      // keystore was; nothing may be there afterwards.
      await runSecretsExec(
        repoRoot: _root.path,
        secretsFile: _secretsFile,
        command: ['sh', '-c', 'printf "%s" "\$ANDROID_KEYSTORE_PATH" > where'],
      );

      final keystore = File('${_root.path}/where').readAsStringSync();
      expect(keystore, isNotEmpty);
      expect(File(keystore).existsSync(), isFalse);
      expect(Directory(File(keystore).parent.path).existsSync(), isFalse);
    });

    test(
      'a failing command is cleaned up after too, and its status passed on',
      () async {
        // The case `exec` would have broken: replacing this process means nothing
        // ever runs the cleanup.
        final code = await runSecretsExec(
          repoRoot: _root.path,
          secretsFile: _secretsFile,
          command: [
            'sh',
            '-c',
            'printf "%s" "\$ANDROID_KEYSTORE_PATH" > where; exit 3',
          ],
        );

        expect(code, 3);
        expect(
          File(File('${_root.path}/where').readAsStringSync()).existsSync(),
          isFalse,
        );
      },
    );

    test('what was loaded is reported, so an absent credential is visible', () {
      final loaded = load();
      addTearDown(loaded.dispose);
      expect(loaded.loaded, ['the Android upload key']);
      // Naming what arrived rather than what was asked for is the point: a Play
      // service account that is simply not in the file has to be visible here
      // rather than inferred from a failure three minutes later.
      expect(loaded.loaded, isNot(contains('the Play service account')));
    });
  });
}
