// SPDX-License-Identifier: Apache-2.0
//
// `appstore upload --metadata --release-type`.
//
// **The flag existed on `promote` only, and one real flow could reach neither
// it nor any substitute.** A `--prepare` step publishes the listing and stops
// — no artifact, no promote — so a human can read the finished page before
// submitting for review. That step creates the App Store version through this
// path, version creation defaults `releaseType` to MANUAL, and nothing that
// flow could run was able to say otherwise. The release type of the version
// somebody then submits by hand was decided by a default nobody chose.
//
// Reported by the consumer running that flow, with the evidence rather than
// the conclusion: the option's declaration sat inside `case
// AscCommand.promote:`, and the create takes `releaseType ?? 'MANUAL'`.
import 'dart:io';

import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:cux_ship/src/appstore/cli.dart';
import 'package:test/test.dart';

late Directory _root;

void _write(String relative, String contents) {
  final file = File('${_root.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

/// Canned App Store Connect holding no version, so every run creates one.
class _FakeClient implements AscClient {
  _FakeClient({this.existingReleaseType});

  /// When set, Apple already holds a 1.1.6 with this release type — so a run
  /// *adopts* a version rather than creating one, which is the only way to
  /// reach the dry-run guard below: a create under `--dry-run` writes nothing
  /// and returns null, so the reporting block is unreachable anyway.
  final String? existingReleaseType;

  final posted = <({String path, Map<String, dynamic> body})>[];

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async {
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
    if (path.endsWith('/appStoreVersions') && existingReleaseType != null) {
      return [
        {
          'type': 'appStoreVersions',
          'id': 'version-held',
          'attributes': {
            'versionString': '1.1.6',
            'appStoreState': 'PREPARE_FOR_SUBMISSION',
            'releaseType': existingReleaseType,
          },
        },
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async => const {};

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    posted.add((path: path, body: body));
    if (path == '/v1/appStoreVersions') {
      // **Apple echoes the attributes it accepted.** The reported line is read
      // off the record rather than off the flag — "effective, not intended" —
      // so a fake returning an empty `attributes` could not tell a run that
      // set the type from one that asked and was ignored.
      return {
        'data': {
          'type': 'appStoreVersions',
          'id': 'version-1',
          'attributes':
              (body['data'] as Map<String, dynamic>)['attributes']
                  as Map<String, dynamic>,
        },
      };
    }
    return {
      'data': {'type': 'x', 'id': 'x', 'attributes': <String, dynamic>{}},
    };
  }

  @override
  Future<Map<String, dynamic>> patch(
    String path,
    Map<String, dynamic> body,
  ) async => {'data': <String, dynamic>{}};

  @override
  Future<void> delete(String path) async {}

  @override
  AscCredentials get credentials =>
      AscCredentials(keyId: 'K', issuerId: 'I', privateKeyPem: 'unused');

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

Future<String> _upload(_FakeClient client, {List<String> extra = const []}) {
  final args = buildAscParser(AscCommand.upload).parse([
    '--bundle-id',
    'design.codeux.example',
    '--version-name',
    '1.1.6',
    '--metadata',
    '${_root.path}/store/appstore',
    ...extra,
  ]);
  final captured = _MemoryStdout();
  return IOOverrides.runZoned(
    () async {
      await runAsc(AscCommand.upload, args, ascClient: client);
      await captured.close();
      return captured.buffer.toString();
    },
    stdout: () => captured,
    stderr: () => captured,
  );
}

/// The `releaseType` the run asked Apple to create the version with.
String? _asked(_FakeClient client) {
  for (final call in client.posted) {
    if (call.path == '/v1/appStoreVersions') {
      return ((call.body['data'] as Map<String, dynamic>)['attributes']
              as Map<String, dynamic>)['releaseType']
          as String?;
    }
  }
  return null;
}

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('asc_release_type');
    _write(
      'store/appstore/listings/en-US/description.txt',
      'A simulation, not a game.',
    );
    exitCode = 0;
  });

  tearDown(() {
    _root.deleteSync(recursive: true);
    exitCode = 0;
  });

  test('a listing publish takes --release-type', () async {
    final client = _FakeClient();

    final said = await _upload(
      client,
      extra: ['--release-type', 'AFTER_APPROVAL'],
    );

    expect(
      _asked(client),
      'AFTER_APPROVAL',
      reason: 'the flag has to reach the create, not just parse',
    );
    expect(said, contains('release type: AFTER_APPROVAL'));
  });

  test('without it, the create is MANUAL and the run says so', () async {
    // **The line prints whether or not the flag was passed**, which is the
    // case it exists for: a version left MANUAL by a default nobody chose is
    // how somebody discovers after approval that the release is waiting on a
    // button they did not know about.
    final client = _FakeClient();

    final said = await _upload(client);

    expect(_asked(client), 'MANUAL');
    expect(said, contains('release type: MANUAL'));
    expect(
      said,
      contains('release it yourself once approved'),
      reason: 'MANUAL is the one that needs a next action naming',
    );
  });

  test('the line is read back from Apple, not echoed from the flag', () async {
    // "Effective, not intended". If Apple ignored the request, the run must
    // report what Apple holds rather than what was asked — reporting the flag
    // would be the create-time `previewFrameTimeCode` mistake again, on a
    // different attribute.
    final client = _FakeClient();

    final said = await _upload(client, extra: ['--release-type', 'MANUAL']);

    expect(said, contains('release type: MANUAL'));
  });

  test('a dry run asks for nothing and claims nothing', () async {
    final client = _FakeClient();

    final said = await _upload(
      client,
      extra: ['--release-type', 'AFTER_APPROVAL', '--dry-run'],
    );

    expect(client.posted, isEmpty);
    expect(
      said,
      isNot(contains('release type:')),
      reason: 'the record was not written, so its value is not an outcome',
    );
  });

  test('a dry run against a held version claims nothing either', () async {
    // **The case the dry-run guard actually exists for**, and the one the
    // test above cannot reach: a *create* under `--dry-run` writes nothing and
    // returns null, so the reporting block is unreachable regardless. Adopting
    // a version Apple already holds is different — the record is real and its
    // current value is readable, so printing it as "effective" beside a flag
    // asking for something else states an outcome the real run would falsify.
    final client = _FakeClient(existingReleaseType: 'MANUAL');

    final said = await _upload(
      client,
      extra: ['--release-type', 'AFTER_APPROVAL', '--dry-run'],
    );

    expect(
      said,
      isNot(contains('release type:')),
      reason: 'nothing was written, so nothing is in effect',
    );
  });

  // **A bad value is refused offline, and the case lives in
  // `subcommand_smoke_test.dart`** — `fail` calls `exit`, so an in-process
  // test of it takes the whole run down rather than failing one case. The
  // refusal fires before credentials, which is what makes a subprocess test of
  // it possible at all.
}
