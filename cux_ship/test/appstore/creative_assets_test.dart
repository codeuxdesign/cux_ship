// SPDX-License-Identifier: Apache-2.0
//
// `appstore creative-assets`: the product page header and the search results
// image, through the App Asset Library (App Store Connect API 4.5.1).
//
// The fake below carries the semantics the tested branches select on, per
// docs/CONTRIBUTING.md: it filters images by category and placements by type
// and by image server-side, because the idempotency of a placement rests on
// `filter[image]` being honoured — a fake that ignored it would report every
// placement as already joining the wanted image.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:cux_ship/src/appstore/cli.dart';
import 'package:cux_ship/src/appstore/creative_assets.dart';
import 'package:test/test.dart';

/// A PNG header [readImageInfo] accepts: signature, IHDR, IEND. [seed] varies
/// the bytes without varying the dimensions, so two "different images" of
/// the same size have different checksums.
Uint8List _png(int width, int height, {int seed = 0}) {
  List<int> be32(int v) => [
    v >> 24 & 255,
    v >> 16 & 255,
    v >> 8 & 255,
    v & 255,
  ];
  return Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    ...be32(13), ...'IHDR'.codeUnits, ...be32(width), ...be32(height),
    8, 2, 0, 0, 0, ...be32(seed),
    ...be32(0), ...'IEND'.codeUnits, ...be32(0),
  ]);
}

String _md5(List<int> bytes) => md5.convert(bytes).toString();

typedef _Call = ({
  String method,
  String path,
  Map<String, String>? query,
  Object? body,
});

class _FakeClient implements AscClient {
  _FakeClient({
    this.versionState = 'PREPARE_FOR_SUBMISSION',
    this.locales = const ['en-US'],
    this.processedState = 'PREPARE_FOR_SUBMISSION',
    this.stateDetails = const [],
  });

  final String versionState;
  final List<String> locales;

  /// What an image reads back as once committed.
  final String processedState;
  final List<Map<String, String>> stateDetails;

  final calls = <_Call>[];
  final images = <Map<String, dynamic>>[];
  final placements = <({String id, String type, String loc, String image})>[];
  final submissions = <({String id, String state, List<String> items})>[];
  final uploadedBytes = <int>[];
  var _next = 0;

  String _id(String prefix) => '$prefix-${++_next}';

  /// An image already in the library, as an earlier run would have left it.
  void seedImage(
    List<int> bytes, {
    String state = 'PREPARE_FOR_SUBMISSION',
    String name = 'u.png',
    String? referenceName,
    String category = 'CREATIVE_ASSETS',
  }) {
    images.add({
      'type': 'appAssetLibraryImages',
      'id': _id('image'),
      'attributes': {
        'category': category,
        'fileName': name,
        'referenceName':
            referenceName ?? creativeReferenceName(name, _md5(bytes)),
        'state': state,
      },
    });
  }

