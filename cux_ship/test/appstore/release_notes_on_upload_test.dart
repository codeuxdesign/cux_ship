// SPDX-License-Identifier: Apache-2.0
//
// `upload --metadata --changelog CHANGELOG.md` accepted the flag and wrote no
// "What's New in This Version". The App Store showed it empty.
//
// **The write existed and lived in the promote block**, so `promote
// --changelog` was correct and the listing-only publish silently was not —
// and the consumer who found it has a flow that never reaches promote by
// design: publish everything, look at it in App Store Connect, then submit by
// hand. A flag taken and dropped, on copy a shopper reads.
//
// **These drive `runAsc` rather than `publishReleaseNotes`**, and that is the
// whole point. The rules the function carries — a first version has no "What's
// New", and Apple refuses emoji — were never the bug; the bug was that one of
// two publishers did not call it. A test of the function alone would have
// passed on the day this shipped.
import 'dart:io';

import 'package:cux_ship/src/appstore/asc_client.dart';
import 'package:cux_ship/src/appstore/cli.dart';
import 'package:test/test.dart';

/// Canned App Store Connect for a listing-only publish.
///
/// **It honours `filter[platform]` on the versions collection**, because
/// `isFirstVersion` is a question about that collection and the whole
/// first-version branch turns on the answer: a fake returning one version
/// would send every case down "this app's first", where no notes are written
/// and this suite would agree with a program that never wrote any.
class _FakeClient implements AscClient {
  _FakeClient({this.versions = const []});

  /// What Apple holds for the platform, before this run.
  final List<Map<String, dynamic>> versions;

  final posted = <({String path, Map<String, dynamic> body})>[];
  final patched = <({String path, Map<String, dynamic> body})>[];

  @override
  Future<List<Map<String, dynamic>>> getAll(
    String path, {
    Map<String, String>? query,
  }) async {
    if (path == '/v1/apps') {
      // **Exact-matched, because `resolveApp` is.** `filter[bundleId]` is a
      // prefix match on Apple's side, so the real client has to sort a
      // `...example.beta` from `...example` itself — a fake that returned one
      // app whatever was asked could not reach that branch.
      return [
        for (final id in ['app-1'])
          if (query?['filter[bundleId]'] == 'design.codeux.example')
            {
              'type': 'apps',
              'id': id,
              'attributes': {
                'bundleId': 'design.codeux.example',
                'name': 'Example',
              },
            },
      ];
    }
    if (path.endsWith('/appStoreVersions')) {
      final wanted = query?['filter[versionString]'];
      if (wanted == null) {
        return versions;
      }
      return versions
          .where(
            (v) =>
                (v['attributes'] as Map<String, dynamic>)['versionString'] ==
                wanted,
          )
          .toList();
    }
    // No appInfos, no existing localizations: the tree here carries only
    // version-scoped text, so the app-level half has nothing to compare and
    // the locale has no record yet.
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
    return {
      'data': {
        'type': 'appStoreVersions',
        'id': 'version-1',
        'attributes': {'versionString': '1.1.6'},
      },
    };
  }

