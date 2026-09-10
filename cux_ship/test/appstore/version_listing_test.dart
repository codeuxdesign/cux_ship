// SPDX-License-Identifier: Apache-2.0
//
// `appstore versions` prints two lines per version and the second of them —
// the copyright — is there because Apple requires it before review and
// defaults it to null. Turning the listing into a value had to keep both
// lines, so a consumer showing the store's own output still shows the half
// that is a warning.
import 'dart:io';

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
  String? buildId = 'build-1',
}) => {
  'type': 'appStoreVersions',
  'id': 'version-$platform-$versionString',
  '_platform': platform,
  '_buildId': ?buildId,
  'attributes': {
    'versionString': versionString,
    'appStoreState': ?state,
    'releaseType': ?releaseType,
    'copyright': ?copyright,
  },
};

/// A `builds` resource as Apple sideloads one.
///
/// `version` is Apple's name for `CFBundleVersion`, which reads backwards and
/// is the single easiest thing to get wrong here — the same trap
/// `appStoreBuildFrom` carries a comment about.
Map<String, dynamic> _build(String id, String buildNumber) => {
  'type': 'builds',
  'id': id,
  'attributes': {'version': buildNumber},
};

/// [resource] as it comes back **with** `include=build`: the relationship
/// carries a `data` key naming the build.
///
/// The un-included shape is what `_version` already produces — no
/// `relationships` at all — and the difference between the two is the fact this
/// file's fake was built to carry.
Map<String, dynamic> _asIncluded(Map<String, dynamic> resource) => {
  ...resource,
  'relationships': {
    'build': {
      'links': {'self': 'https://example.invalid/rel'},
      'data': {'type': 'builds', 'id': resource['_buildId']},
    },
  },
};

/// Canned App Store Connect, narrowed to an app's `appStoreVersions`.
///
/// Filters by platform because the real endpoint does and the tested read
/// passes the filter: versions are per-platform, and a fake that ignored it
/// could not tell a dropped `filter[platform]` from a correct one.
///
/// **And it honours `include` the way Apple was measured to.** The branch under
/// test resolves a build through `relationships.build.data`, so a fake that
/// sideloaded unconditionally could not tell a request that asked for the
/// include from one that forgot — which is `docs/CONTRIBUTING.md`'s rule about
/// a fake carrying the semantics the tested branch selects on, and is the whole
/// reason the build number is reachable at all.
///
/// The two shapes are what a live account returned, recorded in
/// `AppStore.appStoreVersions`:
///
/// - no `include=build` — `relationships.build` carries `links` and **no
///   `data` key at all**
/// - `include=build` — `data` names the build, and it arrives in `included`
class _FakeClient implements AscClient {
  _FakeClient(this.versions, {this.builds = const {}});

  final List<Map<String, dynamic>> versions;

  /// Build id -> `CFBundleVersion`, sideloaded when the query asks.
  final Map<String, String> builds;

  final List<String> paths = <String>[];
  final List<Map<String, String>?> queries = <Map<String, String>?>[];

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async => (await getAllWithIncluded(path, query: query)).data;

