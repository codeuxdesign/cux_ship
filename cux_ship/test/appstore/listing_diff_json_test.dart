// SPDX-License-Identifier: Apache-2.0
//
// `appstore upload --metadata … --dry-run --json`.
//
// **The document is a comparison this package already performs**, and the
// reason it exists is that a readiness check otherwise has to match
// `would update: en-US: description` with a regular expression — the thing
// json-output.md was written after a consumer's status escaped from four of.
//
// Two properties are worth more than the rest and both are easy to fake:
// `matches` must be derived from the same change sets the fields are rendered
// from, and `appleOnlyLocales` must NOT make it false. The second is the one a
// careless implementation gets backwards, because "Apple has a locale we do
// not" reads like a mismatch and is not: "present means owned" means the tree
// makes no claim about it.
import 'dart:convert';
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

/// Canned App Store Connect holding one version and whatever localizations a
/// case gives it.
class _FakeClient implements AscClient {
  _FakeClient({this.localizations = const []});

  /// `appStoreVersionLocalizations` Apple already holds for the version.
  final List<Map<String, dynamic>> localizations;

  final patched = <String>[];
  final posted = <String>[];

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
    if (path.endsWith('/appStoreVersions')) {
      return [
        {
          'type': 'appStoreVersions',
          'id': 'version-1',
          'attributes': {
            'versionString': '1.1.6',
            'appStoreState': 'PREPARE_FOR_SUBMISSION',
          },
        },
      ];
    }
    if (path.endsWith('/appStoreVersionLocalizations')) {
      return localizations;
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
    posted.add(path);
    return {
      'data': {'type': 'x', 'id': 'x', 'attributes': <String, dynamic>{}},
    };
  }

  @override
  Future<Map<String, dynamic>> patch(
    String path,
    Map<String, dynamic> body,
  ) async {
    patched.add(path);
    return {'data': <String, dynamic>{}};
  }

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

Map<String, dynamic> _localization(String locale, Map<String, String> fields) =>
    {
      'type': 'appStoreVersionLocalizations',
      'id': 'loc-$locale',
      'attributes': {'locale': locale, ...fields},
    };

Future<({String out, String err})> _upload(
  _FakeClient client, {
  List<String> extra = const ['--dry-run', '--json'],
}) async {
  final args = buildAscParser(AscCommand.upload).parse([
    '--bundle-id',
    'design.codeux.example',
    '--version-name',
    '1.1.6',
    '--metadata',
    '${_root.path}/store/appstore',
    ...extra,
  ]);
  final out = _MemoryStdout();
  final err = _MemoryStdout();
  await IOOverrides.runZoned(
    () => runAsc(AscCommand.upload, args, ascClient: client),
    stdout: () => out,
    stderr: () => err,
  );
  await out.close();
  await err.close();
  return (out: out.buffer.toString(), err: err.buffer.toString());
}

Map<String, dynamic> _document(({String out, String err}) said) =>
    jsonDecode(said.out) as Map<String, dynamic>;

void main() {
  setUp(() {
    _root = Directory.systemTemp.createTempSync('asc_listing_diff');
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

  test('a tree that differs names the locale and the fields', () async {
    final client = _FakeClient(
      localizations: [
        _localization('en-US', {'description': 'Something old'}),
      ],
    );

    final said = await _upload(client);

    final document = _document(said);
    expect(document['kind'], 'appstore.listing-diff');
    expect(document['schema'], 1);
    expect(document['matches'], isFalse);
    expect((document['version'] as Map<String, dynamic>)['localizations'], {
      'en-US': ['description'],
    });
  });

  test('a tree that already matches says so, and writes nothing', () async {
    final client = _FakeClient(
      localizations: [
        _localization('en-US', {'description': 'A simulation, not a game.'}),
      ],
    );

    final said = await _upload(client);

    expect(_document(said)['matches'], isTrue);
    expect(client.patched, isEmpty);
    expect(client.posted, isEmpty);
  });

  test('a locale only Apple holds is reported and is not a mismatch', () async {
    // **The property most easily got backwards.** "Apple has de-DE and we do
    // not" reads like a difference and is not one: "present means owned" means
    // this tree makes no claim about that locale, and counting it would report
    // a permanent mismatch for every project whose tree is partial on purpose.
    //
    // It still has to be *visible*, because "every field we declare agrees" is
    // narrower than the sentence a reader hears — which is how a status grid
    // came to print LIVE for a release nobody could install.
    final client = _FakeClient(
      localizations: [
        _localization('en-US', {'description': 'A simulation, not a game.'}),
        _localization('de-DE', {'description': 'Etwas anderes'}),
      ],
    );

    final said = await _upload(client);

    final document = _document(said);
    expect(
      document['matches'],
      isTrue,
      reason: 'an undeclared locale is not a difference',
    );
    expect(document['appleOnlyLocales'], ['de-DE']);
    expect(
      (document['display'] as List).join('\n'),
      contains('de-DE'),
      reason: 'unclaimed is not the same as invisible',
    );
  });

  test('matches agrees with the fields it is derived from', () async {
    final client = _FakeClient(
      localizations: [
        _localization('en-US', {'description': 'Something old'}),
      ],
    );

    final document = _document(await _upload(client));

    final version = document['version'] as Map<String, dynamic>;
    final app = document['app'] as Map<String, dynamic>;
    final anyChange =
        (version['localizations'] as Map).isNotEmpty ||
        (version['fields'] as List).isNotEmpty ||
        (app['localizations'] as Map).isNotEmpty ||
        (app['fields'] as List).isNotEmpty;
    expect(document['matches'], !anyChange);
  });

  test('a difference is exit 0 — it is an answer, not a failure', () async {
    // The opposite call from `verify --json`, which exits 1 because it exists
    // to fail a build. Here the answer is in the document and putting it in
    // the status too would be two sources for one fact, free to disagree.
    final client = _FakeClient(
      localizations: [
        _localization('en-US', {'description': 'Something old'}),
      ],
    );

    await _upload(client);

    expect(exitCode, 0);
  });

  test('stdout is the document and nothing else', () async {
    final client = _FakeClient(
      localizations: [
        _localization('en-US', {'description': 'Something old'}),
      ],
    );

    final said = await _upload(client);

    expect(() => jsonDecode(said.out), returnsNormally);
    expect(said.out, isNot(contains('==>')));
  });
}