  Iterable<Map<String, dynamic>> _placementResources(
    Iterable<({String id, String type, String loc, String image})> rows,
  ) => rows.map(
    (p) => {
      'type': 'appAssetLibraryPlacements',
      'id': p.id,
      'attributes': {'placementType': p.type},
    },
  );

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async {
    calls.add((method: 'GET', path: path, query: query, body: null));
    if (path == '/v1/apps') {
      return [
        if (query?['filter[bundleId]'] == 'design.codeux.example')
          {
            'type': 'apps',
            'id': 'app-1',
            'attributes': {
              'bundleId': 'design.codeux.example',
              'name': 'Example',
            },
          },
      ];
    }
    if (path == '/v1/apps/app-1/appStoreVersions') {
      return [
        if (query?['filter[versionString]'] == '1.2.0')
          {
            'type': 'appStoreVersions',
            'id': 'version-1',
            'attributes': {
              'versionString': '1.2.0',
              'appStoreState': versionState,
            },
          },
      ];
    }
    if (path == '/v1/appStoreVersions/version-1/appStoreVersionLocalizations') {
      return [
        for (final locale in locales)
          {
            'type': 'appStoreVersionLocalizations',
            'id': 'loc-$locale',
            'attributes': {'locale': locale},
          },
      ];
    }
    if (path == '/v1/appAssetLibraries/library-1/images') {
      final category = query?['filter[category]'];
      return [
        for (final image in images)
          if (category == null ||
              (image['attributes'] as Map)['category'] == category)
            image,
      ];
    }
    final placementsOf = RegExp(
      r'^/v1/appStoreVersionLocalizations/([^/]+)/placements$',
    ).firstMatch(path);
    if (placementsOf != null) {
      final type = query?['filter[placementType]'];
      final image = query?['filter[image]'];
      return _placementResources(
        placements.where(
          (p) =>
              p.loc == placementsOf.group(1) &&
              (type == null || p.type == type) &&
              (image == null || p.image == image),
        ),
      ).toList();
    }
    if (path == '/v1/reviewSubmissions') {
      return [
        for (final s in submissions)
          if (s.state == query?['filter[state]'])
            {'type': 'reviewSubmissions', 'id': s.id},
      ];
    }
    final items = RegExp(
      r'^/v1/reviewSubmissions/([^/]+)/items$',
    ).firstMatch(path);
    if (items != null) {
      final s = submissions.firstWhere((s) => s.id == items.group(1));
      return [
        for (final item in s.items)
          {'type': 'reviewSubmissionItems', 'id': item},
      ];
    }
    throw StateError('unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    calls.add((method: 'GET', path: path, query: query, body: null));
    if (path == '/v1/apps/app-1/assetLibrary') {
      return {
        'data': {'type': 'appAssetLibraries', 'id': 'library-1'},
      };
    }
    final image = RegExp(
      r'^/v1/appAssetLibraryImages/([^/]+)$',
    ).firstMatch(path);
    if (image != null) {
      return {'data': images.firstWhere((i) => i['id'] == image.group(1))};
    }
    throw StateError('unexpected GET $path');
  }

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    calls.add((method: 'POST', path: path, query: null, body: body));
    final data = body['data'] as Map<String, dynamic>;
    final relationships =
        data['relationships'] as Map<String, dynamic>? ?? const {};
    String rel(String name) =>
        ((relationships[name] as Map)['data'] as Map)['id'] as String;
    switch (path) {
      case '/v1/appAssetLibraryImages':
        final attributes = Map<String, dynamic>.of(
          data['attributes'] as Map<String, dynamic>,
        );
        final size = attributes['fileSize'] as int;
        final id = _id('image');
        images.add({
          'type': 'appAssetLibraryImages',
          'id': id,
          'attributes': {...attributes, 'state': 'AWAITING_UPLOAD'},
        });
        return {
          'data': {
            'type': 'appAssetLibraryImages',
            'id': id,
            'attributes': {
              ...attributes,
              'state': 'AWAITING_UPLOAD',
              'uploadOperations': [
                // Two parts, so a reassembly that dropped one would show.
                {
                  'method': 'PUT',
                  'url': 'https://upload.example/$id/0',
                  'offset': 0,
                  'length': size ~/ 2,
                },
                {
                  'method': 'PUT',
                  'url': 'https://upload.example/$id/1',
                  'offset': size ~/ 2,
                  'length': size - size ~/ 2,
                },
              ],
            },
          },
        };
      case '/v1/appAssetLibraryPlacements':
        final id = _id('placement');
        placements.add((
          id: id,
          type: (data['attributes'] as Map)['placementType'] as String,
          loc: rel('appStoreVersionLocalization'),
          image: rel('image'),
        ));
        return {
          'data': {'type': 'appAssetLibraryPlacements', 'id': id},
        };
      case '/v1/reviewSubmissions':
        final id = _id('submission');
        submissions.add((id: id, state: 'READY_FOR_REVIEW', items: []));
        return {
          'data': {'type': 'reviewSubmissions', 'id': id},
        };
      case '/v1/reviewSubmissionItems':
        final s = submissions.firstWhere(
          (s) => s.id == rel('reviewSubmission'),
        );
        s.items.add(rel('appAssetLibraryImage'));
        return {
          'data': {'type': 'reviewSubmissionItems', 'id': _id('item')},
        };
    }
    throw StateError('unexpected POST $path');
  }

