// SPDX-License-Identifier: Apache-2.0
//
// The selector, and the variable names it filters on. Both are pure functions
// of the parsed file, which is what lets them run with no identity and no Mac.

import 'package:cux_ship/src/project.dart';
import 'package:cux_ship/src/secrets.dart';
import 'package:test/test.dart';

/// What one project's file actually holds, so the selector is exercised against
/// a real shape rather than a convenient one.
const _available = {
  'android.keystores.upload',
  'android.play_service_account',
  'apple.api_keys.upload',
  'apple.certificates.distribution',
  'apple.certificates.developer_id',
  'apple.profiles.ios_appstore',
  'ssh_keys.github_deploy',
  'tokens.artifact',
  'tokens.fosshub',
};

OnlySelection resolve(List<String> selectors, {Set<String>? available}) =>
    resolveOnly(
      selectors,
      available: available ?? _available,
      at: 'secrets/release.yaml',
    );

void main() {
  group('variable names, derived without decrypting', () {
    // Three families name their variables from something only the file knows —
    // the instance for certificates and profiles, a cleartext field for tokens
    // and ssh keys. That is why a static map could not express them, and why
    // this had to become a function of the parsed file.
    test('certificates and profiles derive from the instance', () {
      expect(
        variablesForCredential(
          path: 'apple.certificates.mac_installer',
          instance: 'mac_installer',
          fields: {},
        ),
        {'APPLE_MAC_INSTALLER_P12_PATH', 'APPLE_MAC_INSTALLER_P12_PASSWORD'},
      );
      expect(
        variablesForCredential(
          path: 'apple.profiles.ios_appstore_autofill',
          instance: 'ios_appstore_autofill',
          fields: {},
        ),
        {'APPLE_PROFILE_IOS_APPSTORE_AUTOFILL_PATH'},
      );
    });

    test('tokens and ssh keys take the name the file declares', () {
      expect(
        variablesForCredential(
          path: 'tokens.marks',
          instance: 'marks',
          fields: {'env': 'MARKS_TOKEN'},
        ),
        {'MARKS_TOKEN'},
      );
    });

    // Declared rather than minted, so a credential with no `env` exports
    // nothing rather than inventing a name from the instance.
    test('a token with no env exports nothing rather than guessing', () {
      expect(
        variablesForCredential(
          path: 'tokens.marks',
          instance: 'marks',
          fields: {},
        ),
        isEmpty,
      );
    });

    test('issuer_id is named only when the key carries one', () {
      expect(
        variablesForCredential(
          path: 'apple.api_keys.upload',
          instance: 'upload',
          fields: {'kind': 'individual'},
        ),
        isNot(contains('APPLE_API_ISSUER_ID')),
      );
      expect(
        variablesForCredential(
          path: 'apple.api_keys.upload',
          instance: 'upload',
          fields: {'kind': 'team', 'issuer_id': 'abc'},
        ),
        contains('APPLE_API_ISSUER_ID'),
      );
    });

    test('placed files export nothing — they are written, not exported', () {
      expect(
        variablesForCredential(
          path: 'placed.env_production',
          instance: 'env_production',
          fields: {'path': 'lib/env/production.dart'},
        ),
        isEmpty,
      );
    });
  });

  group('resolving a selector', () {
    test('a family selects every instance it holds', () {
      expect(resolve(['tokens']).paths, {'tokens.artifact', 'tokens.fosshub'});
    });

    test('an instance selects itself', () {
      expect(resolve(['tokens.artifact']).paths, {'tokens.artifact'});
    });

    test('a comma-separated list selects all of them', () {
      expect(
        resolve(['tokens.artifact,apple.certificates.distribution']).paths
          ..toList(),
        {'tokens.artifact', 'apple.certificates.distribution'},
      );
    });

    // A singleton has no instance level; its family path is the whole name.
    test('a singleton resolves by its own name', () {
      expect(resolve(['android.play_service_account']).paths, {
        'android.play_service_account',
      });
    });
  });

  group('what does not resolve is fatal, and the messages differ', () {
    // Three mistakes, three messages. Telling someone their spelling is wrong
    // when it is not sends them looking in the wrong place.
    test('unknown to the schema names what exists', () {
      expect(
        () => resolve(['tokns']),
        throwsA(
          isA<ProjectException>().having(
            (e) => e.message,
            'message',
            allOf(contains('names nothing'), contains('tokens')),
          ),
        ),
      );
    });

    test('a named instance absent from the file names its siblings', () {
      expect(
        () => resolve(['tokens.marsk']),
        throwsA(
          isA<ProjectException>().having(
            (e) => e.message,
            'message',
            allOf(contains('no such tokens'), contains('tokens.artifact')),
          ),
        ),
      );
    });

    // A section is neither production, and refusing it by naming its families
    // is more use than "unknown".
    test('a section is refused, naming its families', () {
      expect(
        () => resolve(['apple']),
        throwsA(
          isA<ProjectException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('is a section'),
              contains('apple.certificates'),
              contains('apple.profiles'),
            ),
          ),
        ),
      );
    });
  });

  group('an empty family is reported, not fatal', () {
    // Naming a family is a scope; naming an instance is an existence claim.
    // The same line `decideProfile` draws between a named profile that is
    // absent (fatal) and an unnamed one that merely turns up (warned).
    test('a family with nothing in this file selects nothing and is named', () {
      final selection = resolve(['tokens'], available: {'tokens.x'}..clear());
      expect(selection.paths, isEmpty);
      expect(selection.emptyFamilies, {'tokens'});
    });

    test('but a named instance in that same family is still fatal', () {
      expect(
        () => resolve(['tokens.marks'], available: <String>{}),
        throwsA(isA<ProjectException>()),
      );
    });
  });

  group('flags that say the same thing are refused, naming the replacement', () {
    // `--keystore` and `--api-key` exist to resolve which instance fills a
    // singular set of variable names. An instance in `--only` already says
    // that, so adjudicating the interaction was three rules where refusing is
    // one — and the error tells the caller what to write instead of what is
    // wrong.
    test('--keystore alongside --only is refused', () {
      expect(
        () => checkOnlyCombination(only: ['tokens.marks'], keystore: 'upload'),
        throwsA(
          isA<ProjectException>().having(
            (e) => e.message,
            'message',
            allOf(contains('say the same thing'), contains('--only')),
          ),
        ),
      );
    });

    test('--api-key alongside --only is refused', () {
      expect(
        () => checkOnlyCombination(only: ['tokens.marks'], apiKey: 'upload'),
        throwsA(isA<ProjectException>()),
      );
    });

    // Different axes, and readers will conflate them: `--profile` decides what
    // Xcode gets installed, `--only` what the child's environment holds.
    test('a profile named in --only points at --profile', () {
      expect(
        () => checkOnlyCombination(only: ['apple.profiles.ios_appstore']),
        throwsA(
          isA<ProjectException>().having(
            (e) => e.message,
            'message',
            contains('--profile'),
          ),
        ),
      );
    });

    test('placed in --only points at secrets place', () {
      expect(
        () => checkOnlyCombination(only: ['placed.env_production']),
        throwsA(
          isA<ProjectException>().having(
            (e) => e.message,
            'message',
            contains('secrets place'),
          ),
        ),
      );
    });

    // Without --only there is nothing to conflict with, so the flags they
    // replace still work as they always did.
    test('the flags are untouched when --only is absent', () {
      expect(
        () => checkOnlyCombination(only: const [], keystore: 'upload'),
        returnsNormally,
      );
    });
  });

  // The case that only appears under nesting: the outer wrapper filtered its
  // child, and the inner one asks for something that did not arrive. Resolved
  // against what this process holds rather than against the file, it fails here
  // naming the credential — instead of four layers down inside a build script.
  group('resolution is against what arrived, not against the file', () {
    test('asking for what an outer wrapper stripped is fatal here', () {
      expect(
        () => resolve(
          ['tokens.artifact'],
          available: {'apple.certificates.distribution'},
        ),
        throwsA(
          isA<ProjectException>().having(
            (e) => e.message,
            'message',
            contains('tokens.artifact'),
          ),
        ),
      );
    });

    test('a partial match fails rather than proceeding with the rest', () {
      expect(
        () => resolve(
          ['apple.certificates.distribution,tokens.artifact'],
          available: {'apple.certificates.distribution'},
        ),
        throwsA(isA<ProjectException>()),
      );
    });
  });
}
