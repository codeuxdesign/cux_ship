// SPDX-License-Identifier: Apache-2.0

import 'package:cux_ship_appstore/asc_client.dart';
import 'package:test/test.dart';

/// Not a real key — the claim selection is pure, so none of this signs
/// anything and no key material is needed to test it.
const _pem = 'not-a-key';

AscCredentials _team() => AscCredentials(
  keyId: 'ABC123',
  issuerId: 'issuer-uuid',
  privateKeyPem: _pem,
);

AscCredentials _individual() =>
    AscCredentials(keyId: 'ABC123', privateKeyPem: _pem);

void main() {
  group('which kind of key', () {
    test('an issuer id means a team key', () {
      expect(_team().isIndividual, isFalse);
    });

    test('no issuer id means an individual key', () {
      expect(_individual().isIndividual, isTrue);
    });
  });

  group('token claims', () {
    test('a team key names the team in iss', () {
      final claims = _team().tokenClaims;
      expect(claims['iss'], 'issuer-uuid');
      expect(claims.containsKey('sub'), isFalse);
    });

    test('an individual key says sub: user, literally', () {
      // Not the user's id — Apple never exposes it, and the string is the
      // whole claim.
      final claims = _individual().tokenClaims;
      expect(claims['sub'], 'user');
      expect(claims.containsKey('iss'), isFalse);
    });

    test('never both, whichever kind', () {
      for (final credentials in [_team(), _individual()]) {
        final claims = credentials.tokenClaims;
        expect(
          claims.containsKey('iss') && claims.containsKey('sub'),
          isFalse,
          reason: 'apple answers a token carrying both with a bare 401',
        );
      }
    });

    test('the audience is a string, not an array', () {
      // The library's `audience` field serialises to an array. The spec allows
      // it; Apple does not accept it.
      expect(_team().tokenClaims['aud'], isA<String>());
      expect(_team().tokenClaims['aud'], 'appstoreconnect-v1');
    });

    test('exp is left to the signer', () {
      expect(_team().tokenClaims.containsKey('exp'), isFalse);
    });
  });

  group('an individual key that also carries an issuer id', () {
    // altool requires --api-issuer even for an individual key, so the issuer
    // is now present for both kinds and cannot be what tells them apart.
    // Apple's filename prefix does that instead.
    AscCredentials individualWithIssuer() => AscCredentials(
      keyId: 'ABC123',
      issuerId: 'issuer-uuid',
      privateKeyPem: _pem,
      keyFileName: 'ApiKey_ABC123.p8',
    );

    test('is still individual, by its ApiKey_ prefix', () {
      expect(individualWithIssuer().isIndividual, isTrue);
    });

    test('still says sub: user and never names an issuer', () {
      final claims = individualWithIssuer().tokenClaims;
      expect(claims['sub'], 'user');
      expect(claims.containsKey('iss'), isFalse);
    });

    test('an AuthKey_ file with an issuer is a team key', () {
      final team = AscCredentials(
        keyId: 'ABC123',
        issuerId: 'issuer-uuid',
        privateKeyPem: _pem,
        keyFileName: 'AuthKey_ABC123.p8',
      );
      expect(team.isIndividual, isFalse);
      expect(team.tokenClaims['iss'], 'issuer-uuid');
    });
  });
}
