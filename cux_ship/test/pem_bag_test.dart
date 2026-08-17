// SPDX-License-Identifier: Apache-2.0
//
// The pairing rule `--from-keychain` is built on, tested without a Mac.

import 'package:cux_ship/src/keychain.dart';
import 'package:test/test.dart';

/// What `openssl pkcs12 -nodes` prints for a keychain holding one identity.
///
/// The names are the point. macOS labels the *certificate* bag with the
/// certificate's name and the *key* bag with whatever the key was imported as
/// — here the account holder — so the two share no friendlyName at all. They
/// share only localKeyID.
const _identity = '''
Bag Attributes
    friendlyName: Apple Distribution: Herbert Poul (AT) (64ZPC769JY)
    localKeyID: A1 B2 C3
subject=UID=64ZPC769JY, CN=Apple Distribution: Herbert Poul (AT), OU=64ZPC769JY
-----BEGIN CERTIFICATE-----
MIIcertificate
-----END CERTIFICATE-----
Bag Attributes
    friendlyName: Herbert Poul
    localKeyID: A1 B2 C3
Key Attributes: <No Attributes>
-----BEGIN PRIVATE KEY-----
MIIkey
-----END PRIVATE KEY-----
Bag Attributes
    friendlyName: Apple Development: Herbert Poul (AT) (64ZPC769JY)
    localKeyID: D4 E5 F6
subject=UID=64ZPC769JY, CN=Apple Development: Herbert Poul (AT), OU=64ZPC769JY
-----BEGIN CERTIFICATE-----
MIIdevelopment
-----END CERTIFICATE-----
''';

void main() {
  group('pairing a certificate with its private key', () {
    final bags = parsePemBags(_identity);

    test('every bag is found, and its localKeyID with it', () {
      expect(bags, hasLength(3));
      expect(bags.map((b) => b.localKeyId), [
        'A1 B2 C3',
        'A1 B2 C3',
        'D4 E5 F6',
      ]);
    });

    test('certificate and key are told apart', () {
      expect(bags[0].isCertificate, isTrue);
      expect(bags[0].isPrivateKey, isFalse);
      expect(bags[1].isPrivateKey, isTrue);
      expect(bags[1].isCertificate, isFalse);
    });

    // The trap the whole port exists to preserve. A filter on friendlyName
    // matches the certificate and misses the key, producing a .p12 that imports
    // without complaint and cannot sign anything — which is what the first
    // version of the shell original did.
    test('localKeyID pairs them; friendlyName does not', () {
      const certificateName =
          'Apple Distribution: Herbert Poul (AT) (64ZPC769JY)';

      final byFriendlyName = bags
          .where((b) => b.body.contains(certificateName))
          .toList();
      expect(
        byFriendlyName.where((b) => b.isPrivateKey),
        isEmpty,
        reason: 'friendlyName cannot reach the key — that is the bug',
      );

      final byLocalKeyId = bags.where((b) => b.localKeyId == 'A1 B2 C3');
      expect(byLocalKeyId.where((b) => b.isCertificate), hasLength(1));
      expect(byLocalKeyId.where((b) => b.isPrivateKey), hasLength(1));
    });

    // An Apple Development certificate carries the same OU=, so matching the
    // team alone would export it and produce builds the App Store refuses.
    test('the team alone does not identify the certificate', () {
      final byTeam = bags.where(
        (b) => b.isCertificate && b.body.contains('64ZPC769JY'),
      );
      expect(byTeam, hasLength(2), reason: 'development carries the same OU');

      final byTeamAndKind = bags.where(
        (b) =>
            b.isCertificate &&
            b.body.contains('64ZPC769JY') &&
            b.body.contains('Apple Distribution'),
      );
      expect(byTeamAndKind, hasLength(1));
    });

    test('the certificate PEM comes back out on its own', () {
      expect(
        bags[0].certificatePem,
        '-----BEGIN CERTIFICATE-----\nMIIcertificate\n-----END CERTIFICATE-----',
      );
    });
  });
}
