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

  group('headings', () {
    // A real secrets file groups its credentials under `android:` and `apple:`,
    // because that is how somebody reads it. The shell script this replaces
    // coped by accident — it stripped leading whitespace before matching, which
    // made it indentation-blind — and reading only the top level instead
    // refuses such a file outright, having found none of the credentials in it.
    test('one level of grouping is walked, and the heading discarded', () {
      secrets(
        'android:\n'
        '  keystore_p12_base64: ${b64('a keystore')}\n'
        '  keystore_password: swordfish\n'
        '  key_alias: upload\n'
        'apple:\n'
        '  api_key_id: ABC123\n'
        '  api_private_key_base64: ${b64('a p8')}\n',
      );
      final loaded = load();
      addTearDown(loaded.dispose);

      expect(loaded.environment['ANDROID_KEY_ALIAS'], 'upload');
      expect(loaded.environment['APPLE_API_KEY_ID'], 'ABC123');
      expect(loaded.loaded, [
        'the Android upload key',
        'the App Store Connect API key',
      ]);
    });

    test('grouped and top-level values can be mixed', () {
      secrets(
        'play_service_account_json_base64: ${b64('{}')}\n'
        'android:\n'
        '  keystore_p12_base64: ${b64('k')}\n'
        '  keystore_password: swordfish\n'
        '  key_alias: upload\n',
      );
      final loaded = load();
      addTearDown(loaded.dispose);
      expect(loaded.environment['GOOGLE_PLAY_SERVICE_ACCOUNT_JSON'], '{}');
      expect(loaded.environment['ANDROID_KEY_ALIAS'], 'upload');
    });

    test('a typo inside a group is reported with its heading', () {
      secrets(
        'android:\n'
        '  keystore_pasword: swordfish\n',
      );
      expect(load, throwsSaying(contains('android.keystore_pasword')));
    });

    test('the same credential under two headings is refused', () {
      // Which one wins is not something to guess at with a credential.
      secrets(
        'android:\n'
        '  key_alias: one\n'
        'other:\n'
        '  key_alias: two\n',
      );
      expect(load, throwsSaying(contains('names key_alias twice')));
    });

    test('nesting deeper than a heading is refused', () {
      secrets(
        'android:\n'
        '  upload:\n'
        '    key_alias: one\n',
      );
      expect(load, throwsSaying(contains('deeper than a credential goes')));
    });
  });

  group('inspecting without decrypting', () {
    /// A file shaped like a real encrypted one: grouped, values replaced by
    /// sops with `ENC[...]`, and carrying the metadata block sops appends.
    ///
    /// **Every `*_base64` name here is load bearing.** The bug this guards
    /// against was a documented `grep -oE '^[a-z_]+:…'` whose character class
    /// omitted digits, so it hid exactly the names that carry key material and
    /// reported only the four that do not. A fixture built from digit-free
    /// names passes either way and proves nothing.
    void encryptedFile() {
      secrets(
        'android:\n'
        '  keystore_p12_base64: ENC[AES256_GCM,data:aaaa,type:str]\n'
        '  keystore_password: ENC[AES256_GCM,data:bbbb,type:str]\n'
        '  key_alias: ENC[AES256_GCM,data:cccc,type:str]\n'
        '  play_service_account_json_base64: ENC[AES256_GCM,data:dddd,type:str]\n'
        'apple:\n'
        '  api_key_id: ENC[AES256_GCM,data:eeee,type:str]\n'
        '  api_private_key_base64: ENC[AES256_GCM,data:ffff,type:str]\n'
        '  distribution_p12_base64: ENC[AES256_GCM,data:gggg,type:str]\n'
        '  distribution_p12_password: ENC[AES256_GCM,data:hhhh,type:str]\n'
        'sops:\n'
        '  age: something\n'
        '  lastmodified: "2026-08-11T00:00:00Z"\n'
        '  mac: ENC[AES256_GCM,data:iiii,type:str]\n'
        '  unencrypted_suffix: _unencrypted\n'
        '  version: 3.13.3\n',
      );
    }

    test('finds every credential, digits in the name included', () {
      encryptedFile();
      final names = inspectSecretKeys(_secretsFile).map((k) => k.name).toList();

      expect(names, hasLength(8));
      for (final withDigits in const [
        'keystore_p12_base64',
        'play_service_account_json_base64',
        'api_private_key_base64',
        'distribution_p12_base64',
        'distribution_p12_password',
      ]) {
        expect(names, contains(withDigits), reason: 'missed $withDigits');
      }
    });

    test('skips the sops metadata block', () {
      // Present in the encrypted file and stripped on decrypt, so it is never a
      // credential — and a reader comparing this output against the accepted
      // set should not have to know to ignore seven entries.
      encryptedFile();
      final names = inspectSecretKeys(_secretsFile).map((k) => k.name);
      for (final meta in const [
        'sops',
        'age',
        'lastmodified',
        'mac',
        'unencrypted_suffix',
        'version',
      ]) {
        expect(names, isNot(contains(meta)), reason: 'reported $meta');
      }
    });

    test('reports the heading each credential was filed under', () {
      encryptedFile();
      final keys = inspectSecretKeys(_secretsFile);
      expect(keys.firstWhere((k) => k.name == 'key_alias').group, 'android');
      expect(keys.firstWhere((k) => k.name == 'api_key_id').group, 'apple');
    });

    test('a top-level credential has no heading', () {
      secrets('key_alias: ENC[AES256_GCM,data:aaaa,type:str]\n');
      expect(inspectSecretKeys(_secretsFile).single.group, isNull);
    });

    test('marks a name that secrets exec would refuse', () {
      // The whole point of running this before a release rather than during
      // one: an unrecognized key stops `secrets exec` dead.
      secrets(
        'android:\n'
        '  keystore_pasword: ENC[AES256_GCM,data:aaaa,type:str]\n'
        '  key_alias: ENC[AES256_GCM,data:bbbb,type:str]\n',
      );
      final keys = inspectSecretKeys(_secretsFile);
      expect(
        keys.firstWhere((k) => k.name == 'keystore_pasword').recognized,
        isFalse,
      );
      expect(keys.firstWhere((k) => k.name == 'key_alias').recognized, isTrue);
    });

    test('agrees with what secrets exec accepts', () {
      // These two must not drift: a pre-flight check that approximates the real
      // rules eventually disagrees with them, which is worse than no check.
      encryptedFile();
      for (final key in inspectSecretKeys(_secretsFile)) {
        expect(
          key.recognized,
          knownSecretKeys().contains(key.name),
          reason: key.name,
        );
      }
    });

    test('needs no identity and never decrypts', () {
      // There is no sops binary in this repo root at all, so a run that
      // succeeds cannot have shelled out to one.
      File('${_root.path}/.bin/sops').deleteSync();
      encryptedFile();
      expect(inspectSecretKeys(_secretsFile), hasLength(8));
    });

    test('an absent file is named', () {
      expect(
        () => inspectSecretKeys(_secretsFile),
        throwsSaying(contains('secrets/release.yaml')),
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

    test('a malformed decrypted file does not echo what it decrypted to', () {
      // The one place plaintext could reach a terminal. `_parse` runs on the
      // *decrypted* document, and package:yaml renders a parse error with the
      // offending source line and a caret under it — so interpolating the whole
      // exception prints that line, key material included, to stderr and into
      // whatever CI log is capturing it.
      //
      // A tab as indentation is invalid YAML that a healthy `sops -d` would
      // never emit, which is why this needs a hand-mangled file and is not an
      // everyday hazard. It is still the difference between an error and a
      // disclosure.
      secrets(
        'android:\n'
        '\tapi_private_key_base64: MIIEvQIBADANBgkqSECRETKEYMATERIAL\n',
      );
      expect(
        load,
        throwsA(
          isA<ProjectException>()
              .having(
                (e) => e.message,
                'message',
                isNot(contains('SECRETKEYMATERIAL')),
              )
              // Still has to say what went wrong, or the fix trades a leak for
              // an unactionable error.
              .having((e) => e.message, 'message', contains('valid YAML')),
        ),
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
