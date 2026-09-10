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
  _FakeClient({this.localizations = const [], this.holdsVersion = true});

  /// `appStoreVersionLocalizations` Apple already holds for the version.
  final List<Map<String, dynamic>> localizations;

  /// **Whether Apple holds a 1.1.6 at all, and whether it holds anything
  /// editable.** False is the state right after a release goes
  /// `READY_FOR_SALE`: no version by that name, and none to rename — so a dry
  /// run creates nothing and has nothing to compare against.
  ///
  /// Settable because the fake used to answer the same record to the filtered
  /// lookup *and* the unfiltered editable-version scan, which made
  /// `ensureVersion` return non-null on every case in this file. The branch
  /// where it returns null was unreachable from the whole suite, and that is
  /// the branch where `matches` was wrong.
  final bool holdsVersion;

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
      if (!holdsVersion) {
        return const [];
      }
      // **`filter[versionString]` is honoured**, because `ensureVersion` asks
      // twice with different queries: once for the named version, and once
      // unfiltered to find an editable one it could rename.
      //
      // No case below selects on it — every one asks for 1.1.6, and the
      // not-held case is `holdsVersion: false`, which returns before this. So
      // a mutation removing it survives, and that is recorded rather than
      // dressed up: it is here because a fake that answers the same record to
      // two different questions is the shape CONTRIBUTING names, and because
      // the next case to ask for a second version name would otherwise be
      // written against a fake that cannot tell them apart.
      final wanted = query?['filter[versionString]'];
      if (wanted != null && wanted != '1.1.6') {
        return const [];
      }
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

  /// Bodies of every `POST`, so a case can assert what was *asked for* as
  /// well as what came back.
  final postedBodies = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    posted.add(path);
    postedBodies.add(body);
    if (path == '/v1/appStoreVersions') {
      // **Apple echoes the attributes it accepted**, and the release-type line
      // is read off that record rather than off the flag — so a fake that
      // returned an empty `attributes` could not tell a run that set the type
      // from one that asked and was ignored.
      final attributes =
          (body['data'] as Map<String, dynamic>)['attributes']
              as Map<String, dynamic>;
      return {
        'data': {
          'type': 'appStoreVersions',
          'id': 'version-new',
          'attributes': attributes,
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

  test('a version that would be created is not "already matches"', () async {
    // **The field the document exists for, answering the opposite of the
    // truth.** A dry run cannot create a version, so `ensureVersion` returns
    // null and the version-scoped comparison never runs — and `matches` read
    // "not compared" as "nothing differs". The prose on the same run is
    // honest: it prints *(dry run created no version, so the fields below are
    // skipped)*. Only the document lied.
    //
    // The state is ordinary rather than exotic: it is every dry run for a
    // version that does not exist yet, which is every run before a release is
    // prepared. `ready` would have reported the store in sync while every
    // description, keyword and screenshot was still to be written.
    final client = _FakeClient(holdsVersion: false);

    final said = await _upload(client);

    final document = _document(said);
    expect(
      document['matches'],
      isFalse,
      reason: 'nothing was compared, which is not the same as nothing differs',
    );
    expect(
      (document['display'] as List).join('\n'),
      isNot(contains('already matches')),
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