  @override
  Future<Map<String, dynamic>> patch(
    String path,
    Map<String, dynamic> body,
  ) async {
    calls.add((method: 'PATCH', path: path, query: null, body: body));
    final image = RegExp(
      r'^/v1/appAssetLibraryImages/([^/]+)$',
    ).firstMatch(path);
    if (image != null) {
      final resource = images.firstWhere((i) => i['id'] == image.group(1));
      final attributes = resource['attributes'] as Map<String, dynamic>;
      attributes['state'] = processedState;
      if (stateDetails.isNotEmpty) {
        attributes['stateDetails'] = stateDetails;
      }
      return {'data': resource};
    }
    final submission = RegExp(
      r'^/v1/reviewSubmissions/([^/]+)$',
    ).firstMatch(path);
    if (submission != null) {
      for (final item
          in submissions.firstWhere((s) => s.id == submission.group(1)).items) {
        (images.firstWhere((i) => i['id'] == item)['attributes']
                as Map)['state'] =
            'WAITING_FOR_REVIEW';
      }
      return {
        'data': {'type': 'reviewSubmissions', 'id': submission.group(1)},
      };
    }
    throw StateError('unexpected PATCH $path');
  }

  @override
  Future<void> delete(String path) async {
    calls.add((method: 'DELETE', path: path, query: null, body: null));
    final placement = RegExp(
      r'^/v1/appAssetLibraryPlacements/([^/]+)$',
    ).firstMatch(path);
    if (placement != null) {
      placements.removeWhere((p) => p.id == placement.group(1));
      return;
    }
    final image = RegExp(
      r'^/v1/appAssetLibraryImages/([^/]+)$',
    ).firstMatch(path);
    if (image != null) {
      images.removeWhere((i) => i['id'] == image.group(1));
      return;
    }
    throw StateError('unexpected DELETE $path');
  }

  @override
  Future<void> uploadOperation(
    Map<String, dynamic> operation,
    List<int> chunk,
  ) async {
    calls.add((
      method: 'PUT',
      path: operation['url'] as String,
      query: null,
      body: null,
    ));
    uploadedBytes.addAll(chunk);
  }

  Iterable<_Call> get writes => calls.where((c) => c.method != 'GET');

  @override
  AscCredentials get credentials =>
      AscCredentials(keyId: 'K', issuerId: 'I', privateKeyPem: 'unused');