  @override
  Future<Map<String, dynamic>> patch(
    String path,
    Map<String, dynamic> body,
  ) async {
    patched.add((path: path, body: body));
    return {'data': <String, dynamic>{}};
  }

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

late Directory _root;

void _write(String relative, String contents) {
  final file = File('${_root.path}/$relative');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

/// Every `whatsNew` this run sent, from whichever verb carried it.
///
/// **Both a POST and a PATCH can carry it** — `writeVersionLocalization`
/// chooses by whether Apple already holds a record for the locale — so a test
/// that watched one verb would pass or fail on the fixture's state rather than
/// on the program's behaviour.
List<String> _whatsNewSent(_FakeClient client) => [
  for (final write in [...client.posted, ...client.patched]) ...{
    ...() {
      final data = write.body['data'];
      final attributes = data is Map<String, dynamic>
          ? data['attributes']
          : null;
      final value = attributes is Map<String, dynamic>
          ? attributes['whatsNew']
          : null;
      return value is String ? [value] : <String>[];
    }(),
  },
];

Future<String> _upload(_FakeClient client, {List<String> extra = const []}) {
  final args = buildAscParser(AscCommand.upload).parse([
    '--bundle-id',
    'design.codeux.example',
    '--version-name',
    '1.1.6',
    '--metadata',
    '${_root.path}/store/appstore',
    '--changelog',
    '${_root.path}/CHANGELOG.md',
    ...extra,
  ]);
  final captured = _MemoryStdout();
  return IOOverrides.runZoned(() async {
    await runAsc(AscCommand.upload, args, ascClient: client);
    await captured.close();
    return captured.buffer.toString();
  }, stdout: () => captured);
}

Map<String, dynamic> _version(String id, String name) => {
  'type': 'appStoreVersions',
  'id': id,
  'attributes': {'versionString': name},
};

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('asc_notes_test');
    _write(
      'CHANGELOG.md',
      '# Changelog\n\n## 1.1.6\n\n- A shorter tour intro\n\n## 1.1.5\n\n- Older\n',
    );
    _write(
      'store/appstore/listings/en-US/description.txt',
      'A simulation, not a game.',
    );
  });

  tearDown(() => _root.deleteSync(recursive: true));

  test('a listing-only upload publishes the release notes', () async {
    // The defect: this wrote the description and nothing else, so App Store
    // Connect showed "What's New in This Version" empty while the command had
    // been given the changelog it should have come from.
    final client = _FakeClient(versions: [_version('old', '1.1.5')]);

    await _upload(client);

    expect(_whatsNewSent(client), ['- A shorter tour intro']);
  });

  test('a first version still has no "What\'s New"', () async {
    // Apple refuses the write with a message that does not explain itself, so
    // the rule has to travel with the write rather than sit at one call site
    // — which is the whole reason this is one function with two callers.
    final client = _FakeClient();

    final said = await _upload(client);

    expect(_whatsNewSent(client), isEmpty);
    expect(said, contains('first App Store version'));
  });

  test('emoji are stripped, and the run says which', () async {
    // Measured, after this file spent a release asserting the opposite. This
    // is copy a shopper reads, so publishing something other than what the
    // changelog says is worth three lines of output.
    _write(
      'CHANGELOG.md',
      '# Changelog\n\n## 1.1.6\n\n- 🚴 A shorter tour intro\n\n## 1.1.5\n\n- Old\n',
    );
    final client = _FakeClient(versions: [_version('old', '1.1.5')]);

    final said = await _upload(client);

    expect(_whatsNewSent(client).single, isNot(contains('🚴')));
    expect(said, contains('rejects emoji'));
  });

  test('no changelog means no release-notes write, not an empty one', () async {
    // "Present means owned" reaches this too: a run that names no notes
    // should leave whatever Apple holds rather than blanking it.
    final client = _FakeClient(versions: [_version('old', '1.1.5')]);
    // No `--changelog`, and no CHANGELOG.md to infer one from: the file is
    // written into the temp root, and nothing points this run at it.
    File('${_root.path}/CHANGELOG.md').deleteSync();
    final args = buildAscParser(AscCommand.upload).parse([
      '--bundle-id',
      'design.codeux.example',
      '--version-name',
      '1.1.6',
      '--metadata',
      '${_root.path}/store/appstore',
    ]);
    final captured = _MemoryStdout();
    await IOOverrides.runZoned(
      () => runAsc(AscCommand.upload, args, ascClient: client),
      stdout: () => captured,
    );
    await captured.close();

    expect(_whatsNewSent(client), isEmpty);
  });

  test('a dry run writes nothing at all', () async {
    final client = _FakeClient(versions: [_version('old', '1.1.5')]);

    await _upload(client, extra: ['--dry-run']);

    expect(client.posted, isEmpty);
    expect(client.patched, isEmpty);
  });
}
