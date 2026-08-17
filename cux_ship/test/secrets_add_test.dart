// SPDX-License-Identifier: Apache-2.0
//
// The parts of `secrets add` that can be tested without sops, a Mac or a real
// credential: identifying an artifact by its content, and reading an api key's
// facts back out of the name Apple gave it.

import 'dart:convert';

import 'package:cux_ship/src/secrets.dart';
import 'package:test/test.dart';

/// A DER SEQUENCE header, which is how both a .p12 and a .mobileprovision open.
List<int> der(List<int> body) => [0x30, 0x82, 0x04, 0x00, ...body];

void main() {
  group('identifying an artifact by what is in it', () {
    test('a PEM private key is one, however it is named', () {
      final p8 = utf8.encode(
        '-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqG\n'
        '-----END PRIVATE KEY-----\n',
      );
      expect(identifyArtifact(p8), ArtifactKind.pemPrivateKey);
    });

    test('an OpenSSH-format key is told apart from a PEM one', () {
      final key = utf8.encode(
        '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEA\n',
      );
      expect(identifyArtifact(key), ArtifactKind.opensshKey);
    });

    // Found by running this over a project's real credentials rather than over
    // fixtures: an ssh key is not necessarily in OpenSSH's own format. A github
    // deploy key stored as PEM RSA lands here, which is why the kind is named
    // for the encoding — `pemPrivateKey` — and not for what it is used for.
    // Calling it `applePrivateKey`, as this first did, would have made every
    // report of it wrong.
    test('an RSA ssh key in PEM form is a PEM private key, not an ssh one', () {
      final key = utf8.encode(
        '-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA\n',
      );
      expect(identifyArtifact(key), ArtifactKind.pemPrivateKey);
      // And `add ssh-key` therefore has to accept both.
      expect(addKindAccepts('ssh-key', ArtifactKind.pemPrivateKey), isTrue);
      expect(addKindAccepts('ssh-key', ArtifactKind.opensshKey), isTrue);
    });

    test('a JKS is recognized by its magic number', () {
      expect(
        identifyArtifact([0xFE, 0xED, 0xFE, 0xED, 0x00, 0x00]),
        ArtifactKind.javaKeystore,
      );
    });

    test('a service account is JSON', () {
      expect(
        identifyArtifact(utf8.encode('{\n  "type": "service_account"\n}')),
        ArtifactKind.json,
      );
    });

    // The discriminator that matters, and the reason this is structural rather
    // than extension-based: both are DER SEQUENCEs, so the first bytes cannot
    // separate them. A profile is CMS *signed* data wrapping a plaintext plist,
    // so its XML is readable in the clear; a p12 is encrypted throughout.
    test(
      'a provisioning profile is told from a p12 by its plaintext plist',
      () {
        final profile = der(utf8.encode('...<?xml version="1.0"?><plist>...'));
        final p12 = der(List.filled(400, 0xAB));

        expect(identifyArtifact(profile), ArtifactKind.provisioningProfile);
        expect(identifyArtifact(p12), ArtifactKind.pkcs12);
      },
    );

    test('an empty file is not silently something', () {
      expect(identifyArtifact([]), ArtifactKind.unknown);
      expect(identifyArtifact(utf8.encode('hello')), ArtifactKind.unknown);
    });
  });

  group('api key facts, read back out of the filename', () {
    // Apple's own naming is the only signal altool gets about which kind of key
    // it holds, and getting it wrong sends `iss` with an individual key and
    // earns a bare 401 after a full build. Running the mapping backwards means
    // the two fields most likely to be wrong are two nobody types.
    test('AuthKey_ is a team key', () {
      final facts = apiKeyFactsFromName('/tmp/AuthKey_ZHGL57YJVC.p8');
      expect(facts?.id, 'ZHGL57YJVC');
      expect(facts?.kind, 'team');
    });

    test('ApiKey_ is an individual key', () {
      final facts = apiKeyFactsFromName('ApiKey_2X9R4HXF34.p8');
      expect(facts?.id, '2X9R4HXF34');
      expect(facts?.kind, 'individual');
    });

    // Refused rather than guessed. A key renamed on the way through carries no
    // evidence of its kind, and inferring one from a name we chose ourselves is
    // the circularity this exists to avoid.
    test('a renamed key is refused rather than guessed at', () {
      expect(apiKeyFactsFromName('upload.p8'), isNull);
      expect(apiKeyFactsFromName('AuthKey_ZHGL57YJVC.p8.bak'), isNull);
      expect(apiKeyFactsFromName('AuthKey.p8'), isNull);
    });
  });
}