  @override
  void close() {}

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

late Directory _root;

void _write(String relative, List<int> bytes) {
  final file = File('${_root.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
}

final _universal = _png(5244, 2950);

Future<({String out, String err})> _run(
  _FakeClient client,
  List<String> extra,
) async {
  final args = buildAscParser(AscCommand.creativeAssets).parse([
    '--bundle-id',
    'design.codeux.example',
    '--metadata',
    _root.path,
    ...extra,
  ]);
  final out = _MemoryStdout();
  final err = _MemoryStdout();
  await IOOverrides.runZoned(
    () => runAsc(AscCommand.creativeAssets, args, ascClient: client),
    stdout: () => out,
    stderr: () => err,
  );
  await out.close();
  await err.close();
  return (out: out.buffer.toString(), err: err.buffer.toString());
}

void main() {
  group('the reference name carries the checksum', () {
    test('and reads back exactly what was written', () {
      final sum = 'a' * 32;
      expect(
        checksumFromReferenceName(creativeReferenceName('h.png', sum)),
        sum,
      );
    });

    test('a name this package did not write is never a match', () {
      expect(checksumFromReferenceName('Header, October'), isNull);
      expect(checksumFromReferenceName(null), isNull);
      // Renamed in the console with the marker edited: not 32 hex digits.
      expect(checksumFromReferenceName('h.png [md5 abc]'), isNull);
    });
  });

  group('what the library already holds decides the upload', () {
    LibraryImage image(
      String state, {
      String sum = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      String id = 'i',
    }) => (
      id: id,
      fileName: 'h.png',
      referenceName: creativeReferenceName('h.png', sum),
      state: state,
      specId: null,
      stateDetails: const [],
    );
    const sum = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    test('nothing with these bytes is a fresh upload', () {
      final match = matchInLibrary([image('APPROVED', sum: 'b' * 32)], sum);
      expect(
        match,
        isA<UploadImage>().having((m) => m.stale, 'stale', isEmpty),
      );
    });

    test('a usable copy is reused, the furthest along first', () {
      final match = matchInLibrary([
        image('PREPARE_FOR_SUBMISSION', id: 'draft'),
        image('APPROVED', id: 'approved'),
      ], sum);
      expect(
        match,
        isA<ReuseImage>().having((m) => m.image.id, 'id', 'approved'),
      );
    });

    test('a copy still processing is waited for, not uploaded twice', () {
      expect(
        matchInLibrary([image('UPLOAD_COMPLETE')], sum),
        isA<AwaitImage>(),
      );
    });

    test('a copy App Review rejected stops the run', () {
      expect(matchInLibrary([image('REJECTED')], sum), isA<RejectedImage>());
    });

    test('a failed or never-committed copy is deleted and uploaded again', () {
      final match = matchInLibrary([
        image('FAILED', id: 'f'),
        image('AWAITING_UPLOAD', id: 'a'),
      ], sum);
      expect(
        match,
        isA<UploadImage>().having((m) => m.stale.map((i) => i.id), 'stale', [
          'f',
          'a',
        ]),
      );
    });

    test('an archived copy is somebody retiring it, and is left alone', () {
      final match = matchInLibrary([image('ARCHIVED')], sum);
      expect(
        match,
        isA<UploadImage>().having((m) => m.stale, 'stale', isEmpty),
      );
    });
  });

  group('planning one placement', () {
    // Field by field: a record holding a list compares the list by identity.
    void expectPlan(PlacementPlan plan, String? keep, List<String> delete) {
      expect(plan.keep, keep);
      expect(plan.delete, delete);
      expect(plan.create, keep == null);
    }

    test('the wanted image already placed alone is unchanged', () {
      expectPlan(planPlacement(existing: ['p1'], joining: ['p1']), 'p1', []);
    });

    test('another image placed there is removed before one goes on', () {
      expectPlan(planPlacement(existing: ['p1'], joining: []), null, ['p1']);
    });

    test('the wanted one beside another keeps the wanted one', () {
      expectPlan(planPlacement(existing: ['p1', 'p2'], joining: ['p2']), 'p2', [
        'p1',
      ]);
    });
  });

  group('appstore creative-assets', () {
    setUp(() {
      exitCode = 0;
      _root = Directory.systemTemp.createTempSync('creative_assets_test');
    });
    tearDown(() {
      exitCode = 0;
      _root.deleteSync(recursive: true);
    });

    test(
      'a universal image is reserved, sent, committed and placed twice',
      () async {
        _write(
          'listings/en-US/creative_assets/UNIVERSAL/header.png',
          _universal,
        );
        final client = _FakeClient();

        final said = await _run(client, ['--version-name', '1.2.0']);

        expect(exitCode, 0, reason: said.err);
        final reserve = client.writes.firstWhere(
          (c) => c.path == '/v1/appAssetLibraryImages',
        );
        final attributes =
            ((reserve.body! as Map)['data'] as Map)['attributes'] as Map;
        expect(attributes['category'], 'CREATIVE_ASSETS');
        expect(attributes['fileName'], 'header.png');
        expect(attributes['fileSize'], _universal.length);
        expect(
          attributes['referenceName'],
          'header.png [md5 ${_md5(_universal)}]',
        );
        expect(
          client.uploadedBytes,
          _universal,
          reason: 'both parts, in order',
        );

        final commit = client.writes.firstWhere((c) => c.method == 'PATCH');
        expect(((commit.body! as Map)['data'] as Map)['attributes'], {
          'uploaded': true,
        }, reason: 'the asset library takes no sourceFileChecksum');

        expect(
          client.placements.map((p) => (p.type, p.loc, p.image)),
          unorderedEquals([
            ('PRODUCT_PAGE_HEADER_ASSET', 'loc-en-US', 'image-1'),
            ('APP_STORE_SEARCH_RESULTS_ASSET', 'loc-en-US', 'image-1'),
          ]),
        );
        expect(said.out, contains('state PREPARE_FOR_SUBMISSION'));
        expect(
          client.calls.where((c) => c.path.startsWith('/v1/reviewSubmission')),
          isEmpty,
          reason: 'nothing is submitted without --submit-for-review',
        );
      },
    );

    test('a second run over the same bytes writes nothing at all', () async {
      _write('listings/en-US/creative_assets/UNIVERSAL/header.png', _universal);
      final client = _FakeClient();
      await _run(client, ['--version-name', '1.2.0']);
      client.calls.clear();

      final said = await _run(client, ['--version-name', '1.2.0']);

      expect(exitCode, 0, reason: said.err);
      expect(client.writes, isEmpty);
      expect(said.out, contains('already in the asset library'));
      expect(said.out, contains('already placed, unchanged'));
    });

    test('changed bytes upload anew and replace the placement', () async {
      _write('listings/en-US/creative_assets/UNIVERSAL/header.png', _universal);
      final client = _FakeClient();
      await _run(client, ['--version-name', '1.2.0']);
      final before = client.placements.map((p) => p.id).toSet();

      final changed = _png(5244, 2950, seed: 7);
      _write('listings/en-US/creative_assets/UNIVERSAL/header.png', changed);
      await _run(client, ['--version-name', '1.2.0']);

      expect(exitCode, 0);
      expect(client.images, hasLength(2));
      expect(client.placements, hasLength(2));
      expect(
        client.placements.map((p) => p.id).toSet().intersection(before),
        isEmpty,
      );
      expect(client.placements.map((p) => p.image).toSet(), {'image-4'});
    });

    test('the same bytes in two locales are uploaded once', () async {
      _write('listings/en-US/creative_assets/UNIVERSAL/header.png', _universal);
      _write('listings/de-DE/creative_assets/UNIVERSAL/header.png', _universal);
      final client = _FakeClient(locales: ['en-US', 'de-DE']);

      await _run(client, ['--version-name', '1.2.0']);

      expect(exitCode, 0);
      expect(
        client.writes.where((c) => c.path == '/v1/appAssetLibraryImages'),
        hasLength(1),
      );
      expect(client.placements.map((p) => p.loc).toSet(), {
        'loc-en-US',
        'loc-de-DE',
      });
    });

    test('a dry run reads and writes nothing', () async {
      _write('listings/en-US/creative_assets/UNIVERSAL/header.png', _universal);
      final client = _FakeClient();

      final said = await _run(client, [
        '--version-name',
        '1.2.0',
        '--dry-run',
        '--submit-for-review',
      ]);

      expect(exitCode, 0, reason: said.err);
      expect(client.writes, isEmpty);
      expect(said.out, contains('would create: en-US UNIVERSAL: header.png'));
      expect(
        said.out,
        contains('would create: placed as the en-US PRODUCT_PAGE_HEADER_ASSET'),
      );
      expect(said.out, contains('would upload'));
    });

    test('without --version-name nothing is placed, and it says so', () async {
      _write('listings/en-US/creative_assets/UNIVERSAL/header.png', _universal);
      final client = _FakeClient();

      final said = await _run(client, []);

      expect(exitCode, 0, reason: said.err);
      expect(client.calls.where((c) => c.path.contains('placements')), isEmpty);
      expect(said.out, contains('PRODUCT_PAGE_HEADER_ASSET not placed'));
    });

    test(
      'a version that is not editable is refused before any upload',
      () async {
        _write(
          'listings/en-US/creative_assets/UNIVERSAL/header.png',
          _universal,
        );
        final client = _FakeClient(versionState: 'READY_FOR_SALE');

        final said = await _run(client, ['--version-name', '1.2.0']);

        expect(exitCode, 1);
        expect(said.err, contains('READY_FOR_SALE'));
        expect(client.writes, isEmpty);
      },
    );

    test('a locale the version lacks is refused before any upload', () async {
      _write('listings/de-DE/creative_assets/UNIVERSAL/header.png', _universal);
      final client = _FakeClient();

      final said = await _run(client, ['--version-name', '1.2.0']);

      expect(exitCode, 1);
      expect(said.err, contains('no de-DE localization'));
      expect(client.writes, isEmpty);
    });

    test("Apple's processing verdict is reported in Apple's words", () async {
      _write('listings/en-US/creative_assets/UNIVERSAL/header.png', _universal);
      final client = _FakeClient(
        processedState: 'FAILED',
        stateDetails: [
          {
            'code': 'IMAGE_INCORRECT_DIMENSIONS',
            'description': 'no spec matches',
          },
        ],
      );

      final said = await _run(client, ['--version-name', '1.2.0']);

      expect(exitCode, 1);
      expect(
        said.err,
        contains('IMAGE_INCORRECT_DIMENSIONS - no spec matches'),
      );
      expect(
        client.placements,
        isEmpty,
        reason: 'a failed image is not placed',
      );
    });

    test('a rejected copy of the same bytes stops the run', () async {
      _write('listings/en-US/creative_assets/UNIVERSAL/header.png', _universal);
      final client = _FakeClient()
        ..seedImage(_universal, state: 'REJECTED', name: 'header.png');

      final said = await _run(client, []);

      expect(exitCode, 1);
      expect(said.err, contains('rejected these exact bytes'));
      expect(client.writes, isEmpty);
    });

    test('a failed copy of the same bytes is deleted, then uploaded', () async {
      // Apple's guidance for FAILED is delete and reserve again. Left in
      // place, every run would add another dead copy to the library.
      _write('listings/en-US/creative_assets/UNIVERSAL/header.png', _universal);
      final client = _FakeClient()
        ..seedImage(_universal, state: 'FAILED', name: 'header.png');

      final said = await _run(client, []);

      expect(exitCode, 0, reason: said.err);
      expect(client.writes.take(2).map((c) => '${c.method} ${c.path}'), [
        'DELETE /v1/appAssetLibraryImages/image-1',
        'POST /v1/appAssetLibraryImages',
      ]);
      expect(client.images.single['id'], isNot('image-1'));
    });

    test('an image from the other category is never reused', () async {
      // The category cannot change after reservation, so a screenshot-category
      // asset carrying the same marker could not be placed as a header. The
      // library listing is filtered to CREATIVE_ASSETS for that reason.
      _write('listings/en-US/creative_assets/UNIVERSAL/header.png', _universal);
      final client = _FakeClient()
        ..seedImage(
          _universal,
          name: 'header.png',
          category: 'APP_SCREENSHOTS_AND_PREVIEWS',
        );

      final said = await _run(client, []);

      expect(exitCode, 0, reason: said.err);
      expect(
        client.writes.where((c) => c.path == '/v1/appAssetLibraryImages'),
        hasLength(1),
      );
    });

    test('--submit-for-review submits the asset on its own', () async {
      _write('listings/en-US/creative_assets/UNIVERSAL/header.png', _universal);
      final client = _FakeClient();

      final said = await _run(client, ['--submit-for-review']);

      expect(exitCode, 0, reason: said.err);
      final submission = client.submissions.single;
      expect(submission.items, ['image-1']);
      final item = client.writes.firstWhere(
        (c) => c.path == '/v1/reviewSubmissionItems',
      );
      expect(
        (((item.body! as Map)['data'] as Map)['relationships'] as Map).keys,
        unorderedEquals(['reviewSubmission', 'appAssetLibraryImage']),
        reason: 'the asset alone — no version rides along',
      );
      expect(
        client.writes.where(
          (c) => c.path == '/v1/reviewSubmissions/${submission.id}',
        ),
        hasLength(1),
      );
      expect(said.out, contains('state WAITING_FOR_REVIEW'));
    });

    test('an asset already in review is not submitted again', () async {
      _write('listings/en-US/creative_assets/UNIVERSAL/header.png', _universal);
      final client = _FakeClient()
        ..seedImage(_universal, state: 'IN_REVIEW', name: 'header.png');

      final said = await _run(client, ['--submit-for-review']);

      expect(exitCode, 0, reason: said.err);
      expect(client.writes, isEmpty);
      expect(
        said.out,
        contains('no creative asset is waiting to be submitted'),
      );
    });

    test('an open submission holding other items is not flipped', () async {
      _write('listings/en-US/creative_assets/UNIVERSAL/header.png', _universal);
      final client = _FakeClient()
        ..submissions.add((
          id: 'open-1',
          state: 'READY_FOR_REVIEW',
          items: ['version-1'],
        ));

      final said = await _run(client, ['--submit-for-review']);

      expect(exitCode, 1);
      expect(said.err, contains('already holds 1 item(s)'));
      expect(
        client.writes.where((c) => c.path.startsWith('/v1/reviewSubmission')),
        isEmpty,
      );
    });
  });
}
