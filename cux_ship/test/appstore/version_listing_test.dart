// SPDX-License-Identifier: Apache-2.0
//
// `appstore versions` prints two lines per version and the second of them —
// the copyright — is there because Apple requires it before review and
// defaults it to null. Turning the listing into a value had to keep both
// lines, so a consumer showing the store's own output still shows the half
// that is a warning.
import 'dart:io';

import 'package:cux_ship/read.dart';
import 'package:cux_ship/src/appstore/app_store.dart';
import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:cux_ship/src/appstore/reads.dart';
import 'package:test/test.dart';

Map<String, dynamic> _version(
  String versionString, {
  String? state = 'READY_FOR_SALE',
  String? releaseType = 'MANUAL',
  String? copyright,
  String platform = 'IOS',
}) => {
  'type': 'appStoreVersions',
  'id': 'version-$platform-$versionString',
  '_platform': platform,
  'attributes': {
    'versionString': versionString,
    'appStoreState': ?state,
    'releaseType': ?releaseType,
    'copyright': ?copyright,
  },
};

/// Canned App Store Connect, narrowed to an app's `appStoreVersions`.
///
/// Filters by platform because the real endpoint does and the tested read
/// passes the filter: versions are per-platform, and a fake that ignored it
/// could not tell a dropped `filter[platform]` from a correct one.
class _FakeClient implements AscClient {
  _FakeClient(this.versions);

  final List<Map<String, dynamic>> versions;
  final List<String> paths = <String>[];

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async {
    paths.add(path);
    final platform = query?['filter[platform]'];
    return versions
        .where((v) => platform == null || v['_platform'] == platform)
        .toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemoryStdout implements Stdout {
  final buffer = StringBuffer();

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  void write(Object? object) => buffer.write(object);

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<String> _printed(Future<void> Function() body) async {
  final captured = _MemoryStdout();
  await IOOverrides.runZoned(body, stdout: () => captured);
  await captured.close();
  return captured.buffer.toString();
}

void main() {
  final app = App('app-1', 'Example', 'design.codeux.example');

  AppStore storeOf(_FakeClient client, {AscPlatform? platform}) => AppStore(
    client,
    Writer(client, dryRun: true),
    platform: platform ?? AscPlatform.ios,
  );

  AppStoreVersions listingOf(
    List<Map<String, dynamic>> payload, {
    AscPlatform platform = AscPlatform.ios,
  }) => appStoreVersionsFrom(payload, platform);

  test('a version carries the three fields a release train reads', () {
    final version = listingOf([
      _version('1.4.0', state: 'PREPARE_FOR_SUBMISSION', releaseType: 'MANUAL'),
    ]).versions.single;

    expect(version.versionString, '1.4.0');
    expect(version.appStoreState, 'PREPARE_FOR_SUBMISSION');
    expect(version.releaseType, 'MANUAL');
  });

  test('and says whether a push against it would be accepted', () {
    // The same rule `ensureVersion` refuses on, so a caller can find out
    // before it asks rather than from a 409.
    expect(
      listingOf([
        _version('1.4.0', state: 'PREPARE_FOR_SUBMISSION'),
      ]).versions.single.editable,
      isTrue,
    );
    expect(
      listingOf([
        _version('1.3.0', state: 'READY_FOR_SALE'),
      ]).versions.single.editable,
      isFalse,
    );
  });

  test('an unreadable state is not editable rather than assumed so', () {
    expect(
      listingOf([_version('1.4.0', state: null)]).versions.single.editable,
      isFalse,
    );
  });

  test('a version can be looked up by its string', () {
    final listing = listingOf([_version('1.4.0'), _version('1.3.0')]);

    expect(listing.version('1.3.0')?.appStoreState, 'READY_FOR_SALE');
    expect(listing.version('9.9.9'), isNull);
  });

  group('lines', () {
    test('are what `appstore versions` has always printed', () {
      final listing = listingOf([
        _version('1.4.0', state: 'READY_FOR_SALE', releaseType: 'MANUAL'),
      ]);

      expect(listing.lines, [
        '  1.4.0  READY_FOR_SALE  MANUAL',
        '    copyright: (unset)',
      ]);
    });

    test('report the copyright when Apple has one', () {
      final listing = listingOf([
        _version('1.4.0', copyright: '2026 Codeux Design'),
      ]);

      expect(listing.lines.last, '    copyright: 2026 Codeux Design');
    });

    test('name the platform when there is nothing to list', () {
      // "no versions" alone does not say which of the two platforms was asked,
      // and a project shipping both reads that line twice.
      expect(listingOf(const [], platform: AscPlatform.macos).lines, [
        '  no App Store versions for MAC_OS',
      ]);
    });
  });

  group('the command', () {
    test('prints exactly the model lines', () async {
      final payload = [_version('1.4.0'), _version('1.3.0')];
      final out = await _printed(
        () => printVersions(storeOf(_FakeClient(payload)), app),
      );

      expect(out, '${listingOf(payload).lines.join('\n')}\n');
    });

    test('asks for this app and this platform only', () async {
      final client = _FakeClient([
        _version('2.0.0', platform: 'MAC_OS'),
        _version('1.4.0', platform: 'IOS'),
      ]);
      final out = await _printed(() => printVersions(storeOf(client), app));

      expect(out, contains('1.4.0'));
      expect(out, isNot(contains('2.0.0')));
      expect(client.paths.single, '/v1/apps/app-1/appStoreVersions');
    });
  });
}