  @override
  Future<
    ({
      List<Map<String, dynamic>> data,
      Map<String, Map<String, dynamic>> included,
    })
  >
  getAllWithIncluded(String path, {Map<String, String>? query}) async {
    paths.add(path);
    queries.add(query);
    final platform = query?['filter[platform]'];
    final matching = versions
        .where((v) => platform == null || v['_platform'] == platform)
        .toList();
    final asked = (query?['include'] ?? '').split(',').contains('build');

    final data = <Map<String, dynamic>>[];
    final included = <String, Map<String, dynamic>>{};
    for (final version in matching) {
      final buildId = version['_buildId'] as String?;
      final relationship = <String, dynamic>{
        'links': {'self': 'https://example.invalid/rel'},
        // The measured difference: the key exists only when it was asked for.
        if (asked) ...{'data': ?_link(buildId)},
      };
      data.add({
        ...version,
        'relationships': {'build': relationship},
      });
      if (asked && buildId != null && builds.containsKey(buildId)) {
        included['builds:$buildId'] = _build(buildId, builds[buildId]!);
      }
    }
    // **Single-page, and deliberately not pretending otherwise.** This fake
    // stands in for the whole client, so pagination never runs through it and
    // a `pageSize` here would only be theatre. The across-pages merge is a
    // property of `AscClient.getAllWithIncluded` itself and is tested against
    // it directly, over a real HTTP seam, in `asc_included_test.dart`.
    return (data: data, included: included);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic>? _link(String? buildId) =>
    buildId == null ? null : {'type': 'builds', 'id': buildId};

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
    Map<String, Map<String, dynamic>> included = const {},
  }) => appStoreVersionsFrom(payload, platform, included: included);

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

    test(
      'and asks for the build, which is the only route to its number',
      () async {
        // **The query is the whole mechanism.** Apple's version attributes carry
        // no build; the build is a relationship, and it arrives only because
        // this request asks for it to be included. Dropping `include=build`
        // costs no request and no error — it costs every build number, silently.
        final client = _FakeClient(
          [_version('1.4.0')],
          builds: const {'build-1': '169'},
        );
        final out = await _printed(() => printVersions(storeOf(client), app));

        expect(client.queries.single?['include'], 'build');
        expect(out, contains('build 169'));
      },
    );

    test(
      'and reads the number through the relationship, not off the version',
      () async {
        // Two versions, two different builds, so a reader that took the first
        // included resource for every version would pass a one-version test and
        // fail here.
        final client = _FakeClient(
          [
            {..._version('1.4.0'), '_buildId': 'build-a'},
            {..._version('1.3.0'), '_buildId': 'build-b'},
          ],
          builds: const {'build-a': '169', 'build-b': '168'},
        );
        final out = await _printed(() => printVersions(storeOf(client), app));

        expect(out, contains('1.4.0  READY_FOR_SALE  MANUAL  build 169'));
        expect(out, contains('1.3.0  READY_FOR_SALE  MANUAL  build 168'));
      },
    );
  });

  group('the build a version names', () {
    test('is null when Apple names none, and the line says nothing', () {
      // The `PREPARE_FOR_SUBMISSION` shape: a version exists and no build is
      // attached to it. The line reads exactly as it did before this field
      // existed rather than carrying `build null`.
      final listing = listingOf([
        _asIncluded(
          _version('1.4.0', state: 'PREPARE_FOR_SUBMISSION', buildId: null),
        ),
      ]);

      expect(listing.versions.single.buildNumber, isNull);
      expect(listing.versions.single.buildNumberAsInt, isNull);
      expect(listing.lines.first, isNot(contains('build')));
    });

    test('is null when nothing asked for it, which is a different fact', () {
      // **Measured against a live account**: without `include=build` the
      // relationship carries `links` and no `data` key at all. So this is the
      // package not having asked rather than Apple having nothing to name —
      // and both land on null, which is what the field's doc comment says it
      // cannot diagnose.
      final unasked = appStoreVersionFrom(_version('1.4.0'));

      expect(unasked.buildNumber, isNull);
    });

    test('is an integer beside the string, for the comparison', () {
      final version = listingOf(
        [_asIncluded(_version('1.4.0'))],
        included: {'builds:build-1': _build('build-1', '169')},
      ).versions.single;

      expect(version.buildNumber, '169');
      expect(version.buildNumberAsInt, 169);
    });

    test('and the integer is null for a dotted one, not zero', () {
      // `CFBundleVersion` may be dotted, which is why the string is the field
      // and the integer is the companion. Zero would sort it below every real
      // build and say something false about it.
      final version = listingOf(
        [_asIncluded(_version('1.4.0'))],
        included: {'builds:build-1': _build('build-1', '1.2.3')},
      ).versions.single;

      expect(version.buildNumber, '1.2.3');
      expect(version.buildNumberAsInt, isNull);
    });

    test('and a build Apple named but did not send is null, not a crash', () {
      // The relationship points at a resource `included` does not carry —
      // which should not happen and is not worth throwing over, because a
      // listing that fails entirely is worse than one missing a number.
      final version = listingOf([
        _asIncluded(_version('1.4.0')),
      ]).versions.single;

      expect(version.buildNumber, isNull);
    });
  });
}
