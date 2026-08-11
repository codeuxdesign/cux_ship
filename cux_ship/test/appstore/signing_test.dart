// SPDX-License-Identifier: Apache-2.0

import 'package:cux_ship/src/appstore/signing.dart';
import 'package:test/test.dart';

/// `now` is fixed so the expiry arithmetic is not a function of when the suite
/// runs. Every date below is relative to this.
final _now = DateTime.utc(2026, 8, 9, 12);

Map<String, dynamic> _certificate({
  String id = 'ABC',
  String type = 'DISTRIBUTION',
  String name = 'Herbert Poul (AT)',
  String? expires,
}) => {
  'id': id,
  'attributes': {
    'certificateType': type,
    'displayName': name,
    'expirationDate': ?expires,
  },
};

Map<String, dynamic> _bundleId(String identifier, {String? name}) => {
  'id': identifier,
  'attributes': {'identifier': identifier, 'name': name ?? identifier},
};

Map<String, dynamic> _profile({
  required String name,
  String state = 'ACTIVE',
  String type = 'IOS_APP_STORE',
  String? expires,
}) => {
  'id': name,
  'attributes': {
    'name': name,
    'profileState': state,
    'profileType': type,
    'expirationDate': ?expires,
  },
};

SigningAudit _audit({
  List<Map<String, dynamic>> certificates = const [],
  List<Map<String, dynamic>> bundleIds = const [],
  List<Map<String, dynamic>> profiles = const [],
  String? prefix,
}) => SigningAudit(
  certificates: certificates,
  bundleIds: bundleIds,
  profiles: profiles,
  ourPrefix: prefix,
  now: _now,
);

void main() {
  group('expiry', () {
    test('reports days left when comfortably far off', () {
      expect(
        _audit().expiryNote('2026-12-09T12:00:00.000+0000'),
        '  (122d left)',
      );
    });

    test('warns inside thirty days', () {
      expect(
        _audit().expiryNote('2026-09-06T12:00:00.000+0000'),
        contains('expires in 28d'),
      );
    });

    test('thirty days is still a warning, thirty one is not', () {
      expect(
        _audit().expiryNote('2026-09-08T12:00:00.000+0000'),
        contains('expires in 30d'),
      );
      expect(
        _audit().expiryNote('2026-09-09T12:00:00.000+0000'),
        isNot(contains('**')),
      );
    });

    test('says how long ago something expired', () {
      expect(
        _audit().expiryNote('2026-08-07T12:00:00.000+0000'),
        contains('EXPIRED 2d ago'),
      );
    });

    test('is silent when apple sent no date, and does not crash on junk', () {
      expect(_audit().expiryNote(null), isEmpty);
      expect(_audit().expiryNote('not a date'), isEmpty);
    });
  });

  group('certificates', () {
    test('groups by type, soonest expiry first', () {
      final audit = _audit(
        certificates: [
          _certificate(id: 'late', expires: '2027-01-01T00:00:00.000+0000'),
          _certificate(id: 'soon', expires: '2026-09-01T00:00:00.000+0000'),
          _certificate(id: 'dev', type: 'DEVELOPMENT'),
        ],
      );

      expect(
        audit.certificatesByType.keys,
        containsAll(['DISTRIBUTION', 'DEVELOPMENT']),
      );
      expect(audit.certificatesByType['DISTRIBUTION']!.map((c) => c['id']), [
        'soon',
        'late',
      ]);
    });

    test('one distribution certificate is not worth warning about', () {
      final audit = _audit(certificates: [_certificate()]);
      expect(audit.distributionCertificateCount, 1);
      expect(audit.distributionCapWorthWarningAbout, isFalse);
    });

    test('two is, because the cap may be two', () {
      final audit = _audit(
        certificates: [
          _certificate(id: 'a'),
          _certificate(id: 'b'),
        ],
      );
      expect(audit.distributionCapWorthWarningAbout, isTrue);
    });

    test('development certificates do not count toward it', () {
      final audit = _audit(
        certificates: [
          _certificate(id: 'a', type: 'DEVELOPMENT'),
          _certificate(id: 'b', type: 'DEVELOPMENT'),
        ],
      );
      expect(audit.distributionCapWorthWarningAbout, isFalse);
    });
  });

  group('app ids', () {
    test('an XC name means xcode registered it', () {
      expect(
        SigningAudit.isAutoCreated(_bundleId('a.b.c', name: 'XC a b c')),
        isTrue,
      );
      expect(
        SigningAudit.isAutoCreated(_bundleId('a.b.c', name: 'My App')),
        isFalse,
      );
    });

    test('the prefix covers the app and its extensions', () {
      final audit = _audit(
        bundleIds: [
          _bundleId('design.codeux.authpass.ios'),
          _bundleId('design.codeux.authpass.ios.autofill'),
          _bundleId('design.codeux.hbh.app.ios'),
        ],
        prefix: 'design.codeux.authpass.ios',
      );

      expect(audit.ourBundleIds.map((b) => b.attr('identifier')), [
        'design.codeux.authpass.ios',
        'design.codeux.authpass.ios.autofill',
      ]);
      expect(audit.otherBundleIds.map((b) => b.attr('identifier')), [
        'design.codeux.hbh.app.ios',
      ]);
    });

    test('a prefix matches on dot boundaries, not on characters', () {
      // design.codeux.authpass.iossomething is a different app.
      final audit = _audit(
        bundleIds: [_bundleId('design.codeux.authpass.iossomething')],
        prefix: 'design.codeux.authpass.ios',
      );
      expect(audit.ourBundleIds, isEmpty);
    });

    test('without a prefix nothing is claimed as ours', () {
      final audit = _audit(bundleIds: [_bundleId('a.b.c')]);
      expect(audit.ourBundleIds, isEmpty);
      expect(audit.otherBundleIds, hasLength(1));
    });
  });

  group('profiles', () {
    test('counts the ones apple no longer considers active', () {
      final audit = _audit(
        profiles: [
          _profile(name: 'a'),
          _profile(name: 'b', state: 'INVALID'),
          _profile(name: 'c', state: 'EXPIRED'),
        ],
      );
      expect(audit.inactiveProfileCount, 2);
    });

    test('counts the ones expiring soon', () {
      final audit = _audit(
        profiles: [
          _profile(name: 'soon', expires: '2026-08-20T00:00:00.000+0000'),
          _profile(name: 'later', expires: '2027-08-20T00:00:00.000+0000'),
          _profile(name: 'undated'),
        ],
      );
      expect(audit.expiringProfileCount, 1);
    });

    test('sorts by name so two runs can be diffed', () {
      final audit = _audit(
        profiles: [
          _profile(name: 'b'),
          _profile(name: 'a'),
        ],
      );
      expect(audit.profilesByName.map((p) => p.attr('name')), ['a', 'b']);
    });
  });

  group('projectPrefix', () {
    test('passes a bundle id through', () {
      expect(
        projectPrefix('design.codeux.holdthewheel'),
        'design.codeux.holdthewheel',
      );
    });

    test('treats absent and blank the same', () {
      expect(projectPrefix(null), isNull);
      expect(projectPrefix('   '), isNull);
    });
  });

  group('attributes', () {
    test('a missing attributes object is not an error', () {
      expect(<String, dynamic>{}.attr('identifier'), isNull);
      expect(<String, dynamic>{'attributes': null}.attr('identifier'), isNull);
    });
  });
}
